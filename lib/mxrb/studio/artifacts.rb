# frozen_string_literal: true

require 'prism'

module Mxrb
  module Studio
    # Reads Ruby project files without evaluating them: parse diagnostics with
    # exact locations, and the Mendix artifacts a file declares (`entity
    # :Order do`, `page :Home do`, ...), qualified by the module folder.
    module Artifacts
      KINDS = %w[
        entity enumeration microflow nanoflow page snippet layout building_block page_template rule
        constant java_action javascript_action scheduled_event regular_expression image_collection
        json_structure xml_schema import_mapping export_mapping message_definition rest_client
        published_rest_service consumed_rest_service published_odata_service consumed_odata_service
        workflow menu oql_view dto
      ].freeze

      module_function

      def diagnostics(text, file:)
        result = Prism.parse(text)
        (result.errors.map { diagnostic(_1, file, 'error') } +
          result.warnings.map { diagnostic(_1, file, 'warning') })
      end

      def diagnostic(item, file, severity)
        location = item.location
        { file:, line: location.start_line, column: location.start_column + 1, end_line: location.end_line,
          end_column: location.end_column + 1, severity:, message: item.message }
      end

      # Declarations with their kind, name, qualified name and line.
      def declarations(text, path: nil)
        result = Prism.parse(text)
        return [] if result.failure?

        found = []
        visit(result.value) { found << declaration(_1, path) }
        found.compact
      end

      def visit(node, &block)
        yield node if node.is_a?(Prism::CallNode) && node.receiver.nil? && KINDS.include?(node.name.to_s)
        node.compact_child_nodes.each { visit(_1, &block) }
      end

      def declaration(node, path)
        arguments = node.arguments
        argument = arguments.arguments.first if arguments
        name = case argument
               when Prism::SymbolNode then argument.unescaped
               when Prism::StringNode then argument.unescaped
               end
        return unless name

        container = module_name(path)
        qualified = name.include?('.') || container.nil? ? name : "#{container}.#{name}"
        { kind: node.name.to_s, name:, qualified_name: qualified, line: node.location.start_line }
      end

      def module_name(path)
        path.to_s[%r{\Amodules/([^/]+)/}, 1]
      end
    end
  end
end
