# frozen_string_literal: true

module Mxrb
  module Architecture
    class Validator
      Result = Data.define(:errors, :warnings) do
        def valid? = errors.empty?
      end

      def initialize(graph)
        @graph = graph
      end

      def validate
        errors = []
        warnings = []
        validate_targets(errors)
        validate_layers(errors)
        validate_cycles(errors)
        Result.new(errors.freeze, warnings.freeze)
      end

      def validate!
        result = validate
        return result if result.valid?

        raise ValidationError, "architecture validation failed:\n- #{result.errors.join("\n- ")}"
      end

      private

      def validate_targets(errors)
        @graph.edges.each do |edge|
          next if @graph.nodes.key?(edge.to)
          next if late_bound_page_nanoflow?(edge)
          next if platform_owned_target?(edge.to)

          errors << "#{edge.from} #{edge.relation} references missing #{edge.to}"
        end
      end

      def late_bound_page_nanoflow?(edge)
        from = @graph.nodes[edge.from]
        from&.kind == :page && edge.to.include?("::nanoflow::")
      end

      def platform_owned_target?(target)
        target.start_with?("System::")
      end

      def validate_layers(errors)
        @graph.edges.each do |edge|
          from = @graph.nodes[edge.from]
          to = @graph.nodes[edge.to]
          next unless from && to

          if from.kind == :page && to.kind == :repository
            errors << "#{from.id} cannot access repository #{to.id} directly"
          end
          if from.kind == :entity && edge.relation.to_s.start_with?("on_") && to.kind == :nanoflow
            errors << "#{from.id} lifecycle cannot call client-side #{to.id}"
          end
          # Entity-to-entity associations are allowed cross-module in Mendix domain model
          next if edge.relation == :association && from.kind == :entity && to.kind == :entity
          if from.module_name != to.module_name && !to.metadata.fetch(:public, false)
            errors << "#{from.id} references internal artifact #{to.id} from another module"
          end
        end
      end

      def validate_cycles(errors)
        adjacency = Hash.new { |h, k| h[k] = [] }
        @graph.edges.select { %i[calls].include?(_1.relation) }.each do |edge|
          adjacency[edge.from] << edge.to if @graph.nodes.key?(edge.to)
        end
        visiting = {}
        visited = {}
        stack = []

        visit = lambda do |node|
          return if visited[node]
          if visiting[node]
            start = stack.index(node) || 0
            errors << "call cycle detected: #{(stack[start..] + [node]).join(' -> ')}"
            return
          end
          visiting[node] = true
          stack << node
          adjacency[node].each { visit.call(_1) }
          stack.pop
          visiting.delete(node)
          visited[node] = true
        end
        @graph.nodes.each_key { visit.call(_1) }
      end
    end
  end
end
