# frozen_string_literal: true

require 'base64'
require 'securerandom'

module Mxrb
  module Dsl
    # Decodes the Ruby-friendly recursive form representation shared by pages,
    # menus, layouts, templates, building blocks, and snippets.
    module PresentationValues
      private

      def presentation_value_document(value)
        case value
        when Array
          value.map { presentation_value_document(_1) }
        when Hash
          presentation_hash_document(value)
        else
          value
        end
      end

      def presentation_hash_document(value) # rubocop:disable Metrics/AbcSize
        spec = value.to_h.transform_keys { _1.respond_to?(:to_sym) ? _1.to_sym : _1 }
        return presentation_node_document(spec) if spec.key?(:node_type)
        return presentation_collection_document(spec) if spec.key?(:collection)
        return presentation_binary_document(spec) if spec.key?(:binary)
        return spec.fetch(:map).to_h.transform_values { presentation_value_document(_1) } if spec.key?(:map)

        value.to_h.transform_values { presentation_value_document(_1) }
      end

      def presentation_node_document(spec)
        fields = spec.fetch(:fields).to_h
        presentation_identity(spec[:id]).merge('$Type' => spec.fetch(:node_type).to_s).tap do |document|
          fields.each { |key, value| document[key.to_s] = presentation_value_document(value) }
        end
      end

      def presentation_collection_document(spec)
        IO::BsonCodec.build_array(
          Array(spec.fetch(:collection)).map { presentation_value_document(_1) },
          marker: spec.fetch(:marker, 2).to_i
        )
      end

      def presentation_binary_document(spec)
        BSON::Binary.new(
          Base64.strict_decode64(spec.fetch(:binary).to_s),
          spec.fetch(:subtype, :generic).to_sym
        )
      end

      def presentation_identity(id)
        { '$ID' => id.to_s.empty? ? SecureRandom.uuid : id.to_s }
      end
    end

    # Reversible Ruby declarations for reusable Mendix presentation documents.
    # Root contracts are typed; nested form nodes retain their Mendix property
    # names while IDs, collections, and binary values use Ruby-friendly specs.
    # rubocop:disable Metrics/ParameterLists
    module PresentationDocuments
      include PresentationValues

      def layout_document(name, appearance:, canvas_height:, canvas_width:, content:,
                          documentation: '', excluded: false, export_level: 'Hidden',
                          unit_id: nil, container_id: nil)
        presentation_document(name, 'Forms$Layout', unit_id:, container_id:, fields: {
          'Appearance' => appearance, 'CanvasHeight' => canvas_height.to_i,
          'CanvasWidth' => canvas_width.to_i, 'Content' => content,
          'Documentation' => documentation.to_s, 'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s
        })
      end

      def page_template_document(name, appearance:, canvas_height:, canvas_width:,
                                 display_name:, documentation:, documentation_url:,
                                 excluded:, export_level:, image:, layout_call:,
                                 template_category:, template_category_weight:,
                                 template_type:, unit_id: nil, container_id: nil)
        presentation_document(name, 'Forms$PageTemplate', unit_id:, container_id:, fields: {
          'Appearance' => appearance, 'CanvasHeight' => canvas_height.to_i,
          'CanvasWidth' => canvas_width.to_i, 'DisplayName' => display_name.to_s,
          'Documentation' => documentation.to_s, 'DocumentationUrl' => documentation_url.to_s,
          'Excluded' => excluded == true, 'ExportLevel' => export_level.to_s,
          'ImageData' => image, 'LayoutCall' => layout_call,
          'TemplateCategory' => template_category.to_s,
          'TemplateCategoryWeight' => template_category_weight.to_i,
          'TemplateType' => template_type
        })
      end

      def building_block_document(name, canvas_height:, canvas_width:, display_name:,
                                  documentation:, documentation_url:, excluded:, export_level:,
                                  image:, platform:, template_category:,
                                  template_category_weight:, widgets:,
                                  unit_id: nil, container_id: nil)
        presentation_document(name, 'Forms$BuildingBlock', unit_id:, container_id:, fields: {
          'CanvasHeight' => canvas_height.to_i, 'CanvasWidth' => canvas_width.to_i,
          'DisplayName' => display_name.to_s, 'Documentation' => documentation.to_s,
          'DocumentationUrl' => documentation_url.to_s, 'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s, 'ImageData' => image,
          'Platform' => platform.to_s, 'TemplateCategory' => template_category.to_s,
          'TemplateCategoryWeight' => template_category_weight.to_i, 'Widgets' => widgets
        })
      end

      def snippet_document(name, canvas_height:, canvas_width:, documentation:, excluded:,
                           export_level:, parameters:, snippet_type:, variables:, widgets:,
                           unit_id: nil, container_id: nil)
        presentation_document(name, 'Forms$Snippet', unit_id:, container_id:, fields: {
          'CanvasHeight' => canvas_height.to_i, 'CanvasWidth' => canvas_width.to_i,
          'Documentation' => documentation.to_s, 'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s, 'Parameters' => parameters,
          'Type' => snippet_type.to_s, 'Variables' => variables, 'Widgets' => widgets
        })
      end

      private

      def presentation_document(name, type, unit_id:, container_id:, fields:)
        document = presentation_identity(unit_id)
        fields.each { |key, value| document[key] = presentation_value_document(value) }
        native_document(
          name, type:, unit_id:, container_id:, containment: 'Documents',
                deep_structure: document
        )
      end
    end
    # rubocop:enable Metrics/ParameterLists
  end
end
