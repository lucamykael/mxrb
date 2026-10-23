# frozen_string_literal: true

require 'prism'

module Mxrb
  class Exporter
    # Reorganizes the generated, typed flow DSL without evaluating project Ruby.
    # The same calls are compiled, but activities and branch bodies have names.
    class MethodFlowSource # rubocop:disable Metrics/ClassLength
      DECLARATIONS = %i[
        parameter return_type documentation allow_concurrent_execution apply_entity_access
        mark_as_used excluded allowed_roles call uses_repository body_fingerprint
        annotations_authoritative annotation annotation_flow as_node node_ref return_node
        return_value end_flow error_event continue_loop break_loop argument
      ].freeze
      CONTRACT = %i[
        parameter return_type documentation allow_concurrent_execution apply_entity_access
        mark_as_used excluded allowed_roles call uses_repository body_fingerprint annotations_authoritative
      ].freeze
      STRUCTURES = %i[decision type_decision rule_decision loop_over while_loop rescue_all].freeze
      TERMINALS = %i[return_value end_flow error_event continue_loop break_loop].freeze
      KEYWORDS = %w[alias and begin break case class def defined do else elsif end ensure false for if
                    in module next nil not or redo rescue retry return self super then true undef
                    unless until when while yield BEGIN END].freeze
      GENERIC_CAPTION = /\A(?:create|change|retrieve|commit|delete|call|execute|activity|action)
                         (?:\s(?:object|variable|list|microflow|nanoflow|action))?\z/ix

      def initialize(source, captions: {})
        parsed = Prism.parse(source)
        raise SerializationError, 'cannot structure an invalid Ruby flow definition' unless parsed.success?

        @statements = parsed.value.statements&.body || []
        @captions = captions.transform_values(&:dup)
        @methods = []
        @used_names = []
        @reserved = (DECLARATIONS + Dsl::FlowBodyDsl.public_instance_methods +
          Dsl::FlowBuilder.public_instance_methods(false) + Object.instance_methods +
          %i[main_line flow_contract step decide call initialize native_call execute_flow compose within]).map(&:to_s)
      end

      def source(indent: 0)
        @source ||= method_groups.map.with_index { |definition, index| render_method(definition, index) }.join("\n\n")
        indent_lines(@source, indent)
      end

      def self.normalize(source)
        source.lines.map(&:strip).join("\n")
      end

      private

      def method_groups
        contract, body = @statements.partition { _1.is_a?(Prism::CallNode) && CONTRACT.include?(_1.name) }
        main = sequence(body)
        configuration = contract.empty? ? [] : [['flow_contract', contract.map { fragment(_1) }]]
        [['main_line', main], *configuration, *@methods]
      end

      def render_method(definition, index)
        name, lines = definition
        prefix = index == 1 ? "private\n\n" : ''
        "#{prefix}def #{name}\n#{indent_lines(lines.join("\n"), 2)}\nend"
      end

      def sequence(statements)
        statements.map { statement(_1) }
      end

      def statement(node)
        raise SerializationError, 'non-declaration statement in flow source' unless node.is_a?(Prism::CallNode)
        return decision(node) if node.name == :decision && simple_decision?(node)
        return structure(node) if STRUCTURES.include?(node.name)
        return fragment(node) if DECLARATIONS.include?(node.name)

        add_method(activity_name(node), [fragment(node)])
      end

      def simple_decision?(node)
        node.block.is_a?(Prism::BlockNode) && Array(node.block.body&.body).all? do |branch|
          branch.is_a?(Prism::CallNode) && branch.name == :on && branch.block.is_a?(Prism::BlockNode)
        end
      end

      def decision(node)
        branches = Array(node.block.body&.body).map { decision_branch(_1) }
        condition = node.arguments.arguments.first.slice
        "decide #{condition}, branches: { #{branches.join(', ')} }"
      end

      def decision_branch(branch)
        value = branch.arguments.arguments.first.slice
        nodes = Array(branch.block.body&.body)
        "#{value} => #{branch_reference("when_#{slug(value)}", nodes)}"
      end

      def branch_reference(label, nodes)
        return '-> {}' if nodes.empty?
        return "-> { #{fragment(nodes.first)} }" if nodes.size == 1 && TERMINALS.include?(nodes.first.name)

        ":#{branch_method(label, nodes)}"
      end

      def structure(node)
        return fragment(node) unless node.block.is_a?(Prism::BlockNode)

        with_callback(node, structure_method(node))
      end

      def structure_method(node)
        body = Array(node.block.body&.body)
        return add_method("#{node.name}_branches", body.map { scoped_branch(_1) }) \
          if %i[type_decision rule_decision].include?(node.name)

        label = node.name == :rescue_all ? 'handle_error' : "#{node.name}_body"
        branch_method(label, body)
      end

      def scoped_branch(branch)
        return fragment(branch) unless branch.is_a?(Prism::CallNode) && branch.block.is_a?(Prism::BlockNode)

        name = branch_method(branch_label(branch), Array(branch.block.body&.body))
        with_callback(branch, name)
      end

      def branch_label(branch)
        value = branch.arguments&.arguments&.first&.slice || 'otherwise'
        "#{branch.name}_#{slug(value)}"
      end

      def branch_method(label, body)
        lines = sequence(body)
        return lines.first if lines.size == 1 && @used_names.include?(lines.first)

        add_method(label, lines)
      end

      def with_callback(node, name)
        prefix = node.slice.byteslice(0, node.block.location.start_offset - node.location.start_offset).rstrip
        if node.closing_loc
          prefix.sub(/\)\z/, "#{node.arguments ? ', ' : ''}&step(:#{name}))")
        else
          "#{prefix}#{node.arguments ? ', ' : '('}&step(:#{name})#{node.arguments ? '' : ')'}"
        end
      end

      def fragment(node)
        first, *rest = node.slice.lines
        [first, *rest.map { _1.delete_prefix(' ' * node.location.start_column) }].join.rstrip
      end

      def activity_name(node)
        captions = @captions[self.class.normalize(node.slice)]
        caption = captions&.shift.to_s
        return slug(caption) unless caption.empty? || GENERIC_CAPTION.match?(caption)

        target = activity_target(node)
        [node.name.to_s, slug(target)].reject(&:empty?).join('_')
      end

      def activity_target(node)
        first = node.arguments&.arguments&.find { _1.is_a?(Prism::SymbolNode) || _1.is_a?(Prism::StringNode) }
        first&.unescaped.to_s
      end

      def add_method(label, lines)
        name = slug(label)
        name = 'activity' if name.empty?
        name = "activity_#{name}" if @reserved.include?(name) || KEYWORDS.include?(name) || name.match?(/\A\d/)
        name = unique_name(name)
        @used_names << name
        @methods << [name, lines]
        name
      end

      def unique_name(base)
        suffix = 1
        name = base
        while @used_names.include?(name)
          suffix += 1
          name = "#{base}_#{suffix}"
        end
        name
      end

      def slug(value)
        value.to_s.unicode_normalize(:nfkd).encode('ASCII', invalid: :replace, undef: :replace, replace: '')
             .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.gsub(/[^a-z\d]+/, '_').gsub(/\A_+|_+\z/, '')
      end

      def indent_lines(source, width)
        lines = source.lines
        margin = lines.reject { _1.strip.empty? }.map { _1[/\A */].length }.min || 0
        lines.map { _1.strip.empty? ? "\n" : "#{' ' * width}#{_1.delete_prefix(' ' * margin)}" }.join.rstrip
      end
    end
  end
end
