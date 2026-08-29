# frozen_string_literal: true

module Mxrb
  module Dsl
    # Semantic project-level documents that do not belong to a Mendix module.
    module ProjectDocuments
      include PresentationValues

      def project_settings_document(settings:, unit_id:, container_id:, id: nil,
                                    containment: 'ProjectDocuments')
        project_native_document(
          'Settings$ProjectSettings', { 'Settings' => settings },
          unit_id:, container_id:, id:, containment:
        )
      end

      def system_text_collection(system_texts:, unit_id:, container_id:, id: nil,
                                 containment: 'ProjectDocuments')
        project_native_document(
          'Texts$SystemTextCollection', { 'SystemTexts' => system_texts },
          unit_id:, container_id:, id:, containment:
        )
      end

      private

      def project_native_document(type, fields, unit_id:, container_id:, id:, containment:) # rubocop:disable Metrics/ParameterLists
        document = presentation_identity(id || unit_id).merge('$Type' => type)
        fields.each { |key, value| document[key] = presentation_value_document(value) }
        native_unit(
          unit_id, container_id:, containment:, deep_structure: document
        )
      end
    end
  end
end
