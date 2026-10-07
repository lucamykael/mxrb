# frozen_string_literal: true

require 'bigdecimal'
require 'strscan'

module Mxrb
  module Runtime
    # Compiles the supported WHERE grammar to typed Ruby readers, never SQL or eval.
    # Parsing validates every branch, including predicates over an empty source.
    # rubocop:disable Metrics/ClassLength
    class OqlPredicate
      Operand = Data.define(:kind, :read, :literal)
      TOKEN = %r{'(?:[^']|'')*'|[+-]?\d+(?:\.\d+)?|[A-Za-z_][A-Za-z0-9_]*|!=|<=|>=|[=<>()/.]}
      COMPARISONS = %w[= != < <= > >=].freeze
      KINDS = { integer: :number, long: :number, autonumber: :number, decimal: :number,
                string: :string, enumeration: :string, boolean: :boolean, datetime: :datetime }.freeze

      def initialize(text, scope, &resolve)
        @tokens = tokenize(text)
        @scope = scope
        @resolve = resolve
        @expression = disjunction
        error!('unexpected trailing tokens') unless @tokens.empty?
      end

      def call(row) = @expression.read.call(row) == true

      private

      def tokenize(text)
        scanner = StringScanner.new(text)
        tokens = []
        until scanner.eos?
          next if scanner.scan(/\s+/)

          token = scanner.scan(TOKEN)
          error!('invalid token') unless token
          tokens << token
        end
        tokens
      end

      def take(value)
        return false unless @tokens.first.to_s.casecmp?(value)

        @tokens.shift
        true
      end

      def expect(value)
        error!("expected #{value}") unless take(value)
      end

      def disjunction
        result = conjunction
        result = logical(result, conjunction, true) while take('OR')
        result
      end

      def conjunction
        result = negation
        result = logical(result, negation, false) while take('AND')
        result
      end

      def negation
        return invert(negation) if take('NOT')
        return comparison unless take('(')

        result = disjunction
        expect(')')
        result
      end

      def comparison
        left = operand
        if take('IS')
          negative = take('NOT')
          expect('NULL')
          result = null_test(left)
          return negative ? invert(result) : result
        end
        return boolean(left) unless COMPARISONS.include?(@tokens.first)

        operator = @tokens.shift
        compare(left, operand, operator)
      end

      def operand
        token = @tokens.shift.to_s
        return literal(:string, token[1...-1].gsub("''", "'")) if token.start_with?("'")
        return literal(:number, BigDecimal(token)) if token.match?(/\A[+-]?\d/)
        return literal(:null, nil) if token.casecmp?('NULL')
        return literal(:boolean, token.casecmp?('TRUE')) if %w[TRUE FALSE].include?(token.upcase)

        column(token)
      end

      def column(token)
        if take('.') || take('/')
          error!("unknown scope #{token}") unless token == @scope
          token = @tokens.shift.to_s
        end
        error!('expected an attribute or literal') unless token.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        type, reader = @resolve.call(token)
        kind = KINDS[type]
        error!("unsupported attribute type #{type}") unless kind
        Operand.new(kind, reader, false)
      end

      def literal(kind, value) = Operand.new(kind, ->(_row) { value }, true)

      def boolean(value)
        error!('expected a boolean predicate') unless %i[boolean null].include?(value.kind)
        value
      end

      def null_test(value) = Operand.new(:boolean, ->(row) { value.read.call(row).nil? }, false)

      def invert(value)
        boolean(value)
        Operand.new(:boolean, lambda { |row|
          result = value.read.call(row)
          result.nil? ? nil : !result
        }, false)
      end

      def logical(left, right, decisive)
        boolean(left)
        boolean(right)
        Operand.new(:boolean, lambda { |row|
          values = [left.read.call(row), right.read.call(row)]
          next decisive if values.include?(decisive)
          next nil if values.include?(nil)

          !decisive
        }, false)
      end

      def compare(left, right, operator)
        if %w[= !=].include?(operator) && [left.kind, right.kind].include?(:null)
          result = null_test(left.kind == :null ? right : left)
          return operator == '=' ? result : invert(result)
        end
        validate_comparison(left, right, operator)
        comparison_reader(left, right, operator)
      end

      def comparison_reader(left, right, operator)
        Operand.new(:boolean, lambda { |row|
          first = left.read.call(row)
          second = right.read.call(row)
          next null_comparison(left, right, operator) if first.nil? || second.nil?

          first.public_send(operator == '=' ? :== : operator, second)
        }, false)
      end

      def null_comparison(left, right, operator)
        return nil unless %w[= !=].include?(operator) && (left.literal || right.literal)

        operator == '!='
      end

      def validate_comparison(left, right, operator)
        types = [left.kind, right.kind].reject { _1 == :null }
        error!('incompatible comparison types') if types.uniq.length > 1
        return if %w[= !=].include?(operator) || types.all? { _1 == :number }

        error!('ordered comparisons require numbers')
      end

      def error!(message)
        raise NativeRuntimeError, "Unsupported OQL view WHERE: #{message}"
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
