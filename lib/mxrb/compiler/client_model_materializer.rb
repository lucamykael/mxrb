# frozen_string_literal: true

module Mxrb
  module Compiler
    ClientModelMaterialization = Data.define(:model_path, :pages, :navigation_documents)

    # Materializes Runtime page descriptors and navigation documents.
    class ClientModelMaterializer
      TYPES = %w[Forms$Page Navigation$NavigationDocument].freeze

      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        path = File.join(@deployment, 'model', 'model.mdp')
        package = ModelPackage.read(path)
        pages = source.units_of('Forms$Page').map { PageDocumentCompiler.new(source).compile(_1) }
        navigation = compile_navigation(source, package)
        write(path, package, pages + navigation)
        ClientModelMaterialization.new(
          model_path: path, pages: pages.length, navigation_documents: navigation.length
        )
      end

      private

      def compile_navigation(source, package)
        compiler = NavigationDocumentCompiler.new(
          RuntimeModelSchema.new(package, version: source.version)
        )
        source.units_of('Navigation$NavigationDocument').map { compiler.compile(_1) }
      end

      def write(path, package, documents)
        documents.reduce(package) { |result, document| result.upsert(document) }.write(path)
      end
    end
  end
end
