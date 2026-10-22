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
        documents = compile_domains(source)
        path = File.join(@deployment, 'model', 'model.mdp')
        write_model(path, source, documents)
        DomainModelMaterialization.new(
          model_path: path, domain_models: documents.length,
          entities: documents.sum { _1.fetch('Entities').length }
        )
      end

      private

      def compile_domains(source)
        compiler = DomainDocumentCompiler.new(source)
        source.units_of('DomainModels$DomainModel').map { compiler.compile(_1) }
      end

      def write_model(path, source, documents)
        package = ModelPackage.read(path)
        documents += [system_domain(package, source)].compact
        documents.reduce(package) { |result, document| result.upsert(document) }.write(path)
      end

      # The access rules of the seeded System module name the user roles of the
      # project the seed came from; MxBuild writes the project's own user roles
      # that hold the same System module roles.
      def system_domain(package, source)
        seed = SystemModelSeed.for(source.version).domain_document
        document = seed && package.find(IO::BsonCodec.extract_id(seed['$ID']))&.document
        return unless document

        roles = UserRoleResolver.new(source)
        document.merge('Entities' => Array(document['Entities']).map { system_entity(_1, roles) })
      end

      def system_entity(entity, roles)
        rules = Array(entity['AccessRules']).map do |rule|
          rule.merge('AllowedUserRoles' => roles.resolve_seed(Array(rule['AllowedUserRoles'])))
        end
        entity.merge('AccessRules' => rules)
      end
    end
  end
end
