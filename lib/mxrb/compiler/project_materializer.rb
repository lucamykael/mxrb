# frozen_string_literal: true

require 'digest'

module Mxrb
  module Compiler
    ProjectMaterialization = Data.define(:model_path, :modules, :documents)

    # Rebuilds the Runtime project/module index after native document materialization.
    class ProjectMaterializer # rubocop:disable Metrics/ClassLength
      EDITORIAL_TYPES = %w[
        Projects$ModuleSettings Security$ModuleSecurity Folders$Folder Projects$Folder
      ].freeze

      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        path = File.join(@deployment, 'model', 'model.mdp')
        package = ModelPackage.read(path)
        project = compile_project(source, package, project_unit(source))
        package = write_modules(source, package)
        package = package.upsert(project)
        package = ensure_deployment_header(package, source)
        package = ProjectModelOrderer.new(package, project).order
        package.write(path)
        result(path, project)
      end

      private

      def compile_project(source, package, unit)
        existing = package.find(unit.id)&.document
        {
          '$ID' => unit.document['$ID'], '$Type' => unit.document['$Type'],
          'ProjectDocuments' => project_documents(source, package, existing),
          'Modules' => preserved_modules(source, existing, package) + compiled_modules(source, package)
        }
      end

      def project_documents(source, package, existing)
        units = source.units.select { _1.containment == 'ProjectDocuments' }
        source_documents = units.filter_map { reference(_1, package) }
        source_ids = source_documents.filter_map { IO::BsonCodec.extract_id(_1['$ID']) }
        preserved = Array(existing&.fetch('ProjectDocuments', nil)).reject do |document|
          source_ids.include?(IO::BsonCodec.extract_id(document['$ID']))
        end
        preserved + source_documents
      end

      def compile_module(source, package, module_unit) # rubocop:disable Metrics/AbcSize
        units = source.units.select { _1.module_name == module_unit.document['Name'] }
        domain = units.find { _1.document['$Type'] == 'DomainModels$DomainModel' }
        documents = units.reject { skip_document?(_1, module_unit, domain) }
                         .filter_map { reference(_1, package) }
        {
          '$ID' => module_unit.document['$ID'], '$Type' => module_unit.document['$Type'],
          'DomainModel' => reference(domain, package), 'AllDocuments' => documents
        }
      end

      def skip_document?(unit, module_unit, domain)
        unit == module_unit || unit == domain || EDITORIAL_TYPES.include?(unit.document['$Type'])
      end

      def reference(unit, package)
        return nil unless unit && package.find(unit.id)

        { '$ID' => unit.document['$ID'], '$Type' => unit.document['$Type'] }
      end

      def project_unit(source)
        source.units.find { _1.document['$Type'] == 'Projects$Project' } ||
          raise(CompilationError, 'MPR has no project document')
      end

      def preserved_modules(source, existing, package)
        return seeded_modules(source, package) unless existing

        source_ids = source.units_of('Projects$ModuleImpl').map(&:id)
        existing.fetch('Modules').reject { source_ids.include?(IO::BsonCodec.extract_id(_1['$ID'])) }
      end

      def seeded_modules(source, package)
        return [] unless package.find(SystemModelSeed::MODULE_ID)

        seed = SystemModelSeed.for(source.version)
        [seed.module_reference]
      end

      def compiled_modules(source, package)
        source.units_of('Projects$ModuleImpl').map { compile_module(source, package, _1) }
      end

      def write_modules(source, package)
        source.units_of('Projects$ModuleImpl').reduce(package) do |result, unit|
          document = {
            '$ID' => unit.document['$ID'], '$Type' => unit.document['$Type'],
            'Name' => unit.document['Name']
          }
          result.upsert(document)
        end
      end

      def result(path, project)
        modules = project.fetch('Modules')
        ProjectMaterialization.new(
          model_path: path, modules: modules.length, documents: document_count(modules)
        )
      end

      def document_count(modules) = modules.sum { _1.fetch('AllDocuments').length }

      def deployment_header?(package)
        package.documents.any? do |document|
          document['$Type'] == 'Projects$Project' && document.key?('DeploymentID')
        end
      end

      def ensure_deployment_header(package, source)
        return package if deployment_header?(package)

        package.with_appended(deployment_header(source, project_unit(source)))
      end

      def deployment_header(source, unit)
        {
          '$ID' => unit.document['$ID'], '$Type' => unit.document['$Type'],
          'DeploymentID' => Digest::SHA256.hexdigest(unit.id)[0, 16].to_i(16).to_s,
          'RuntimeVersion' => source.version, 'ModelVersion' => 'unversioned',
          'SprintrProjectName' => File.basename(source.path, File.extname(source.path))
        }
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
