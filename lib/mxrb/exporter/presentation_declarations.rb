# frozen_string_literal: true

module Mxrb
  class Exporter
    # Declares image and icon collections, layouts, page templates, building blocks and snippets as Ruby.
    module PresentationDeclarations
      private

      def image_collection_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:image_collection, document, {
                               images: bson_items(doc['Images']).map do |image|
                                 {
                                   id: document_id(image), name: image.fetch('Name'),
                                   format: image.fetch('ImageFormat', ''),
                                   data: code_action_binary_spec(image.fetch('Image'))
                                 }
                               end,
                               documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden'),
                               images_marker: bson_marker(doc['Images'], 2)
                             })
      end

      def custom_icon_collection_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:custom_icon_collection, document, {
                               collection_class: doc.fetch('CollectionClass', ''), prefix: doc.fetch('Prefix', ''),
                               font: code_action_binary_spec(doc.fetch('FontData')),
                               icons: bson_items(doc['Icons']).map do |icon|
                                 {
                                   id: document_id(icon), name: icon.fetch('Name'),
                                   character_code: icon.fetch('CharacterCode', 0),
                                   tags: bson_items(icon['Tags']), tags_marker: bson_marker(icon['Tags'], 2)
                                 }
                               end,
                               documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden'),
                               icons_marker: bson_marker(doc['Icons'], 2)
                             })
      end

      def layout_document_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:layout_document, document, {
                               appearance: presentation_value_spec(doc['Appearance']),
                               canvas_height: doc.fetch('CanvasHeight', 0), canvas_width: doc.fetch('CanvasWidth', 0),
                               content: presentation_value_spec(doc['Content']),
                               documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden')
                             })
      end

      def page_template_document_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:page_template_document, document, {
                               appearance: presentation_value_spec(doc['Appearance']),
                               canvas_height: doc.fetch('CanvasHeight', 0), canvas_width: doc.fetch('CanvasWidth', 0),
                               display_name: doc.fetch('DisplayName', ''),
                               documentation: doc.fetch('Documentation', ''),
                               documentation_url: doc.fetch('DocumentationUrl', ''), excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden'),
                               image: presentation_value_spec(doc['ImageData']),
                               layout_call: presentation_value_spec(doc['LayoutCall']),
                               template_category: doc.fetch('TemplateCategory', ''),
                               template_category_weight: doc.fetch('TemplateCategoryWeight', 0),
                               template_type: presentation_value_spec(doc['TemplateType'])
                             })
      end

      def building_block_document_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:building_block_document, document, {
                               canvas_height: doc.fetch('CanvasHeight', 0), canvas_width: doc.fetch('CanvasWidth', 0),
                               display_name: doc.fetch('DisplayName', ''),
                               documentation: doc.fetch('Documentation', ''),
                               documentation_url: doc.fetch('DocumentationUrl', ''), excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden'),
                               image: presentation_value_spec(doc['ImageData']), platform: doc.fetch('Platform', ''),
                               template_category: doc.fetch('TemplateCategory', ''),
                               template_category_weight: doc.fetch('TemplateCategoryWeight', 0),
                               widgets: presentation_value_spec(doc['Widgets'])
                             })
      end

      def snippet_document_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:snippet_document, document, {
                               canvas_height: doc.fetch('CanvasHeight', 0), canvas_width: doc.fetch('CanvasWidth', 0),
                               documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden'),
                               parameters: presentation_value_spec(doc['Parameters']),
                               snippet_type: doc.fetch('Type', ''),
                               variables: presentation_value_spec(doc['Variables']),
                               widgets: presentation_value_spec(doc['Widgets'])
                             })
      end

      def presentation_value_spec(value)
        case value
        when BSON::Binary
          { binary: Base64.strict_encode64(value.data), subtype: value.type.to_sym }
        when Array
          presentation_array_spec(value)
        when Hash
          presentation_hash_spec(value)
        else
          value
        end
      end

      def presentation_array_spec(value)
        return value.map { presentation_value_spec(_1) } unless value.first.is_a?(Integer)

        parsed = IO::BsonCodec.parse_array(value)
        {
          collection: parsed.fetch(:items).map { presentation_value_spec(_1) },
          marker: parsed.fetch(:marker)
        }
      end

      def presentation_hash_spec(value)
        if value['$Type']
          fields = value.reject { |key, _| %w[$ID $Type].include?(key) }
                        .transform_values { presentation_value_spec(_1) }
          return { node_type: value.fetch('$Type'), id: document_id(value), fields: }
        end

        { map: value.transform_values { presentation_value_spec(_1) } }
      end
    end
  end
end
