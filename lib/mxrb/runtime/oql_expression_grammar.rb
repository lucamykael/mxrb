# frozen_string_literal: true

require_relative 'oql_scalar'
require_relative 'oql_function_grammar'
require_relative 'oql_case_grammar'

module Mxrb
  module Runtime
    # Value expressions of OQL: arithmetic and string concatenation, with the
    # functions and CASE of the included grammars. Included by OqlPredicate,
    # which owns the token queue, column resolution and error reporting.
    module OqlExpressionGrammar
      include OqlFunctionGrammar
      include OqlCaseGrammar

      INTEGERS = %i[integer long autonumber].freeze

      private

      def additive
        result = multiplicative
        result = arithmetic(result, @tokens.shift, multiplicative) while %w[+ -].include?(@tokens.first)
        result
      end

      def multiplicative
        result = unary
        result = arithmetic(result, @tokens.shift, unary) while %w[* : %].include?(@tokens.first)
        result
      end

      def unary
        return negate(unary) if take('-')

        take('+')
        primary
      end

      def primary
        return call_operand if @tokens[1] == '(' && callable?(@tokens.first.to_s.upcase)
        return case_expression if take('CASE')
        return group_or_subquery if @tokens.first == '('

        token = @tokens.shift.to_s
        literal_token(token) || column(token)
      end

      def callable?(word) = OqlPredicate::AGGREGATES.include?(word) || FUNCTIONS.include?(word)

      def call_operand
        word = @tokens.first.to_s.upcase
        OqlPredicate::AGGREGATES.include?(word) ? aggregate_operand : function(word)
      end

      def group_or_subquery
        return scalar_subquery if subquery_ahead?

        @tokens.shift
        parenthesized
      end

      def parenthesized
        result = additive
        expect(')')
        result
      end

      def negate(value)
        number!(value)
        term(value.type, value.scale, nullable(value, &:-@), literal: value.literal)
      end

      def arithmetic(left, operator, right)
        return concatenation(left, right) if operator == '+' && [left.kind, right.kind].include?(:string)

        operands = [left, right].each { number!(_1) }
        error!('integer arithmetic out of range') if overflowing?(operands)
        term(numeric_type([left, right]), result_scale(left, operator, right), numeric_reader(left, operator, right))
      end

      # Mendix computes an integer column with a literal beyond 32 bits as an INTEGER and overflows.
      def overflowing?(operands)
        operands.any? { _1.literal && _1.type == :long } && operands.any? { _1.type == :integer }
      end

      def result_scale(left, operator, right)
        operator == '*' ? left.scale + right.scale : [left.scale, right.scale].max
      end

      def numeric_reader(left, operator, right)
        integer = [left, right].all? { INTEGERS.include?(_1.type) }
        scale = result_scale(left, operator, right)
        lambda do |row|
          first = left.read.call(row)
          second = right.read.call(row)
          first.nil? || second.nil? ? nil : OqlScalar.arithmetic(first, operator, second, integer:, scale:)
        end
      end

      def concatenation(left, right)
        [left, right].each { error!('+ joins only strings') unless _1.kind == :string }
        term(:string, 0, ->(row) { "#{left.read.call(row)}#{right.read.call(row)}" })
      end

      def numeric_type(values)
        types = values.map(&:type)
        return :decimal if types.include?(:decimal)

        types.include?(:long) ? :long : :integer
      end

      def number!(value)
        error!('arithmetic requires numbers; cast NULL to a type') unless value.kind == :number
      end

      def nullable(value, &block)
        lambda do |row|
          result = value.read.call(row)
          result.nil? ? nil : block.call(result)
        end
      end

      def term(type, scale, read, literal: false)
        OqlPredicate::Operand.new(OqlPredicate::KINDS.fetch(type), read, literal, type, scale)
      end
    end
  end
end
