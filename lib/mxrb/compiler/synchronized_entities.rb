# frozen_string_literal: true

module Mxrb
  module Compiler
    # The entities a native profile synchronizes in Mendix 11: the persistable
    # entities of the project, specializations of persistable System entities
    # included, and the System entities Studio Pro shows.
    class SynchronizedEntities
      include ModelValues

      # System entities Studio Pro does not show, which MxBuild leaves out of the
      # offline configuration of a native profile.
      INTERNAL_SYSTEM_ENTITIES = %w[
        System.AutoCommitEntry System.BackgroundJob System.ChangeHash System.OfflineCreatedGuids
        System.OfflineSynchronizationHistory System.PrivateFileDocument System.Thumbnail System.UnreferencedFile
        System.WorkflowActivity System.WorkflowActivityUserTaskOutcome System.WorkflowVersion
      ].freeze

      def initialize(source)
        @source = source
      end

      def names
        @names ||= begin
          kinds = entity_kinds
          kinds.keys.select { persistable?(_1, kinds) } + system_entities
        end
      end

      private

      def system_entities
        @system_entities ||= begin
          objects = Runtime::SystemMetamodel.for(@source.version).fetch('objects')
          objects.select { _1['persistable'] }.map { _1['name'] } - INTERNAL_SYSTEM_ENTITIES
        end
      end

      def persistable?(entity, kinds, seen = [])
        return system_entities.include?(entity) unless kinds.key?(entity)
        return false if seen.include?(entity)

        kind = kinds[entity]
        kind.is_a?(String) ? persistable?(kind, kinds, seen + [entity]) : kind
      end

      # Each project entity: whether it is persistable, or the generalization that decides.
      def entity_kinds
        @source.units_of('DomainModels$DomainModel').each_with_object({}) do |unit, kinds|
          array(unit.document['Entities']).each do |entity|
            generalization = entity['MaybeGeneralization'] || {}
            kinds["#{unit.module_name}.#{entity['Name']}"] =
              if generalization['$Type'] == 'DomainModels$NoGeneralization' then generalization['Persistable'] == true
              else generalization['Generalization'].to_s
              end
          end
        end
      end
    end
  end
end
