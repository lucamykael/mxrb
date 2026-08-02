# frozen_string_literal: true

module Mxrb
  module Compiler
    # Orders model documents so containers precede children during Runtime resolution.
    class ProjectModelOrderer
      def initialize(package, project)
        @package = package
        @project = project
      end

      def order
        ordered = [@project, deployment_header]
        ordered.concat(resolve(@project.fetch('ProjectDocuments')))
        @project.fetch('Modules').each { append_module(ordered, _1) }
        ordered.compact!
        ordered.concat(remaining(ordered))
        ModelPackage.from_documents(ordered)
      end

      private

      def append_module(ordered, mod)
        ordered.concat(resolve([mod]))
        ordered.concat(resolve([mod.fetch('DomainModel')]))
        ordered.concat(resolve(mod.fetch('AllDocuments')))
      end

      def resolve(references)
        Array(references).filter_map do |reference|
          next unless reference

          id = IO::BsonCodec.extract_id(reference['$ID'])
          @package.entries.find { _1.id == id && !header?(_1.document) }&.document
        end
      end

      def deployment_header = @package.documents.find { header?(_1) }

      def remaining(ordered)
        used = ordered.map(&:object_id)
        @package.documents.reject do |document|
          used.include?(document.object_id) || document.equal?(@project) || header?(document)
        end
      end

      def header?(document)
        document['$Type'] == 'Projects$Project' && document.key?('DeploymentID')
      end
    end
  end
end
