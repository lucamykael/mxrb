# frozen_string_literal: true

require_relative 'oql_join_sources'

module Mxrb
  module Runtime
    # A deliberately bounded grammar for relational view entities, not executable SQL.
    class OqlRelationalQuery
      REFERENCE = %r{\A[A-Za-z_][A-Za-z0-9_]*(?:[/.][A-Za-z_][A-Za-z0-9_]*)?\z}
      AGGREGATES = %w[COUNT SUM AVG MIN MAX].freeze
      CLAUSES = %w[SELECT FROM WHERE GROUP HAVING ORDER LIMIT OFFSET UNION].freeze
      Projection = Data.define(:reference, :name, :aggregate)

      attr_reader :sources, :projections, :groups, :filter

      def self.relational?(text)
        tokens = Oql::Translator.tokens(text).reject { _1.type == :space }
        tokens.each_with_index.any? do |token, index|
          token.type == :word && relational_word?(token.text.upcase, tokens[index + 1]&.text)
        end
      end

      def self.relational_word?(word, following)
        %w[JOIN GROUP].include?(word) || (AGGREGATES.include?(word) && following == '(')
      end

      def initialize(text)
        parts = clauses(text)
        @projections = split_columns(parts.fetch('SELECT')).map { projection(_1) }
        @groups = parts.key?('GROUP') ? group_columns(parts.fetch('GROUP')) : []
        @filter = parts['WHERE']&.map(&:text)&.join
        @sources = OqlJoinSources.new(parts.fetch('FROM').map(&:text)).sources
      end

      def grouped? = !groups.empty? || projections.any?(&:aggregate)

      private

      def clauses(text)
        tokens = Oql::Translator.tokens(text.strip)
        starts = clause_starts(tokens)
        names = starts.map { tokens[_1].text.upcase }
        validate_clause_order(starts, names)
        starts.each_with_index.to_h do |start, index|
          [names[index], tokens[(start + 1)...starts.fetch(index + 1, tokens.length)]]
        end
      end

      def clause_starts(tokens)
        tokens.each_index.select do |index|
          tokens[index].type == :word && CLAUSES.include?(tokens[index].text.upcase)
        end
      end

      def validate_clause_order(starts, names)
        expected = %w[SELECT FROM]
        expected << 'WHERE' if names.include?('WHERE')
        expected << 'GROUP' if names.include?('GROUP')
        return if starts.first&.zero? && names == expected

        invalid!('expected SELECT, FROM, optional WHERE and GROUP BY')
      end

      def split_columns(tokens)
        tokens.map(&:text).join.split(',', -1).map(&:strip)
      end

      def projection(text)
        match = /\A(.+?)\s+(?:AS\s+)?([A-Za-z_][A-Za-z0-9_]*)\z/i.match(text)
        invalid!('every projection requires an alias') unless match
        expression, name = match.captures
        aggregate = /\A(COUNT|SUM|AVG|MIN|MAX)\s*\(\s*(.*?)\s*\)\z/i.match(expression)
        function = aggregate && aggregate[1].upcase
        reference = normalize_reference(aggregate ? aggregate[2] : expression)
        invalid!('only COUNT accepts *') if reference == '*' && function != 'COUNT'
        Projection.new(reference, name, function)
      end

      def group_columns(tokens)
        tokens = tokens.drop_while { _1.type == :space }
        invalid!('expected GROUP BY') unless tokens.first&.text&.casecmp?('BY')
        split_columns(tokens.drop(1)).map { normalize_reference(_1, wildcard: false) }
      end

      def normalize_reference(text, wildcard: true)
        value = text.gsub(/\s+/, '').tr('/', '.')
        return value if REFERENCE.match?(value) || (wildcard && value == '*')

        invalid!('expected a column reference')
      end

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported relational OQL view: #{message}"
      end
    end
  end
end
