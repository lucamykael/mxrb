# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Editable query text; native parameter/access metadata stays in the sidecar.
    class Dataset
      class << self
        attr_reader :mendix_id

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          unless /\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/.match?(value.to_s)
            raise ArgumentError, 'dataset name must be qualified as Module.Name'
          end

          @mendix_name = value.to_s.freeze
          @mendix_id = SourceIdentity.resolve(self, :dataset, @mendix_name, id:)
          Registry.register(:dataset, @mendix_name, self)
        end

        def oql(value = nil)
          return @query unless value

          raise TypeError, 'dataset OQL must be a String' unless value.is_a?(String)

          @query = value.dup.freeze
        end

        def native_metadata(parameters: [], excluded: false)
          @parameters = parameters.map(&:to_s).freeze
          @excluded = excluded == true
        end

        def definition
          Runtime::OqlDatasets::Definition.new(mendix_name, oql, @parameters || [], @excluded == true)
        end
      end
    end

    # Query edits are reversible. Structural dataset edits require the native
    # model until parameters, access rules and document renames have a full DSL.
    class DatasetSynchronizer
      def initialize(project, manifest)
        @project = project
        @previous = manifest.modules.flat_map { _1.fetch('datasets', []) }
      end

      def synchronize!
        current = Registry.all(:dataset).values
        validate_identities!(current)
        plans = current.map { plan(_1) }
        return if plans.empty?

        @project.mpr.transaction { plans.each { |id, document| @project.mpr.update_unit(id, document) } }
        @project.refresh!
      end

      private

      def validate_identities!(current)
        return if current.map(&:mendix_id).sort == @previous.map { _1.fetch('id') }.sort

        raise ValidationError, 'dataset creation/removal requires the native model'
      end

      def validate_metadata!(dataset)
        previous = @previous.find { _1.fetch('id') == dataset.mendix_id }
        definition = dataset.definition
        unless previous.fetch('name') == definition.name && previous.fetch('parameters') == definition.parameters &&
               previous.fetch('excluded') == definition.excluded
          raise ValidationError, 'dataset rename/parameter/access metadata edits require the native model'
        end
      end

      def plan(dataset)
        validate_metadata!(dataset)
        document = @project.modules.flat_map(&:application_documents).find { _1[:id] == dataset.mendix_id }
        raise ValidationError, 'dataset source is missing from the native model' unless document

        value = document.fetch(:doc)
        value.fetch('Source')['Query'] = dataset.oql
        [dataset.mendix_id, value]
      end
    end
  end
end
