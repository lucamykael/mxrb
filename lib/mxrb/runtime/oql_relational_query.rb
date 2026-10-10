# frozen_string_literal: true

require_relative 'oql_join_sources'
require_relative 'oql_query_shape'
require_relative 'oql_nesting'

module Mxrb
  module Runtime
    # A deliberately bounded grammar for relational view entities, not executable SQL.
    class OqlRelationalQuery
      REFERENCE = %r{\A[A-Za-z_][A-Za-z0-9_]*(?:[/.][A-Za-z_][A-Za-z0-9_]*)?\z}
      AGGREGATES = %w[COUNT SUM AVG MIN MAX].freeze
      CLAUSES = %w[SELECT FROM WHERE GROUP HAVING ORDER LIMIT OFFSET UNION].freeze
      AGGREGATE = /\A(COUNT|SUM|AVG|MIN|MAX)\s*\(\s*([^()]*?)\s*\)\z/i
      # expression holds the text of a computed projection; aggregated marks one that uses aggregates.
      Projection = Data.define(:reference, :name, :aggregate, :expression, :aggregated) do
        def initialize(reference:, name:, aggregate:, expression: nil, aggregated: false) = super
      end

      attr_reader :sources, :projections, :groups, :filter, :having

      def self.relational?(text) = OqlQueryShape.relational?(text)

      def initialize(text)
        parts = clauses(text)
        @projections = select_list(parts.fetch('SELECT'))
        @groups = parts.key?('GROUP') ? group_columns(parts.fetch('GROUP')) : []
        @filter = clause_text(parts['WHERE'])
        @having = clause_text(parts['HAVING'])
        @sources = OqlJoinSources.new(parts.fetch('FROM').map(&:text)).sources
      end

      def grouped? = !groups.empty? || projections.any? { _1.aggregate || _1.aggregated }
      def distinct? = @distinct

      private

      def select_list(tokens)
        tokens = tokens.drop_while { _1.type == :space }
        @distinct = tokens.first&.type == :word && tokens.first.text.casecmp?('DISTINCT')
        columns = split_columns(@distinct ? tokens.drop(1) : tokens)
        invalid!('expected at least one projection') if columns == ['']
        columns.each_with_index.map { |column, index| projection(column, index) }
      end

      def clause_text(tokens) = tokens&.map(&:text)&.join

      def clauses(text)
        tokens = Oql::Translator.tokens(text.strip)
        starts = clause_starts(tokens)
        names = starts.map { tokens[_1].text.upcase }
        validate_clause_order(starts, names)
        starts.each_with_index.to_h do |start, index|
          [names[index], tokens[(start + 1)...starts.fetch(index + 1, tokens.length)]]
        end
      end

      # Clauses of subqueries stay inside their parentheses.
      def clause_starts(tokens)
        OqlNesting.top_level(tokens) { _1.type == :word && CLAUSES.include?(_1.text.upcase) }
      end

      def validate_clause_order(starts, names)
        expected = %w[SELECT FROM] + %w[WHERE GROUP].select { names.include?(_1) }
        expected << 'HAVING' if names.include?('HAVING') && names.include?('GROUP')
        return if starts.first&.zero? && names == expected

        invalid!('expected SELECT, FROM, optional WHERE, GROUP BY and HAVING after GROUP BY')
      end

      def split_columns(tokens)
        depth = 0
        columns = tokens.each_with_object([+'']) do |token, parts|
          depth += { '(' => 1, ')' => -1 }.fetch(token.text, 0)
          token.text == ',' && depth.zero? ? parts << +'' : parts.last << token.text
        end
        columns.map(&:strip)
      end

      # Subqueries may leave a column unnamed: an attribute keeps its name, other terms get a position.
      def projection(text, index)
        match = /\A(.+?)\s+(?:AS\s+)?([A-Za-z_][A-Za-z0-9_]*)\z/i.match(text)
        match = nil if match && (!complete?(match[1]) || match[2].casecmp?('END'))
        expression, name = match ? match.captures : [text, unnamed(text, index)]
        aggregate = AGGREGATE.match(expression)
        return aggregate_projection(aggregate, name) if aggregate
        return Projection.new(normalize_reference(expression), name, nil) if simple_reference?(expression)

        computed(expression, name)
      end

      def aggregate_projection(match, name)
        function = match[1].upcase
        reference = normalize_reference(match[2])
        invalid!('only COUNT accepts *') if reference == '*' && function != 'COUNT'
        Projection.new(reference, name, function)
      end

      # Whether the text before a trailing word is a whole term, so that word is an alias.
      def complete?(text)
        Oql::Translator.tokens(text).sum { OqlNesting.paren(_1) }.zero? && !text.match?(%r{[-+*:%(,./]\s*\z})
      end

      def unnamed(text, index)
        simple_reference?(text) ? normalize_reference(text).split('.').last : "Column#{index + 1}"
      end

      def simple_reference?(text) = REFERENCE.match?(text.strip.gsub(%r{\s*([./])\s*}, '\\1'))

      def computed(expression, name)
        # Aggregates of a subquery do not group the outer query.
        tokens = OqlNesting.outside_subqueries(Oql::Translator.tokens(expression).reject { _1.type == :space })
        aggregated = tokens.each_cons(2).any? { |word, open| AGGREGATES.include?(word.text.upcase) && open.text == '(' }
        Projection.new(nil, name, nil, expression, aggregated)
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
