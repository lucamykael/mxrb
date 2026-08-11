# frozen_string_literal: true

require 'zip'

module Mxrb
  module Compiler
    # Serializes schema-described Mendix 6/7 custom widgets to their Dojo client contract.
    # rubocop:disable Metrics
    class LegacyCustomWidgetCompiler
      include ModelValues

      SUPPORTED_TYPES = %w[
        Attribute Boolean Decimal Entity EntityConstraint Enumeration Form Image Integer
        Microflow String System TranslatableString Object
      ].freeze

      attr_reader :widget_id

      def initialize(source, widget, language:)
        @source = source
        @widget = widget
        @language = language
        @widget_type = widget['Type'] || {}
        @widget_id = @widget_type['WidgetId'].to_s
        @schema_index = schema_index(@widget_type)
      end

      def supported?
        !widget_id.empty? && package_module? && properties(@widget['Object']).all? do |property|
          type = property_type(property)
          SUPPORTED_TYPES.include?(type) && supported_value?(type, property['Value'])
        end
      end

      def properties_hash
        properties(@widget['Object']).to_h do |property|
          schema = property_schema(property)
          [schema['PropertyKey'].to_s, compile_value(schema.dig('ValueType', 'Type'), property['Value'])]
        end
      end

      private

      def properties(object) = array(object&.fetch('Properties', nil))

      def property_schema(property)
        @schema_index[IO::BsonCodec.extract_id(property['TypePointer'])] || {}
      end

      def property_type(property) = property_schema(property).dig('ValueType', 'Type').to_s

      def supported_value?(type, value)
        value ||= {}
        return objects(value).all? { supported_object?(_1) } if type == 'Object'
        return !image_uri(value['Image']).nil? if type == 'Image' && !value['Image'].to_s.empty?

        true
      end

      def supported_object?(object)
        properties(object).all? do |property|
          type = property_type(property)
          SUPPORTED_TYPES.include?(type) && supported_value?(type, property['Value'])
        end
      end

      def compile_value(type, value)
        value ||= {}
        case type
        when 'Boolean' then value['PrimitiveValue'] == 'true'
        when 'Integer' then value['PrimitiveValue'].to_i
        when 'Decimal' then value['PrimitiveValue'].to_f
        when 'Enumeration', 'String', 'System' then value['PrimitiveValue'].to_s
        when 'TranslatableString' then translated(value['TranslatableValue'])
        when 'Entity' then value['EntityPath'].to_s
        when 'EntityConstraint' then value['XPathConstraint'].to_s
        when 'Attribute' then relative_attribute(value['AttributePath'])
        when 'Microflow' then value['Microflow'].to_s
        when 'Form' then value['Form'].to_s
        when 'Image' then value['Image'].to_s.empty? ? '' : image_uri(value['Image'])
        when 'Object' then objects(value).map { compile_object(_1) }
        end
      end

      def compile_object(object)
        properties(object).to_h do |property|
          schema = property_schema(property)
          [schema['PropertyKey'].to_s, compile_value(schema.dig('ValueType', 'Type'), property['Value'])]
        end
      end

      def objects(value) = array(value&.fetch('Objects', nil))

      def relative_attribute(path)
        value = path.to_s
        value.split('.').last.to_s
      end

      def translated(text)
        items = array(text&.fetch('Items', nil))
        items.find { _1['LanguageCode'] == @language }&.fetch('Text', '') ||
          items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          items.first&.fetch('Text', '') || ''
      end

      def image_uri(reference)
        module_name, collection_name, image_name = reference.to_s.split('.', 3)
        unit = @source.units_of('Images$ImageCollection').find do |candidate|
          candidate.module_name == module_name && candidate.document['Name'] == collection_name
        end
        image = array(unit&.document&.fetch('Images', nil)).find { _1['Name'] == image_name }
        unless image
          return system_image_uri(collection_name, image_name) if module_name == 'System'

          return
        end

        "img/#{module_name}$#{image_name}.#{image_format(image)}"
      end

      def system_image_uri(collection_name, image_name)
        return if collection_name != 'Images' || image_name.to_s.empty?

        extension = %w[Error Running Completed Module].include?(image_name) ? 'gif' : 'png'
        "img/System$#{image_name}.#{extension}"
      end

      def schema_index(root)
        index = {}
        visit = lambda do |value|
          case value
          when Hash
            id = IO::BsonCodec.extract_id(value['$ID'])
            index[id] = value if id
            value.each_value { visit.call(_1) }
          when Array then value.each { visit.call(_1) }
          end
        end
        visit.call(root)
        index
      end

      def package_module?
        return true unless @source.is_a?(SourceModel)

        entry = "#{widget_id.tr('.', '/')}.js"
        root = File.join(File.dirname(@source.path), 'widgets')
        return true if File.file?(File.join(root, entry))

        Dir.glob(File.join(root, '*.mpk')).any? do |path|
          Zip::File.open(path) { _1.find_entry(entry) }
        rescue Zip::Error
          false
        end
      end
    end
    # rubocop:enable Metrics
  end
end
