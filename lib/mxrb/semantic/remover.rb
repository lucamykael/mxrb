# frozen_string_literal: true

module Mxrb
  module Semantic
    class RemovalPlan
      attr_reader :artifact, :incoming, :children

      def initialize(project:, artifact:, incoming:, children:)
        @project = project
        @artifact = artifact
        @incoming = incoming.freeze
        @children = children.freeze
        @applied = false
      end

      def safe? = incoming.empty? && children.empty?
      def applied? = @applied

      def apply!
        raise ArgumentError, "removal plan was already applied" if applied?
        unless safe?
          raise ArgumentError,
                "cannot remove #{artifact.qualified_name}: " \
                "#{incoming.size} incoming reference(s), #{children.size} child unit(s)"
        end

        @project.mpr.transaction { @project.mpr.delete_unit(artifact.unit_id) }
        @project.refresh!
        @applied = true
        self
      end
    end

    class Remover
      EMBEDDED_KINDS = %i[module entity attribute association].freeze

      def initialize(project)
        @project = project
      end

      def plan(name)
        artifact = resolve(name)
        if EMBEDDED_KINDS.include?(artifact.kind)
          raise ArgumentError,
                "#{artifact.kind} removal requires a typed domain-model mutation"
        end
        raw = @project.raw_unit(artifact.unit_id)
        raise ArgumentError, "#{artifact.qualified_name} is not a removable unit" unless raw

        incoming = @project.references_to(artifact)
                           .reject { _1.source.id == artifact.id }
        children = @project.children_of(artifact.unit_id)
        RemovalPlan.new(project: @project, artifact:, incoming:, children:)
      end

      private

      def resolve(name)
        artifact = @project.find_artifact(name)
        return artifact if artifact

        matches = @project.semantic_index.find_all(name)
        raise KeyError, "unknown Mendix artifact #{name.inspect}" if matches.empty?
        raise ArgumentError, "ambiguous Mendix artifact #{name.inspect}" if matches.size > 1

        matches.first
      end
    end
  end
end
