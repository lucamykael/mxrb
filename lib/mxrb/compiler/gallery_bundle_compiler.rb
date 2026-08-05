# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # Compiles the official React Gallery widget with XPath, microflow, or nanoflow data sources.
    class GalleryBundleCompiler # rubocop:disable Metrics/ClassLength
      include ModelValues

      WIDGET_ID = 'com.mendix.widget.web.gallery.Gallery'

      attr_reader :data_source, :entity_name

      def initialize(source, page_name, widget)
        @source = source
        @page_name = page_name
        @widget = widget
        @index = document_index
        @values = property_values(widget['Object'])
        @data_source = WebListDataSource.new(source, widget)
        @entity_name = data_source.entity
        @xpath_arguments = resolve_xpath_arguments
      end

      def supported?
        widget_type&.fetch('WidgetId', nil) == WIDGET_ID &&
          @data_source.supported? && !entity_name.to_s.empty? && !@xpath_arguments.nil?
      end

      def content_widgets = array(@values['content']&.last&.fetch('Widgets', nil))
      def widget_key = "p.#{@page_name}.#{@widget['Name']}"
      def data_source_id = "p.#{Digest::SHA256.hexdigest(widget_key)[0, 6].to_i(16)}"

      def render(content, nanoflow_reference: nil)
        @nanoflow_reference = nanoflow_reference
        values = primitives(@values).merge(
          key: widget_key, '$widgetId': widget_key, datasource: raw(datasource),
          content: raw("TemplatedWidgetProperty({ children: () => #{content}, " \
                       "dataSourceId: #{JSON.generate(data_source_id)}, editable: false })"),
          itemSelection: raw(selection), class: css_class
        )
        "React.createElement($Gallery, #{js_object(values)})"
      end

      private

      def datasource
        config = {
          dataSourceId: data_source_id,
          operationId: WebOperationCompiler.operation_id(@page_name, @widget['Name'])
        }
        return xpath_datasource(config) if @data_source.xpath?
        return microflow_datasource(config) if @data_source.microflow?

        nanoflow_datasource(config)
      end

      def xpath_datasource(config)
        values = config.merge(entity: entity_name, sort: [])
        unless @xpath_arguments.empty?
          values[:arguments] = @xpath_arguments
          values[:fetchOnlyWithAllParams] = true
        end
        "DatabaseObjectListProperty(#{js_object(values)})"
      end

      def resolve_xpath_arguments
        return {} unless @data_source.xpath?

        names = xpath_variables(@data_source.xpath_constraint)
        return {} if names.empty?

        parameters = object_page_parameters(page_document, names)
        return unless parameters

        parameters.to_h { |name, _entity| [name, ["$#{name}", :undefined, false]] }
      end

      def page_document
        module_name, document_name = @page_name.split('.', 2)
        @source.units_of('Forms$Page').find do |unit|
          unit.module_name == module_name && unit.document['Name'] == document_name
        end&.document
      end

      def microflow_datasource(config)
        values = config.merge(argMap: {}, fetchOnlyWithAllParams: false)
        "MicroflowObjectListProperty(#{js_object(values)})"
      end

      def nanoflow_datasource(config)
        values = config.except(:operationId).merge(
          source: { nanoflow: raw(@nanoflow_reference || 'undefined') },
          argMap: {}, fetchOnlyWithAllParams: false
        )
        "NanoflowObjectListProperty(#{js_object(values)})"
      end

      def selection
        type = @values['itemSelection']&.last&.fetch('Selection', 'None') || 'None'
        "SelectionProperty(#{js_object(selectionType: type, dataSourceId: data_source_id)})"
      end

      def primitives(values)
        values.each_with_object({}) do |(key, pair), result|
          type, value = pair
          compiled = primitive(type, value)
          result[key.to_sym] = compiled unless compiled.equal?(:undefined)
        end
      end

      def primitive(type, value) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
        compiled = case type
                   when 'Boolean' then value['PrimitiveValue'] == 'true'
                   when 'Integer' then value['PrimitiveValue'].to_i
                   when 'Enumeration' then value['PrimitiveValue'].to_s
                   when 'TextTemplate' then raw(expression(translated_text(value['TextTemplate'])))
                   when 'Widgets' then [] if array(value['Widgets']).empty?
                   when 'Object' then [] if array(value['Objects']).empty?
                   end
        compiled.nil? ? :undefined : compiled
      end

      def expression(value)
        "ExpressionProperty(#{js_object(expression: { expr: { type: 'literal', value: }, args: {} })})"
      end

      def raw(value) = { '$raw' => value }

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

      def css_class
        ["mx-name-#{@widget['Name']}", @widget.dig('Appearance', 'Class')]
          .map(&:to_s).reject(&:empty?).uniq.join(' ')
      end

      def translated_text(text)
        items = array(text&.dig('Template', 'Items'))
        items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          items.first&.fetch('Text', '') || ''
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
    end # rubocop:enable Metrics/ClassLength
  end
end
