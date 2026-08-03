# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # Compiles the static-image subset of the official React Image widget.
    class ImageBundleCompiler # rubocop:disable Metrics/ClassLength
      include ModelValues

      WIDGET_ID = 'com.mendix.widget.web.image.Image'

      def self.render_static(key, css_class, uri, options) # rubocop:disable Metrics/MethodLength
        properties = {
          key:, '$widgetId': key, datasource: 'image',
          imageObject: raw("WebStaticImageProperty({ image: { uri: #{JSON.generate(uri)} } })"),
          imageUrl: raw(expression('')), isBackgroundImage: false, onClickType: 'action',
          alternativeText: raw(expression('')), widthUnit: unit(options[:width_unit]),
          width: number(options[:width], 100), heightUnit: unit(options[:height_unit]),
          height: number(options[:height], 100), iconSize: 14,
          displayAs: 'fullImage', responsive: options[:responsive], minHeightUnit: 'none', minHeight: 0,
          maxHeightUnit: 'none', maxHeight: 0, class: css_class
        }
        "React.createElement($Image, #{javascript(properties)})"
      end # rubocop:enable Metrics/MethodLength

      def self.expression(value)
        "ExpressionProperty({ expression: { expr: { type: \"literal\", value: #{JSON.generate(value)} }, args: {} } })"
      end

      def self.raw(value) = { '$raw' => value }
      def self.unit(value) = value.to_s.downcase.then { _1.empty? ? 'auto' : _1 }
      def self.number(value, fallback) = Integer(value || fallback)

      def self.javascript(value)
        return value['$raw'] if value.is_a?(Hash) && value.key?('$raw')
        return "[#{value.map { javascript(_1) }.join(', ')}]" if value.is_a?(Array)
        if value.is_a?(Hash)
          return "{ #{value.map { |key, item| "#{JSON.generate(key)}: #{javascript(item)}" }.join(', ')} }"
        end

        JSON.generate(value)
      end

      def initialize(source, page_name, widget)
        @source = source
        @page_name = page_name
        @widget = widget
        @index = document_index
        @values = property_values(widget['Object'])
      end

      def supported?
        type = widget_type
        type && type.fetch('WidgetId', nil) == WIDGET_ID &&
          primitive('datasource') == 'image' && image_uri
      end

      def render # rubocop:disable Metrics/AbcSize
        values = primitive_properties.merge(
          key: widget_key, '$widgetId': widget_key,
          imageObject: self.class.raw("WebStaticImageProperty({ image: { uri: #{JSON.generate(image_uri)} } })"),
          imageUrl: self.class.raw(self.class.expression(text_value('imageUrl'))),
          alternativeText: self.class.raw(self.class.expression(text_value('alternativeText'))),
          class: css_class
        )
        "React.createElement($Image, #{self.class.javascript(values)})"
      end # rubocop:enable Metrics/AbcSize

      private

      def primitive_properties
        @values.each_with_object({}) do |(key, (type, value)), result|
          compiled = case type
                     when 'Boolean' then value['PrimitiveValue'] == 'true'
                     when 'Integer' then value['PrimitiveValue'].to_i
                     when 'Enumeration' then value['PrimitiveValue'].to_s
                     end
          result[key.to_sym] = compiled unless compiled.nil?
        end
      end

      def primitive(key)
        pair = @values[key]
        return unless pair

        pair.last.fetch('PrimitiveValue', nil)
      end

      def text_value(key)
        pair = @values[key]
        return translated_text(nil) unless pair

        translated_text(pair.last.fetch('TextTemplate', nil))
      end

      def image_uri # rubocop:disable Metrics/AbcSize
        pair = @values['imageObject']
        reference = pair ? pair.last.fetch('Image', '').to_s : ''
        module_name, collection_name, image_name = reference.split('.', 3)
        unit = @source.units_of('Images$ImageCollection').find do |candidate|
          candidate.module_name == module_name && candidate.document['Name'] == collection_name
        end
        return unless unit

        image = array(unit.document['Images']).find { _1['Name'] == image_name }
        return unless image

        "img/#{[module_name, collection_name, image_name].join('$')}.#{image_format(image)}"
      end # rubocop:enable Metrics/AbcSize

      def translated_text(template)
        items = template ? array(template.dig('Template', 'Items')) : []
        items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          items.first&.fetch('Text', '') || ''
      end

      def widget_key = "p.#{@page_name}.#{@widget['Name']}"

      def css_class
        ["mx-name-#{@widget['Name']}", @widget.dig('Appearance', 'Class')]
          .map(&:to_s).reject(&:empty?).uniq.join(' ')
      end

      def property_values(object)
        properties = object ? array(object.fetch('Properties', nil)) : []
        properties.filter_map do |property|
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
