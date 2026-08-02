# frozen_string_literal: true

module Mxrb
  module Compiler
    DomainModelMaterialization = Data.define(:model_path, :domain_models, :entities)

    # Replaces or inserts Runtime domain-model documents in model.mdp.
    class DomainModelMaterializer
      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        Adapter.for(source.version)
        compiler = DomainDocumentCompiler.new(source)
        documents = source.units_of('DomainModels$DomainModel').map { compiler.compile(_1) }
        path = File.join(@deployment, 'model', 'model.mdp')
        write_model(path, documents)
        DomainModelMaterialization.new(
          model_path: path, domain_models: documents.length,
          entities: documents.sum { _1.fetch('Entities').length }
        )
      end

      private

      def write_model(path, documents)
        package = documents.reduce(ModelPackage.read(path)) { |result, document| result.upsert(document) }
        package.write(path)
      end
    end
  end
end
