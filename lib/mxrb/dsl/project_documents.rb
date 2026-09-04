# frozen_string_literal: true

module Mxrb
  module Dsl
    # Semantic project-level documents that do not belong to a Mendix module.
    module ProjectDocuments
      include PresentationValues

      def mendix_project_id(value) = (@project_id = value.to_s)

      def project_settings(&block)
        raise ArgumentError, 'project_settings requires a block' unless block

        builder = Settings::ProjectBuilder.new
        builder.instance_eval(&block)
        @project_settings_model = builder.to_model
      end

      def project_settings_document(settings:, unit_id:, container_id:, id: nil,
                                    containment: 'ProjectDocuments')
        project_native_document(
          'Settings$ProjectSettings', { 'Settings' => settings },
          unit_id:, container_id:, id:, containment:
        )
      end

      def system_text_collection(system_texts: nil, unit_id: nil, container_id: nil, id: nil,
                                 containment: 'ProjectDocuments', &block)
        return typed_system_text_collection(system_texts, unit_id, container_id, id, &block) if block

        raise ArgumentError, 'system_texts, unit_id and container_id are required' unless
          system_texts && unit_id && container_id

        project_native_document(
          'Texts$SystemTextCollection', { 'SystemTexts' => system_texts },
          unit_id:, container_id:, id:, containment:
        )
      end

      private

      def typed_system_text_collection(system_texts, unit_id, container_id, id, &block)
        raise ArgumentError, 'typed system_text_collection does not accept storage keywords' if
          [system_texts, unit_id, container_id, id].any?

        collection = SystemTexts::Collection.build(&block)
        @system_texts = collection.to_h
        collection
      end

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
