# frozen_string_literal: true

module Mxrb
  module Compiler
    SystemQueueMaterialization = Data.define(:model_path, :queues)

    # Adds the Runtime's built-in System workflow queues absent from editor MPRs.
    class SystemQueueMaterializer
      QUEUES = [
        %w[cc8b48dd-2c7e-4aa0-a614-3c683349cb72 MendixWorkflows-WorkflowExecution 5
           3ba681ba-b94c-5f4a-82cb-d9e75947cb18],
        %w[9d554d4e-7cf8-4a35-9504-a9f600f28e41 MendixWorkflows-DefaultTaskExecution 3
           b06495bf-e4c6-5e62-8e98-56b7a852f440]
      ].freeze

      def initialize(mpr_path, deployment:)
        @version = SourceModel.read(mpr_path).version
        @deployment = File.expand_path(deployment)
      end

      def materialize # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        path = File.join(@deployment, 'model', 'model.mdp')
        package = QUEUES.reduce(ModelPackage.read(path)) do |model, queue|
          existing = model.documents.find { _1['QualifiedName'] == "System.#{queue[1]}" }
          ids = if existing
                  [existing['$ID'], existing.dig('Config', '$ID')]
                else
                  [queue[0], queue[3]]
                end
          model.upsert(document(ids[0], queue[1], queue[2], ids[1]))
        end
        package.write(path)
        SystemQueueMaterialization.new(model_path: path, queues: QUEUES.length)
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

      def document(id, name, parallelism, config_id)
        {
          '$ID' => id, '$Type' => 'Queues$Queue',
          'Config' => queue_config(config_id, parallelism),
          'Name' => name, 'QualifiedName' => "System.#{name}"
        }
      end

      def queue_config(id, parallelism)
        config = { '$ID' => id, '$Type' => 'Queues$BasicQueueConfig' }
        return config.merge('Parallelism' => parallelism.to_i) if @version.to_i < 10

        config.merge('ParallelismExpression' => parallelism, 'ClusterWide' => false)
      end
    end
  end
end
