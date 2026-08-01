# frozen_string_literal: true

module Mxrb
  module Compiler
    SettingsMaterialization = Data.define(:model_path, :documents)

    # Synchronizes Runtime-visible project settings, including lifecycle microflows.
    class SettingsMaterializer
      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        path = File.join(@deployment, 'model', 'model.mdp')
        package = ModelPackage.read(path)
        compiler = SettingsDocumentCompiler.new(RuntimeModelSchema.new(package, version: source.version))
        documents = source.units_of('Settings$ProjectSettings').map { compiler.compile(_1) }
        documents.reduce(package) { |result, document| result.upsert(document) }.write(path)
        SettingsMaterialization.new(model_path: path, documents: documents.length)
      end
    end
  end
end
