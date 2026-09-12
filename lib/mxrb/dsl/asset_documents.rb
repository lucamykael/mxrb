# frozen_string_literal: true

require 'base64'
require 'securerandom'

module Mxrb
  module Dsl
    # Semantic declarations for image and custom-icon collections embedded in
    # the Mendix model.
    # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
    module AssetDocuments
      def image_collection(name, images:, documentation: '', excluded: false,
                           export_level: 'Hidden', images_marker: 2,
                           unit_id: nil, container_id: nil)
        document = asset_identity(unit_id).merge(
          'Documentation' => documentation.to_s, 'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'Images' => IO::BsonCodec.build_array(
            Array(images).map { image_asset_document(_1) }, marker: images_marker.to_i
          )
        )
        asset_native_document(
          name, 'Images$ImageCollection', document, unit_id:, container_id:
        )
      end

      def custom_icon_collection(name, collection_class:, prefix:, font:, icons:,
                                 documentation: '', excluded: false,
                                 export_level: 'Hidden', icons_marker: 2,
                                 unit_id: nil, container_id: nil)
        document = asset_identity(unit_id).merge(
          'CollectionClass' => collection_class.to_s, 'Documentation' => documentation.to_s,
          'Excluded' => excluded == true, 'ExportLevel' => export_level.to_s,
          'FontData' => asset_binary(font),
          'Icons' => IO::BsonCodec.build_array(
            Array(icons).map { custom_icon_document(_1) }, marker: icons_marker.to_i
          ),
          'Prefix' => prefix.to_s
        )
        asset_native_document(
          name, 'CustomIcons$CustomIconCollection', document, unit_id:, container_id:
        )
      end

      private

      def image_asset_document(source)
        spec = asset_spec(source)
        asset_identity(spec[:id]).merge(
          '$Type' => 'Images$Image', 'Image' => asset_binary(spec.fetch(:data)),
          'ImageFormat' => spec.fetch(:format, '').to_s, 'Name' => spec.fetch(:name).to_s
        )
      end

      def custom_icon_document(source)
        spec = asset_spec(source)
        asset_identity(spec[:id]).merge(
          '$Type' => 'CustomIcons$CustomIcon',
          'CharacterCode' => spec.fetch(:character_code, 0).to_i,
          'Name' => spec.fetch(:name).to_s,
          'Tags' => IO::BsonCodec.build_array(
            Array(spec[:tags]).map(&:to_s), marker: spec.fetch(:tags_marker, 2).to_i
          )
        )
      end

      def asset_binary(source)
        return source if source.is_a?(BSON::Binary)

        spec = asset_spec(source)
        BSON::Binary.new(
          Base64.strict_decode64(spec.fetch(:data).to_s),
          spec.fetch(:subtype, :generic).to_sym
        )
      end

      def asset_native_document(name, type, document, unit_id:, container_id:)
        native_document(
          name, type:, unit_id:, container_id:, containment: 'Documents',
                deep_structure: document
        )
      end

      def asset_identity(id)
        { '$ID' => id.to_s.empty? ? SecureRandom.uuid : id.to_s }
      end

      def asset_spec(value)
        value.to_h.transform_keys(&:to_sym)
      end
    end
    # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists
  end
end
