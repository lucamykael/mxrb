# frozen_string_literal: true

require 'bigdecimal'
require 'strscan'
require_relative 'oql_membership'

module Mxrb
  module Runtime
    # Compiles the supported WHERE grammar to typed Ruby readers, never SQL or eval.
    # Parsing validates every branch, including predicates over an empty source.
    # Strings compare, match and sort case-insensitively, as Mendix 11.12.1 does.
    # rubocop:disable Metrics/ClassLength
    class OqlPredicate
      Operand = Data.define(:kind, :read, :literal)
      TOKEN = %r{'(?:[^']|'')*'|[+-]?\d+(?:\.\d+)?|[A-Za-z_][A-Za-z0-9_]*|!=|<=|>=|[=<>()/.,*]}
      AGGREGATES = %w[COUNT SUM AVG MIN MAX].freeze
      COMPARISONS = %w[= != < <= > >=].freeze
      KINDS = { integer: :number, long: :number, autonumber: :number, decimal: :number,
                string: :string, enumeration: :string, boolean: :boolean, datetime: :datetime,
                identifier: :identifier }.freeze

      def initialize(text, scope, aggregate: nil, &resolve)
        @tokens = tokenize(text)
        @scope = scope
        @resolve = resolve
        @aggregate = aggregate
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
        return null_clause(left) if take('IS')

        membership(left) || ordinary(left)
      end

      def null_clause(left)
        negative = take('NOT')
        expect('NULL')
        result = null_test(left)
        negative ? invert(result) : result
      end

      def ordinary(left)
        return boolean(left) unless COMPARISONS.include?(@tokens.first)

        operator = @tokens.shift
        compare(left, operand, operator)
      end

      def membership(left)
        negative = negated_membership?
        result = membership_test(left)
        negative ? invert(result) : result
      end

      def negated_membership?
        return false unless @tokens.first.to_s.casecmp?('NOT') && %w[LIKE IN].include?(@tokens[1].to_s.upcase)

        @tokens.shift
        true
      end

      def membership_test(left)
        return like(left, operand) if take('LIKE')

        within(left, literal_list) if take('IN')
      end

      def like(left, pattern)
        error!('LIKE requires a string attribute') unless left.kind == :string && !left.literal
        error!('LIKE requires a literal pattern') unless pattern.literal && %i[string null].include?(pattern.kind)
        Operand.new(:boolean, OqlMembership.like(left.read, pattern.read.call(nil).to_s), false)
      end

      def literal_list
        expect('(')
        values = [operand]
        values << operand while take(',')
        expect(')')
        error!('IN accepts only literal values') unless values.all?(&:literal)
        values
      end

      def within(left, values)
        values.each { validate_comparison(left, _1, '=') }
        normalize = ->(value) { comparable(left.kind, value) }
        Operand.new(:boolean, OqlMembership.within(left.read, values.map { _1.read.call(nil) }, normalize), false)
      end

      def operand
        return aggregate_operand if AGGREGATES.include?(@tokens.first.to_s.upcase) && @tokens[1] == '('

        token = @tokens.shift.to_s
        literal_token(token) || column(token)
      end

      def literal_token(token)
        return literal(:string, token[1...-1].gsub("''", "'")) if token.start_with?("'")
        return literal(:number, BigDecimal(token)) if token.match?(/\A[+-]?\d/)
        return literal(:null, nil) if token.casecmp?('NULL')

        literal(:boolean, token.casecmp?('TRUE')) if %w[TRUE FALSE].include?(token.upcase)
      end

      def aggregate_operand
        error!('aggregates are only allowed in HAVING') unless @aggregate
        function = @tokens.shift.upcase
        expect('(')
        reference = take('*') ? '*' : qualified_column(@tokens.shift.to_s)
        expect(')')
        error!('only COUNT accepts *') if reference == '*' && function != 'COUNT'
        type, reader = @aggregate.call(function, reference)
        Operand.new(KINDS.fetch(type), reader, false)
      end

      def column(token)
        token = qualified_column(token)
        pattern = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?\z/
        error!('expected an attribute or literal') unless pattern.match?(token)
        type, reader = @resolve.call(token)
        kind = KINDS[type]
        error!("unsupported attribute type #{type}") unless kind
        Operand.new(kind, reader, false)
      end

      def qualified_column(token)
        if take('.') || take('/')
          error!("unknown scope #{token}") unless Array(@scope).include?(token)
          name = @tokens.shift.to_s
          token = @scope.is_a?(Array) ? "#{token}.#{name}" : name
        end
        token
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

          first = comparable(left.kind, first)
          second = comparable(right.kind, second)
          first.public_send(operator == '=' ? :== : operator, second)
        }, false)
      end

      def comparable(kind, value) = kind == :string ? value.to_s.downcase : value

      def null_comparison(left, right, operator)
        return nil unless %w[= !=].include?(operator) && (left.literal || right.literal)

        operator == '!='
      end

      def validate_comparison(left, right, operator)
        types = [left.kind, right.kind].reject { _1 == :null }
        error!('incompatible comparison types') if types.uniq.length > 1
        return if %w[= !=].include?(operator) || types.all? { _1 == :number } || types.all? { _1 == :string }

        error!('ordered comparisons require numbers or strings')
      end

      def error!(message)
        raise NativeRuntimeError, "Unsupported OQL view WHERE: #{message}"
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
