# frozen_string_literal: true

module Mxrb
  module Compiler
    # Normalizes MPR's BSON array convention into Runtime-native values.
    module ModelValues
      private

      def array(value) = IO::BsonCodec.parse_array(value)[:items]
      def plain_array(value) = value ? array(value).map { plain_value(_1) } : []
      def plain_document(value) = value ? plain_value(value) : nil

      def xpath_variables(constraint)
        constraint.to_s.scan(/\$([A-Za-z_]\w*)/).flatten.uniq
      end

      def object_page_parameters(document, names)
        indexed = page_parameter_types(document)
        entities = names.to_h { |name| [name, object_parameter_entity(indexed[name])] }
        entities if entities.values.all?
      end

      def page_parameter_types(document)
        array(document&.fetch('Parameters', nil)).filter_map do |parameter|
          next unless parameter.is_a?(Hash)

          [parameter['Name'].to_s, parameter['ParameterType'] || {}]
        end.to_h
      end

      def object_parameter_entity(type)
        return unless type&.fetch('$Type', nil) == 'DataTypes$ObjectType'

        entity = type['Entity'].to_s
        entity unless entity.empty?
      end

      def image_bytes(value)
        value.respond_to?(:data) ? value.data : value.to_s.b
      end

      def image_format(source) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        explicit = source['ImageFormat'].to_s.downcase
        return explicit unless explicit.empty?

        bytes = image_bytes(source['Image'])
        return 'png' if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
        return 'gif' if bytes.start_with?('GIF87a', 'GIF89a')
        return 'jpg' if bytes.start_with?("\xFF\xD8\xFF".b)
        return 'bmp' if bytes.start_with?('BM')
        return 'ico' if bytes.start_with?("\x00\x00\x01\x00".b)
        return 'webp' if bytes.start_with?('RIFF') && bytes.byteslice(8, 4) == 'WEBP'
        return 'svg' if bytes.byteslice(0, 1024).to_s.match?(/<svg\b/i)

        raise CompilationError, "cannot determine format for image #{source['Name'].inspect}"
      end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      def plain_value(value)
        case value
        when Hash then value.to_h { |key, child| [key, plain_value(child)] }
        when Array then array(value).map { plain_value(_1) }
        else value
        end
      end
    end
  end
end
