# frozen_string_literal: true

module Mxrb
  module Semantic
    class MovePlan
      attr_reader :source, :target, :before_container, :containment_name

      def initialize(project:, source:, target:, before_container:, containment_name:)
        @project = project
        @source = source
        @target = target
        @before_container = before_container
        @containment_name = containment_name
        @applied = false
      end

      def after_container = target.unit_id
      def empty? = before_container == after_container
      def applied? = @applied

      def apply!
        raise ArgumentError, "move plan was already applied" if applied?

        unless empty?
          @project.mpr.transaction do
            @project.mpr.relocate_unit(
              source.unit_id,
              container_uuid: after_container,
              containment_name:
            )
          end
        end
        @project.refresh!
        @applied = true
        self
      end
    end

    # Cross-module move: relocates a unit AND renames its qualified name across
    # the project so that all references stay consistent.
    class CrossModuleMovePlan
      attr_reader :source, :target, :before_container, :rename_changes

      def initialize(project:, source:, target:, rename_plan:, before_container:, containment_name:)
        @project = project
        @source = source
        @target = target
        @rename_plan = rename_plan
        @before_container = before_container
        @containment_name = containment_name
        @applied = false
      end

      def after_container = target.unit_id
      def empty? = false
      def rename_changes = @rename_plan.changes
      def applied? = @applied

      def apply!
        raise ArgumentError, "cross-module move plan was already applied" if applied?

        @project.mpr.transaction do
          @rename_plan.documents.each do |unit_id, doc|
            @project.mpr.update_unit(unit_id, doc)
          end
          @project.mpr.relocate_unit(
            @source.unit_id,
            container_uuid: @target.unit_id,
            containment_name: @containment_name
          )
        end
        @project.refresh!
        @applied = true
        self
      end
    end

    class Mover
      EMBEDDED_KINDS = %i[module entity attribute association].freeze
      CONTAINER_KINDS = %i[module folder].freeze

      def initialize(project)
        @project = project
      end

      def plan(name, to:)
        source = resolve(name)
        target = resolve(to)
        validate_kinds(source, target)

        raw = @project.raw_unit(source.unit_id)
        raise ArgumentError, "#{source.qualified_name} is not a movable unit" unless raw
        if descendant_ids(source.unit_id).include?(target.unit_id)
          raise ArgumentError, "cannot move #{source.qualified_name} into its descendant"
        end

        if source.module_name != target.module_name
          plan_cross_module(source, target, raw)
        else
          MovePlan.new(
            project: @project,
            source:,
            target:,
            before_container: raw.fetch("ContainerID"),
            containment_name: raw.fetch("ContainmentName")
          )
        end
      end

      private

      def plan_cross_module(source, target, raw)
        new_name = "#{target.module_name}.#{source.name}"
        rename_plan = Renamer.new(@project).plan(source.qualified_name, to: new_name, cross_module: true)
        CrossModuleMovePlan.new(
          project: @project,
          source:,
          target:,
          rename_plan:,
          before_container: raw.fetch("ContainerID"),
          containment_name: raw.fetch("ContainmentName")
        )
      end

      def resolve(name)
        artifact = @project.find_artifact(name)
        return artifact if artifact

        matches = @project.semantic_index.find_all(name)
        raise KeyError, "unknown Mendix artifact #{name.inspect}" if matches.empty?
        raise ArgumentError, "ambiguous Mendix artifact #{name.inspect}" if matches.size > 1

        matches.first
      end

      def validate_kinds(source, target)
        if EMBEDDED_KINDS.include?(source.kind)
          raise ArgumentError, "#{source.kind} cannot be moved as a standalone unit"
        end
        return if CONTAINER_KINDS.include?(target.kind)

        raise ArgumentError, "#{target.qualified_name} is not a module or folder"
      end

      def descendant_ids(unit_id)
        direct = @project.children_of(unit_id)
        direct.flat_map do |child|
          [child.fetch("UnitID"), *descendant_ids(child.fetch("UnitID"))]
        end
      end
    end
  end
end
