# frozen_string_literal: true

require_relative 'support'

module Mxrb
  module Uml
    # Builds call-chain sequence diagrams from the existing semantic index.
    # rubocop:disable Metrics
    class SequenceDiagram
      CALLABLE_KINDS = %i[microflow nanoflow].freeze
      MAX_DEPTH = 100

      def initialize(index, root: nil, module_name: nil, depth: 2)
        raise ArgumentError, 'choose either root or module_name' if root && module_name
        raise ArgumentError, 'root or module_name is required' unless root || module_name

        @index = index
        @root = root
        @module_name = module_name
        @depth = Integer(depth)
        raise ArgumentError, 'depth must be zero or greater' if @depth.negative?
        raise ArgumentError, "depth cannot exceed #{MAX_DEPTH}" if @depth > MAX_DEPTH

        @edges, @selected = root ? root_graph : module_graph
        @participants = participants
      end

      def to_mermaid
        lines = ['sequenceDiagram']
        @participants.each do |artifact|
          lines << %(  participant #{participant_id(artifact)} as #{Support.mermaid_text(artifact.qualified_name)})
        end
        @edges.each do |source, target|
          lines << "  #{participant_id(source)}->>#{participant_id(target)}: call"
        end
        append_mermaid_empty_note(lines) if @edges.empty?
        "#{lines.join("\n")}\n"
      end

      def to_plantuml
        lines = ['@startuml']
        @participants.each do |artifact|
          lines << %(participant "#{Support.plantuml_text(artifact.qualified_name)}" as #{participant_id(artifact)})
        end
        @edges.each do |source, target|
          lines << "#{participant_id(source)} -> #{participant_id(target)} : call"
        end
        lines << 'note "No call relationships found" as MXRB' if @edges.empty?
        lines << '@enduml'
        "#{lines.join("\n")}\n"
      end

      private

      def root_graph
        root = @index.find(@root)
        raise ArgumentError, "microflow not found: #{@root}" unless root && CALLABLE_KINDS.include?(root.kind)

        edges = []
        visited = {}
        visit = lambda do |source, level|
          return if level >= @depth || visited.key?(source.id)

          visited[source.id] = true
          callees(source).each do |target|
            edges << [source, target]
            visit.call(target, level + 1)
          end
        end
        visit.call(root, 0)
        [edges.uniq { [_1.id, _2.id] }, [root]]
      end

      def module_graph
        sources = @index.artifacts.select do |artifact|
          artifact.module_name == @module_name.to_s && CALLABLE_KINDS.include?(artifact.kind)
        end
        raise ArgumentError, "module not found or has no microflows: #{@module_name}" if sources.empty?

        edges = sources.flat_map do |source|
          callees(source).filter_map do |target|
            [source, target] if target.module_name == @module_name.to_s
          end
        end
        edges = edges.uniq { [_1.id, _2.id] }
        [edges, sources]
      end

      def callees(source)
        @index.references_from(source).filter_map do |reference|
          reference.target if reference.relation == :calls && CALLABLE_KINDS.include?(reference.target.kind)
        end.uniq(&:id)
      end

      def participants
        (@selected + @edges.flatten).uniq(&:id).sort_by(&:qualified_name)
      end

      def append_mermaid_empty_note(lines)
        participant = @participants.first
        lines << if participant
                   "  Note over #{participant_id(participant)}: No call relationships found"
                 else
                   '  Note over MXRB: No call relationships found'
                 end
      end

      def participant_id(artifact) = Support.identifier(artifact.qualified_name, prefix: 'participant')
    end
    # rubocop:enable Metrics
  end
end
