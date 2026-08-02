# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # Compiles the Data Grid 2 XPath/attribute-column subset into pluggable-widget properties.
    class DataGridBundleCompiler # rubocop:disable Metrics/ClassLength
      include ModelValues

      WIDGET_ID = 'com.mendix.widget.web.datagrid.Datagrid'

      def initialize(source, page_name, widget)
        @source = source
        @page_name = page_name
        @widget = widget
        @index = document_index
      end

      def supported?
        widget_type&.fetch('WidgetId', nil) == WIDGET_ID && xpath_source &&
          columns.all? { attribute_column?(_1) }
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

      def compile_column(object) # rubocop:disable Metrics/AbcSize
        values = property_values(object)
        attribute = values.fetch('attribute').last.dig('AttributeRef', 'Attribute')
        entity, name = attribute.rpartition('.').then { |prefix, _, suffix| [prefix, suffix] }
        primitives(values).merge(
          showContentAs: values.fetch('showContentAs').last['PrimitiveValue'],
          attribute: raw_attribute(entity, name), dynamicText: :undefined,
          header: expression(text_value(values['header']&.last)), tooltip: :undefined,
          filter: [], visible: expression(true), exportValue: :undefined
        )
      end # rubocop:enable Metrics/AbcSize

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

      def attribute_column?(object)
        value = property_values(object)['attribute']&.last
        value&.dig('AttributeRef', 'Attribute').to_s.include?('.')
      end

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
    end # rubocop:enable Metrics/ClassLength
  end
end
