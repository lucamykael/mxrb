# frozen_string_literal: true

module Mxrb
  module Compiler
    CodeActionMaterialization = Data.define(:model_path, :java_actions, :javascript_actions)

    # Materializes server and client action signatures into model.mdp.
    class CodeActionMaterializer
      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        path = File.join(@deployment, 'model', 'model.mdp')
        documents = compile_documents(source)
        documents.reduce(ModelPackage.read(path)) { |package, document| package.upsert(document) }.write(path)
        counts = documents.map { _1['$Type'] }.tally
        CodeActionMaterialization.new(
          model_path: path, java_actions: counts.fetch('JavaActions$JavaAction', 0),
          javascript_actions: counts.fetch('JavaScriptActions$JavaScriptAction', 0)
        )
      end

      private

      def compile_documents(source)
        compiler = CodeActionDocumentCompiler.new
        source.units.select { CodeActionDocumentCompiler::TYPES.include?(_1.document['$Type']) }
              .map { compiler.compile(_1) }
      end
    end
  end
end
