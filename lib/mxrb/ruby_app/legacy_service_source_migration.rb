# frozen_string_literal: true

require 'ripper'

module Mxrb
  module RubyApp
    # Renames the deprecated service projection API while preserving embedded
    # application code byte-for-byte everywhere else.
    class LegacyServiceSourceMigration
      SERVICE_PATH = %r{\Aapp/services/.+\.rb\z}
      FLOW_KINDS = %w[microflow nanoflow].freeze
      SERVICE_CLASS = %w[Mxrb RubyApp Service].freeze
      private_constant :FLOW_KINDS, :SERVICE_CLASS

      def initialize(path:, source:)
        @path = path.to_s
        @source = source.to_s
      end

      def migrate
        return @source unless SERVICE_PATH.match?(@path)

        syntax = Ripper.sexp(@source)
        return @source unless syntax

        @replacements = {}
        @line_offsets = line_offsets
        visit(syntax, service: true, method: false)
        return @source if @replacements.empty?

        rewritten = @source.b.dup
        @replacements.sort_by(&:first).reverse_each do |offset, (length, replacement)|
          rewritten[offset, length] = replacement
        end
        rewritten.force_encoding(@source.encoding)
      end

      private

      def visit(node, service:, method:)
        return unless node.is_a?(Array)

        case node.first
        when :class
          visit(node[3], service: constant_path(node[2]) == SERVICE_CLASS, method: false)
          return
        when :module
          # Modules may namespace generated service classes, but their own
          # methods are not part of the Service instance API.
          visit(node[2], service: false, method: false)
          return
        when :sclass
          return
        when :def
          replace_identifier(node[1], 'native_call', 'execute_flow') if service
          node.drop(2).each { visit(_1, service:, method: true) }
          return
        when :defs
          # The legacy execution API is an instance method. Singleton method
          # definitions may describe unrelated application APIs.
          return
        when :command
          migrate_flow(node[1], node[2]) if service && !method
          replace_identifier(node[1], 'native_call', 'execute_flow') if service
        when :method_add_arg
          migrate_flow(call_identifier(node[1]), node[2]) if service && !method
        when :fcall, :vcall
          replace_identifier(node[1], 'native_call', 'execute_flow') if service
        when :call, :command_call
          if service && self_receiver?(node[1])
            replace_identifier(node[3], 'native_call', 'execute_flow')
            migrate_flow(node[3], node[4]) if node.first == :command_call && !method
          end
        end

        node.each { visit(_1, service:, method:) if _1.is_a?(Array) }
      end

      def migrate_flow(identifier, arguments)
        return unless FLOW_KINDS.include?(first_symbol_argument(arguments))

        replace_identifier(identifier, 'native', 'flow')
      end

      def call_identifier(node)
        return unless node.is_a?(Array)
        return node[1] if %i[fcall vcall].include?(node.first)
        return node[3] if node.first == :call && self_receiver?(node[1])

        nil
      end

      def first_symbol_argument(arguments)
        return unless arguments.is_a?(Array)

        arguments = arguments[1] if arguments.first == :arg_paren
        return unless arguments.is_a?(Array) && arguments.first == :args_add_block

        value = arguments[1]&.first
        return unless value.is_a?(Array) && value.first == :symbol_literal

        symbol = value[1]
        return unless symbol.is_a?(Array) && symbol.first == :symbol

        identifier = symbol[1]
        identifier[1] if identifier.is_a?(Array) && identifier.first == :@ident
      end

      def self_receiver?(node)
        node.is_a?(Array) && node.first == :var_ref && node[1]&.first == :@kw && node[1][1] == 'self'
      end

      def constant_path(node)
        return [] unless node.is_a?(Array)

        case node.first
        when :const_ref, :top_const_ref then [node.dig(1, 1)]
        when :var_ref then node[1]&.first == :@const ? [node[1][1]] : []
        when :const_path_ref then constant_path(node[1]) + [node.dig(2, 1)]
        else []
        end
      end

      def replace_identifier(token, original, replacement)
        return unless token.is_a?(Array) && token.first == :@ident && token[1] == original

        line, column = token[2]
        offset = @line_offsets.fetch(line - 1) + column
        @replacements[offset] = [original.bytesize, replacement]
      end

      def line_offsets
        offset = 0
        @source.lines.map do |line|
          start = offset
          offset += line.bytesize
          start
        end
      end
    end
  end
end
