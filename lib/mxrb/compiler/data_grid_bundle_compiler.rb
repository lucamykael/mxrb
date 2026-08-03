# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # Compiles the Data Grid 2 XPath/attribute-column subset into pluggable-widget properties.
    # rubocop:disable Metrics
    class DataGridBundleCompiler
      include ModelValues

      WIDGET_ID = 'com.mendix.widget.web.datagrid.Datagrid'

      def initialize(source, page_name, widget = nil, render_widgets: nil, **widget_keywords)
        @source = source
        @page_name = page_name
        @widget = widget || widget_keywords
        @render_widgets = render_widgets
        @index = document_index
      end

      def supported?
        widget_type&.fetch('WidgetId', nil) == WIDGET_ID && xpath_source &&
          columns.all? { supported_column?(_1) }
      end

      def render
        "React.createElement($Datagrid, #{js_object(properties)})"
      end

      private

      def properties
        values = property_values(@widget['Object'])
        primitives(values).merge(
          key: widget_key, '$widgetId': widget_key, advanced: false,
          datasource: datasource, columns: columns.map { compile_column(_1) },
          class: css_class
        )
      end

      def primitives(values)
        values.each_with_object({}) do |(key, pair), result|
          type, value = pair
          compiled = primitive(type, value)
          result[key.to_sym] = compiled unless compiled.equal?(:undefined)
        end
      end

      def primitive(type, value) # rubocop:disable Metrics/CyclomaticComplexity
        compiled = case type
                   when 'Boolean' then value['PrimitiveValue'] == 'true'
                   when 'Integer' then value['PrimitiveValue'].to_i
                   when 'Enumeration' then value['PrimitiveValue'].to_s
                   when 'TextTemplate' then expression(translated_text(value['TextTemplate']))
                   when 'Widgets' then [] if array(value['Widgets']).empty?
                   end
        compiled.nil? ? :undefined : compiled
      end # rubocop:enable Metrics/CyclomaticComplexity

      def datasource
        {
          '$raw' => "DatabaseObjectListProperty(#{js_object(
            dataSourceId: data_source_id, entity: entity_name,
            operationId: WebOperationCompiler.operation_id(@page_name, @widget['Name']), sort: []
          )})"
        }
      end

      def compile_column(object) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        values = property_values(object)
        mode = values.fetch('showContentAs').last['PrimitiveValue']
        attribute = attribute_name(values)
        entity, name = attribute.rpartition('.').then { |prefix, _, suffix| [prefix, suffix] }
        result = primitives(values).merge(
          showContentAs: mode, attribute: attribute.empty? ? :undefined : raw_attribute(entity, name),
          dynamicText: :undefined, header: expression(text_value(values['header']&.last)),
          tooltip: :undefined, filter: compile_widgets(values['filter']&.last),
          visible: expression(true), exportValue: :undefined
        )
        result[:dynamicText] = dynamic_text(values, entity, name) if mode == 'dynamicText'
        result[:content] = templated_content(values) if mode == 'customContent'
        result.merge!(association_filter(values)) if association_filter?(values)
        result
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def association_filter?(values)
        !association_steps(values).empty? && !filter_widget(values).nil?
      end

      def association_filter(values) # rubocop:disable Metrics/AbcSize
        filter = filter_widget(values)
        steps = association_steps(values)
        steps.flat_map { [_1['Association'], _1['DestinationEntity']] }.join('/')
        association = steps.first['Association'].to_s
        endpoint = steps.last['DestinationEntity'].to_s
        caption = attribute_name(values).split('.').last
        selectable_id = "#{data_source_id}$#{filter['Name']}"
        operation_id = WebOperationCompiler.operation_id(
          @page_name, "#{@widget['Name']}$#{filter['Name']}"
        )
        {
          filterAssociation: raw_property('ListAssociationProperty', {
            type: filter_boolean(filter, 'multiSelect') ? 'ReferenceSet' : 'Reference',
            entity: :undefined, path: '', attribute: association, endpointEntity: endpoint,
            selectableObjectsId: selectable_id, filterable: true, dataSourceId: data_source_id
          }),
          filterAssociationOptions: raw_property('DatabaseObjectListProperty', {
            dataSourceId: selectable_id, entity: endpoint, operationId: operation_id,
            sort: [[caption, 'asc']]
          }),
          filterAssociationOptionLabel: raw_property('ListExpressionProperty', {
            expression: {
              expr: { type: 'variable', variable: 'currentObject', path: caption },
              args: { currentObject: { widget: widget_key, source: 'object' } }
            }, dataSourceId: selectable_id
          })
        }
      end

      def raw_property(name, config) = { '$raw' => "#{name}(#{js_object(config)})" }

      def filter_widget(values)
        array(values['filter']&.last&.fetch('Widgets', nil)).first
      end

      def association_steps(values)
        array(values['attribute']&.last&.dig('AttributeRef', 'EntityRef', 'Steps'))
      end

      def filter_boolean(widget, key)
        property_values(widget['Object'])[key]&.last&.fetch('PrimitiveValue', nil) == 'true'
      end

      def dynamic_text(values, entity, name)
        template = values['dynamicText']&.last&.fetch('TextTemplate', nil)
        parameters = array(template&.fetch('Parameters', nil))
        return :undefined unless parameters.one? && !name.empty?

        variable = { type: 'variable', variable: 'currentObject', path: name }
        expr = if attribute_type(entity, name) == 'DateTime'
                 { type: 'function', name: '_format',
                   parameters: [variable, { type: 'literal', value: JSON.generate(type: 'datetime') }] }
               else
                 variable
               end
        raw_list_expression(expr)
      end

      def raw_list_expression(expr)
        payload = {
          expression: { expr:, args: { currentObject: { widget: widget_key, source: 'object' } } },
          dataSourceId: data_source_id
        }
        { '$raw' => "ListExpressionProperty(#{js_object(payload)})" }
      end

      def templated_content(values)
        widgets = array(values['content']&.last&.fetch('Widgets', nil))
        rendered = @render_widgets.call(widgets, widget_key, entity_name)
        { '$raw' => "TemplatedWidgetProperty(#{js_object(
          dataSourceId: data_source_id, editable: false,
          children: { '$raw' => "() => #{rendered}" }
        )})" }
      end

      def compile_widgets(value)
        widgets = array(value&.fetch('Widgets', nil))
        return [] if widgets.empty?

        { '$raw' => @render_widgets.call(widgets, widget_key, entity_name) }
      end

      def raw_attribute(entity, name)
        {
          '$raw' => "AttributeProperty(#{js_object(
            path: '', entity:, attribute: name, attributeType: attribute_type(entity, name),
            sortable: true, filterable: true, dataSourceId: data_source_id, isList: false
          )})"
        }
      end

      def expression(value)
        payload = { expression: { expr: { type: 'literal', value: }, args: {} } }
        { '$raw' => "ExpressionProperty(#{js_object(payload)})" }
      end

      def js_object(value)
        pairs = value.map { |key, item| "#{JSON.generate(key)}: #{js_value(item)}" }
        "{ #{pairs.join(', ')} }"
      end

      def js_value(value)
        return value['$raw'] if value.is_a?(Hash) && value.key?('$raw')
        return 'undefined' if value == :undefined
        return "[#{value.map { js_value(_1) }.join(', ')}]" if value.is_a?(Array)
        return js_object(value) if value.is_a?(Hash)

        JSON.generate(value)
      end

      def property_values(object)
        array(object&.fetch('Properties', nil)).filter_map do |property|
          type = @index[IO::BsonCodec.extract_id(property['TypePointer'])]
          next unless type

          [type.fetch('PropertyKey'), [type.dig('ValueType', 'Type'), property['Value']]]
        end.to_h
      end

      def columns
        value = property_values(@widget['Object']).fetch('columns').last
        array(value['Objects'])
      end

      def supported_column?(object)
        values = property_values(object)
        mode = values['showContentAs']&.last&.fetch('PrimitiveValue', nil)
        return attribute_name(values).include?('.') if %w[attribute dynamicText].include?(mode)
        return false unless mode == 'customContent' && @render_widgets

        array(values['content']&.last&.fetch('Widgets', nil)).any?
      end

      def attribute_name(values) = values['attribute']&.last&.dig('AttributeRef', 'Attribute').to_s

      def xpath_source
        property_values(@widget['Object'])['datasource']&.last&.fetch('DataSource', nil)
      end

      def entity_name = xpath_source.dig('EntityRef', 'Entity').to_s
      def data_source_id = "p.#{Digest::SHA256.hexdigest(widget_key)[0, 6].to_i(16)}"
      def widget_key = "p.#{@page_name}.#{@widget['Name']}"

      def css_class
        ["mx-name-#{@widget['Name']}", @widget.dig('Appearance', 'Class')]
          .map(&:to_s).reject(&:empty?).uniq.join(' ')
      end

      def translated_text(text)
        items = array(text&.dig('Template', 'Items'))
        items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          items.first&.fetch('Text', '') || ''
      end

      def text_value(value) = translated_text(value&.fetch('TextTemplate', nil))

      def attribute_type(entity, name) # rubocop:disable Metrics/AbcSize
        document = @source.units_of('DomainModels$DomainModel').filter_map do |unit|
          next unless unit.module_name == entity.split('.').first

          array(unit.document['Entities']).find { _1['Name'] == entity.split('.').last }
        end.first
        attribute = array(document&.fetch('Attributes', nil)).find { _1['Name'] == name }
        attribute_type_name(attribute&.fetch('NewType', nil))
      end # rubocop:enable Metrics/AbcSize

      def attribute_type_name(type)
        type_name = type&.fetch('$Type', '').to_s.delete_prefix('DomainModels$')
        type_name.delete_suffix('AttributeType').then { _1.empty? ? 'String' : _1 }
      end

      def widget_type
        object_type_id = IO::BsonCodec.extract_id(@widget.dig('Object', 'TypePointer'))
        return unless object_type_id

        @index.values.find do |document|
          IO::BsonCodec.extract_id(document.dig('ObjectType', '$ID')) == object_type_id
        end
      end

      def document_index
        return @source.document_index if @source.is_a?(SourceModel)

        {}.tap { |index| @source.documents.each { index_document(_1, index) } }
      end

      def index_document(value, index)
        case value
        when Hash
          id = IO::BsonCodec.extract_id(value['$ID'])
          index[id] = value if id
          value.each_value { index_document(_1, index) }
        when Array then value.each { index_document(_1, index) }
        end
      end
    end
    # rubocop:enable Metrics
  end
end
