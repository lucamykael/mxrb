# frozen_string_literal: true

module Mxrb
  module Compiler
    MicroflowMaterialization = Data.define(:model_path, :microflows, :nanoflows, :rules)

    # Materializes microflows, nanoflows, and rules using the version-matched Runtime schema.
    class MicroflowMaterializer
      TYPES = %w[Microflows$Microflow Microflows$Nanoflow Microflows$Rule].freeze
      # The module roles the System module's own microflows allow, which MxBuild
      # turns into the project's user roles.
      SYSTEM_FLOW_ROLES = { 'System.ShowHomePage' => %w[System.Administrator System.User] }.freeze

      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        Adapter.for(source.version)
        path = File.join(@deployment, 'model', 'model.mdp')
        package = ModelPackage.read(path)
        documents = compile_documents(source, package)
        write_model(path, package, documents)
        result(path, documents)
      end

      private

      def compile_documents(source, package)
        compiler = MicroflowDocumentCompiler.new(
          source, RuntimeModelSchema.new(package, version: source.version)
        )
        flows = source.units.select { TYPES.include?(_1.document['$Type']) && _1.document['Excluded'] != true }
        flows.map { compiler.compile(_1) } +
          system_documents(package, compiler)
      end

      def system_documents(package, compiler)
        package.documents.filter_map do |document|
          roles = SYSTEM_FLOW_ROLES[document['QualifiedName']]
          document.merge('ModelerAllowedUserRoles' => compiler.user_roles_for(roles)) if roles
        end
      end

      def write_model(path, package, documents)
        documents.reduce(package) { |result, document| result.upsert(document) }.write(path)
      end

      def result(path, documents)
        counts = documents.map { _1['$Type'] }.tally
        MicroflowMaterialization.new(
          model_path: path, microflows: counts.fetch('Microflows$Microflow', 0),
          nanoflows: counts.fetch('Microflows$Nanoflow', 0), rules: counts.fetch('Microflows$Rule', 0)
        )
      end
    end
  end
end
