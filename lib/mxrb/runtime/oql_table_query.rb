# frozen_string_literal: true

require_relative 'oql_relational_query'

module Mxrb
  module Runtime
    # Separates tabular ordering/paging and a single derived FROM source from the
    # relational grammar. Tokens inside strings and parentheses remain opaque.
    class OqlTableQuery
      CLAUSES = %w[SELECT FROM WHERE GROUP HAVING ORDER LIMIT OFFSET UNION].freeze
      ALLOWED = %w[SELECT FROM WHERE GROUP HAVING ORDER LIMIT OFFSET].freeze
      DERIVED_ENTITY = 'MxrbDerived.Source'
      Order = Data.define(:reference, :descending)
      attr_reader :relational, :derived, :orders, :limit, :offset

      def initialize(text)
        parts = split_clauses(text)
        extract_options(parts)
        parts['FROM'] = derived_source(parts.fetch('FROM'))
        @relational = OqlRelationalQuery.new(parts.map { |name, value| "#{name} #{value}" }.join(' '))
        names = @relational.projections.map(&:name)
        invalid!('duplicate output column') unless names.uniq == names
      end

      private

      def extract_options(parts)
        @orders = parts.key?('ORDER') ? parse_order(parts.delete('ORDER')) : []
        @limit = parts.key?('LIMIT') ? integer(parts.delete('LIMIT')) : nil
        @offset = parts.key?('OFFSET') ? integer(parts.delete('OFFSET')) : nil
      end

      def split_clauses(text)
        tokens = Oql::Translator.tokens(text.to_s.strip)
        starts = clause_starts(tokens)
        names = starts.map { tokens[_1].text.upcase }
        validate_clause_order(starts, names)
        clause_bodies(tokens, starts, names)
      end

      def clause_bodies(tokens, starts, names)
        starts.each_with_index.to_h do |start, index|
          [names[index], tokens[(start + 1)...starts.fetch(index + 1, tokens.length)].map(&:text).join.strip]
        end
      end

      def validate_clause_order(starts, names)
        expected = %w[SELECT FROM] + ALLOWED.drop(2).select { names.include?(_1) }
        invalid!('unsupported clause order') unless starts.first&.zero? && names == expected
      end

      def clause_starts(tokens)
        depth = 0
        starts = tokens.each_index.select do |index|
          token = tokens[index]
          depth = nesting(token, depth)
          depth.zero? && token.type == :word && CLAUSES.include?(token.text.upcase)
        end
        invalid!('unbalanced parentheses') unless depth.zero?
        starts
      end

      def nesting(token, depth)
        depth += 1 if token.text == '('
        depth -= 1 if token.text == ')'
        invalid!('unbalanced parentheses') if depth.negative?
        depth
      end

      def derived_source(source)
        return source unless source.start_with?('(')

        tokens = Oql::Translator.tokens(source)
        closing = derived_end(tokens)
        name = derived_alias(tokens[(closing + 1)..])
        @derived = tokens[1...closing].map(&:text).join
        "#{DERIVED_ENTITY} #{name}"
      end

      def derived_end(tokens)
        depth = 0
        tokens.index do |token|
          depth = nesting(token, depth)
          depth.zero?
        end
      end

      def derived_alias(tokens)
        suffix = tokens.map(&:text).join.strip
        match = /\A(?:AS\s+)?([A-Za-z_][A-Za-z0-9_]*)\z/i.match(suffix)
        invalid!('derived FROM requires one alias and no joined sources') unless match
        match[1]
      end

      def parse_order(text)
        match = /\ABY\s+(.+)\z/im.match(text)
        invalid!('expected ORDER BY') unless match
        match[1].split(',', -1).map do |item|
          entry = /\A\s*(\S+?)(?:\s+(ASC|DESC))?\s*\z/i.match(item)
          invalid!('expected an ORDER BY column') unless entry && OqlRelationalQuery::REFERENCE.match?(entry[1])
          Order.new(entry[1].tr('/', '.'), entry[2]&.upcase == 'DESC')
        end
      end

      def integer(text)
        invalid!('LIMIT/OFFSET require a nonnegative integer') unless /\A\d+\z/.match?(text)
        text.to_i
      end

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported tabular OQL: #{message}"
      end
    end
  end
end
