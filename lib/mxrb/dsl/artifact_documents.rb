# frozen_string_literal: true

require 'securerandom'

module Mxrb
  module Dsl
    # Typed declarations for small module artifacts that otherwise need a
    # complete native-document hash. The native baseline remains authoritative
    # for unknown fields while these declarations expose the supported fields.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
    module ArtifactDocuments
      def task_queue(name, parallelism_expression: nil, parallelism: nil,
                     cluster_wide: false, documentation: '', excluded: false,
                     export_level: 'Hidden', unit_id: nil, container_id: nil,
                     config_id: nil)
        if parallelism_expression.nil? == parallelism.nil?
          raise ArgumentError,
                'task_queue requires exactly one of parallelism_expression or parallelism'
        end

        config = artifact_identity(config_id).merge('$Type' => 'Queues$BasicQueueConfig')
        if parallelism_expression.nil?
          config['Parallelism'] = Integer(parallelism)
        else
          config['ParallelismExpression'] = parallelism_expression.to_s
          config['ClusterWide'] = cluster_wide == true
        end
        native_document(
          name, type: 'Queues$Queue', unit_id:, container_id:,
                deep_structure: artifact_identity(unit_id).merge(
                  'Config' => config, 'Documentation' => documentation.to_s,
                  'Excluded' => excluded == true, 'ExportLevel' => export_level.to_s
                )
        )
      end

      def regular_expression(name, expression:, documentation: '', excluded: false,
                             export_level: 'Hidden', unit_id: nil, container_id: nil)
        native_document(
          name, type: 'RegularExpressions$RegularExpression', unit_id:, container_id:,
                deep_structure: artifact_identity(unit_id).merge(
                  'Documentation' => documentation.to_s, 'Excluded' => excluded == true,
                  'ExportLevel' => export_level.to_s, 'Expression' => expression.to_s
                )
        )
      end

      private

      def artifact_identity(id)
        { '$ID' => id.to_s.empty? ? SecureRandom.uuid : id.to_s }
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
  end
end
