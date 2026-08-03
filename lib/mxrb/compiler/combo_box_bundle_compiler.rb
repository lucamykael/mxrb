# frozen_string_literal: true

require 'digest'
require 'json'

module Mxrb
  module Compiler
    # Compiles association- and database-backed instances of the official React Combo box widget.
    class ComboBoxBundleCompiler # rubocop:disable Metrics/ClassLength
      include ModelValues

      WIDGET_ID = 'com.mendix.widget.web.combobox.Combobox'

      def initialize(source, page_name, widget, scope:, entity:)
        @source = source
        @page_name = page_name
        @widget = widget
        @scope = scope
        @entity = entity
        @index = document_index
        @values = property_values(widget['Object'])
        @data_source = WebListDataSource.new(source, widget)
      end

      def supported?
        widget_type&.fetch('WidgetId', nil) == WIDGET_ID && supported_source? &&
          @data_source.supported? && !@data_source.entity.to_s.empty? && resolved_scope
      end

      def render # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        properties = primitive_properties.merge(
          key: widget_key, '$widgetId': widget_key, class: css_class, id: widget_key,
          optionsSourceStaticDataSource: [],
          ariaRequired: raw(expression(false))
        )
        properties.merge!(source_properties)
        control = "React.createElement($Combobox, #{javascript(properties)})"
        caption = translated_text(@widget['LabelTemplate'])
        group = {
          key: "#{widget_key}$formGroup", '$widgetId': "#{widget_key}$formGroup",
          class: "#{css_class} mx-combobox", control: raw("[#{control}]"),
          width: 3, orientation: 'horizontal', labelFor: widget_key,
          caption: raw(expression(caption)), hasError: raw(expression(false))
        }
        "React.createElement($FormGroup, #{javascript(group)})"
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

      def supported_source?
        return database_source_supported? if primitive('source') == 'database'

        association_source_supported?
      end

      def database_source_supported?
        target_attribute && database_caption_attribute && database_value_attribute
      end

      def association_source_supported?
        primitive('source') == 'context' && primitive('optionsSourceType') == 'association' &&
          association_step && association_caption_attribute
      end

      def source_properties
        primitive('source') == 'database' ? database_properties : association_properties
      end

      def database_properties
        return database_association_properties if target_steps.any?

        {
          databaseAttributeString: raw(attribute_property(target_attribute)),
          optionsSourceDatabaseCaptionAttribute: raw(list_attribute_property(database_caption_attribute)),
          optionsSourceDatabaseValueAttribute: raw(list_attribute_property(database_value_attribute)),
          optionsSourceDatabaseDataSource: raw(list_property),
          optionsSourceDatabaseItemSelection: raw(selection_property)
        }
      end

      def database_association_properties
        {
          source: 'context',
          optionsSourceAssociationCaptionAttribute: raw(list_attribute_property(database_caption_attribute)),
          attributeAssociation: raw(association_property(target_steps.first)),
          optionsSourceAssociationDataSource: raw(list_property)
        }
      end

      def association_properties
        {
          optionsSourceAssociationCaptionAttribute: raw(list_attribute_property(association_caption_attribute)),
          attributeAssociation: raw(association_property(association_step)),
          optionsSourceAssociationDataSource: raw(list_property)
        }
      end

      def association_property(step)
        "AssociationProperty(#{javascript(
          type: 'Reference', entity: resolved_entity, path: '', attribute: step['Association'],
          endpointEntity: step['DestinationEntity'], selectableObjectsId: data_source_id,
          scope: resolved_scope, onChange: do_nothing
        )})"
      end

      def list_property
        config = {
          dataSourceId: data_source_id, entity: @data_source.entity, scope: resolved_scope,
          operationId: WebOperationCompiler.operation_id(@page_name, @widget['Name'])
        }
        if @data_source.xpath?
          "DatabaseObjectListProperty(#{javascript(config.merge(sort: []))})"
        else
          "MicroflowObjectListProperty(#{javascript(config.merge(argMap: {}, fetchOnlyWithAllParams: false))})"
        end
      end

      def selection_property
        selection = value('optionsSourceDatabaseItemSelection')&.fetch('Selection', 'Single') || 'Single'
        "SelectionProperty(#{javascript(selectionType: selection, dataSourceId: data_source_id)})"
      end

      def attribute_property(attribute)
        entity, name = split_attribute(attribute.fetch('Attribute'))
        path = entity_steps(attribute).flat_map do |step|
          [step['Association'], step['DestinationEntity']]
        end.join('/')
        config = {
          scope: resolved_scope, path:, entity:, attribute: name, onChange: do_nothing,
          isList: false, validation: nil, formatting: {}
        }
        "AttributeProperty(#{javascript(config)})"
      end

      def list_attribute_property(attribute)
        entity, name = split_attribute(attribute.fetch('Attribute'))
        "ListAttributeProperty(#{javascript(
          path: '', entity:, attribute: name, attributeType: 'String', sortable: true,
          filterable: true, dataSourceId: data_source_id, isList: false
        )})"
      end

      def split_attribute(qualified)
        entity, separator, name = qualified.to_s.rpartition('.')
        raise CompilationError, "invalid Combo box attribute #{qualified.inspect}" unless separator == '.'

        [entity, name]
      end

      def resolved_scope
        @resolved_scope ||= begin
          parameter = target_value&.dig('SourceVariable', 'PageParameter').to_s
          parameter.empty? ? @scope : "$#{parameter}"
        end
      end

      def resolved_entity
        return @entity unless @entity.to_s.empty?

        parameter = target_value&.dig('SourceVariable', 'PageParameter').to_s
        page_parameter_entity(parameter)
      end

      def page_parameter_entity(name)
        module_name, document_name = @page_name.split('.', 2)
        page = @source.units_of('Forms$Page').find do |unit|
          unit.module_name == module_name && unit.document['Name'] == document_name
        end
        parameter = array(page&.document&.fetch('Parameters', nil)).find { _1['Name'] == name }
        parameter&.dig('ParameterType', 'Entity').to_s
      end

      def target_value = value('databaseAttributeString')
      def target_attribute = target_value&.fetch('AttributeRef', nil)
      def database_caption_attribute = value('optionsSourceDatabaseCaptionAttribute')&.fetch('AttributeRef', nil)
      def database_value_attribute = value('optionsSourceDatabaseValueAttribute')&.fetch('AttributeRef', nil)
      def association_caption_attribute = value('optionsSourceAssociationCaptionAttribute')&.fetch('AttributeRef', nil)

      def association_step
        entity_steps(value('attributeAssociation')).first
      end

      def target_steps = entity_steps(target_attribute)

      def entity_steps(value)
        array(value&.dig('EntityRef', 'Steps'))
      end

      def primitive_properties
        @values.each_with_object({}) do |(key, (type, property)), result|
          compiled = compile_primitive(type, property)
          result[key.to_sym] = compiled unless compiled.nil?
        end
      end

      def compile_primitive(type, property)
        case type
        when 'Boolean' then property['PrimitiveValue'] == 'true'
        when 'Integer' then property['PrimitiveValue'].to_i
        when 'Enumeration' then property['PrimitiveValue'].to_s
        when 'TextTemplate' then raw(expression(translated_text(property['TextTemplate'])))
        when 'Widgets' then [] if array(property['Widgets']).empty?
        end
      end

      def translated_text(template)
        items = array(template&.dig('Template', 'Items'))
        items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          items.first&.fetch('Text', '') || ''
      end

      def expression(value)
        "ExpressionProperty(#{javascript(expression: { expr: { type: 'literal', value: }, args: {} })})"
      end

      def do_nothing
        { type: 'doNothing', argMap: {}, config: {}, disabledDuringExecution: false }
      end

      def data_source_id = "p.#{Digest::SHA256.hexdigest(widget_key)[0, 6].to_i(16)}"
      def widget_key = "p.#{@page_name}.#{@widget['Name']}"

      def css_class
        ["mx-name-#{@widget['Name']}", @widget.dig('Appearance', 'Class')]
          .map(&:to_s).reject(&:empty?).uniq.join(' ')
      end

      def primitive(key) = value(key)&.fetch('PrimitiveValue', nil)
      def value(key) = @values[key]&.last
      def raw(value) = { '$raw' => value }

      def javascript(value)
        return value['$raw'] if value.is_a?(Hash) && value.key?('$raw')
        return "[#{value.map { javascript(_1) }.join(', ')}]" if value.is_a?(Array)
        if value.is_a?(Hash)
          return "{ #{value.map { |key, item| "#{JSON.generate(key)}: #{javascript(item)}" }.join(', ')} }"
        end

        JSON.generate(value)
      end

      def property_values(object)
        array(object&.fetch('Properties', nil)).filter_map do |property|
          type = @index[IO::BsonCodec.extract_id(property['TypePointer'])]
          next unless type

          [type.fetch('PropertyKey'), [type.dig('ValueType', 'Type'), property['Value']]]
        end.to_h
      end

      def widget_type
        object_type_id = IO::BsonCodec.extract_id(@widget.dig('Object', 'TypePointer'))
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
