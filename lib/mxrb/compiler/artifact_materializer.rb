# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    ArtifactMaterialization = Data.define(:model_path, :metadata_path, :documents, :scheduled_events)

    # Materializes executable non-flow artifacts and their Runtime metadata.
    class ArtifactMaterializer
      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        model_path = File.join(@deployment, 'model', 'model.mdp')
        metadata_path = File.join(@deployment, 'model', 'metadata.json')
        documents = compile_documents(source)
        write_model(model_path, documents)
        events = write_metadata(metadata_path, source)
        ArtifactMaterialization.new(
          model_path:, metadata_path:, documents: documents.length, scheduled_events: events.length
        )
      end

      private

      def compile_documents(source)
        compiler = ArtifactDocumentCompiler.new
        source.units.select { ArtifactDocumentCompiler::TYPES.include?(_1.document['$Type']) }
                    .map { compiler.compile(_1) }
      end

      def write_model(path, documents)
        documents.reduce(ModelPackage.read(path)) { |package, document| package.upsert(document) }
                 .write(path)
      end

      def write_metadata(path, source)
        events = source.units_of('ScheduledEvents$ScheduledEvent').map do |unit|
          { 'Name' => "#{unit.module_name}.#{unit.document['Name']}",
            'Description' => unit.document['Documentation'].to_s }
        end
        metadata = JSON.parse(File.read(path))
        metadata['ScheduledEvents'] = events
        File.write(path, JSON.pretty_generate(metadata))
        events
      end
    end
  end
end
