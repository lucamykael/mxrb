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

    # Reversible declarations for reusable Mendix presentation documents.
    # Block declarations use the schema-checked Forms model. Keyword declarations
    # remain available only as a compatibility reader for older exported sources.
    # rubocop:disable Metrics/ParameterLists
    module PresentationDocuments
      include PresentationValues

      def layout_document(name, **options, &block)
        return typed_forms_document(name, 'Forms$Layout', &block) if block

        presentation_document(
          name, 'Forms$Layout', unit_id: options[:unit_id], container_id: options[:container_id], fields: {
          'Appearance' => options.fetch(:appearance),
          'CanvasHeight' => options.fetch(:canvas_height).to_i,
          'CanvasWidth' => options.fetch(:canvas_width).to_i,
          'Content' => options.fetch(:content),
          'Documentation' => options.fetch(:documentation, '').to_s,
          'Excluded' => options.fetch(:excluded, false) == true,
          'ExportLevel' => options.fetch(:export_level, 'Hidden').to_s
        })
      end

      def page_template_document(name, **options, &block)
        return typed_forms_document(name, 'Forms$PageTemplate', &block) if block

        presentation_document(
          name, 'Forms$PageTemplate', unit_id: options[:unit_id], container_id: options[:container_id], fields: {
          'Appearance' => options.fetch(:appearance),
          'CanvasHeight' => options.fetch(:canvas_height).to_i,
          'CanvasWidth' => options.fetch(:canvas_width).to_i,
          'DisplayName' => options.fetch(:display_name).to_s,
          'Documentation' => options.fetch(:documentation).to_s,
          'DocumentationUrl' => options.fetch(:documentation_url).to_s,
          'Excluded' => options.fetch(:excluded) == true,
          'ExportLevel' => options.fetch(:export_level).to_s,
          'ImageData' => options.fetch(:image), 'LayoutCall' => options.fetch(:layout_call),
          'TemplateCategory' => options.fetch(:template_category).to_s,
          'TemplateCategoryWeight' => options.fetch(:template_category_weight).to_i,
          'TemplateType' => options.fetch(:template_type)
        })
      end

      def building_block_document(name, **options, &block)
        return typed_forms_document(name, 'Forms$BuildingBlock', &block) if block

        presentation_document(
          name, 'Forms$BuildingBlock', unit_id: options[:unit_id], container_id: options[:container_id], fields: {
          'CanvasHeight' => options.fetch(:canvas_height).to_i,
          'CanvasWidth' => options.fetch(:canvas_width).to_i,
          'DisplayName' => options.fetch(:display_name).to_s,
          'Documentation' => options.fetch(:documentation).to_s,
          'DocumentationUrl' => options.fetch(:documentation_url).to_s,
          'Excluded' => options.fetch(:excluded) == true,
          'ExportLevel' => options.fetch(:export_level).to_s,
          'ImageData' => options.fetch(:image), 'Platform' => options.fetch(:platform).to_s,
          'TemplateCategory' => options.fetch(:template_category).to_s,
          'TemplateCategoryWeight' => options.fetch(:template_category_weight).to_i,
          'Widgets' => options.fetch(:widgets)
        })
      end

      def snippet_document(name, **options, &block)
        return typed_forms_document(name, 'Forms$Snippet', &block) if block

        presentation_document(
          name, 'Forms$Snippet', unit_id: options[:unit_id], container_id: options[:container_id], fields: {
          'CanvasHeight' => options.fetch(:canvas_height).to_i,
          'CanvasWidth' => options.fetch(:canvas_width).to_i,
          'Documentation' => options.fetch(:documentation).to_s,
          'Excluded' => options.fetch(:excluded) == true,
          'ExportLevel' => options.fetch(:export_level).to_s,
          'Parameters' => options.fetch(:parameters),
          'Type' => options.fetch(:snippet_type).to_s,
          'Variables' => options.fetch(:variables), 'Widgets' => options.fetch(:widgets)
        })
      end

      private

      def typed_forms_document(name, storage_type, &block)
        schema_type = storage_type.delete_prefix('Forms$')
        model = Forms::Node.build(schema_type, &block)
        model.name(name.to_s) if model.schema_type.property(:name) && !model.assigned?(:name)
        native_document(name, type: storage_type, deep_structure: {})
        @native_documents.last[:forms_model] = model
        model
      end

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
