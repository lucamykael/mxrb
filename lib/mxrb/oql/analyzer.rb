# frozen_string_literal: true

module Mxrb
  module Oql
    # Lightweight positional analysis for OQL and SQL source. This deliberately
    # stays independent from Translator's tokenizer: findings preserve the
    # original fragment for editor highlighting.
    # rubocop:disable Metrics/ClassLength
    class Analyzer
      DIALECTS = Translator::DIALECTS
      LIKE = /\bLIKE\s+'(?<pattern>(?:''|[^'])*)'/i
      WHERE = /\bWHERE\b(?<body>.*?)(?=\b(?:GROUP\s+BY|ORDER\s+BY|HAVING|LIMIT|OFFSET|UNION)\b|\z)/im
      FUNCTION = /\b(?:LOWER|UPPER|CAST)\s*\([^)]*\)/i
      FROM = /\bFROM\b(?<body>.*?)(?=\b(?:WHERE|GROUP\s+BY|ORDER\s+BY|HAVING|LIMIT|OFFSET|UNION)\b|\z)/im
      SELECT = /\bSELECT\b(?:\s+DISTINCT)?\s+(?<body>.*?)(?=\bFROM\b)/im
      STAR = %r{(?<!\()(?:\b[A-Za-z_][A-Za-z0-9_$]*\s*/\s*)?\*}

      def initialize(dialect: :postgresql)
        @dialect = dialect.to_sym
        raise ArgumentError, "unsupported analysis dialect #{@dialect.inspect}" \
          unless DIALECTS.include?(@dialect)
      end

      def analyze(query)
        source = query.oql.to_s
        findings = [
          *like_findings(source),
          *function_findings(source),
          *cartesian_findings(source),
          *select_star_findings(source)
        ].freeze
        AnalysisReport.new(query, findings)
      end

      def analyze_source(source, language: :oql)
        analyze(ad_hoc_query(source, language))
      end

      def analyze_sql(source) = analyze_source(source, language: :sql)

      private

      def ad_hoc_query(source, language)
        kind = language.to_sym
        raise ArgumentError, "unsupported analysis language #{language.inspect}" \
          unless %i[oql sql].include?(kind)

        text = source.to_s.freeze
        Query.new(
          'adhoc', 'AdHoc', 'AdHoc', kind, text, nil, [].freeze,
          kind == :sql ? 'Sql$AdHoc' : 'Oql$AdHoc', Translator.parameters(text)
        )
      end

      def like_findings(source)
        source.to_enum(:scan, LIKE).filter_map do
          match = Regexp.last_match
          classify_like(match[:pattern], match[0])
        end
      end

      def classify_like(pattern, fragment)
        if pattern.start_with?('%') && pattern.end_with?('%')
          finding(:like_both_wildcard, :warning, fragment)
        elsif pattern.start_with?('%')
          finding(:like_leading_wildcard, :error, fragment)
        elsif pattern.end_with?('%')
          finding(:like_trailing_only, :hint, fragment)
        end
      end

      def function_findings(source)
        source.to_enum(:scan, WHERE).flat_map do
          body = Regexp.last_match[:body]
          body.to_enum(:scan, FUNCTION).map do
            finding(:function_in_where, :warning, Regexp.last_match[0])
          end
        end
      end

      def cartesian_findings(source)
        source.to_enum(:scan, FROM).filter_map do
          match = Regexp.last_match
          body = match[:body]
          finding(:cartesian_join, :error, match[0].strip) \
            if body.include?(',') && !body.match?(/\bJOIN\b/i)
        end
      end

      def select_star_findings(source)
        source.to_enum(:scan, SELECT).flat_map do
          body = Regexp.last_match[:body]
          body.to_enum(:scan, STAR).map do
            finding(:select_star, :hint, Regexp.last_match[0])
          end
        end
      end

      def finding(rule, severity, fragment)
        definition = definitions.fetch(rule)
        Finding.new(rule, severity, fragment.freeze, definition[:message], definition[:suggestions])
      end

      # Keeping messages and dialect alternatives together prevents a rule
      # from being emitted without an actionable replacement.
      # rubocop:disable Metrics/MethodLength
      def definitions
        @definitions ||= {
          like_leading_wildcard: definition(
            'A leading wildcard prevents ordinary index seeks.',
            postgresql: 'Use pg_trgm with a GIN/GiST index or full-text search.',
            sql_server: 'Use CONTAINS with a full-text index.',
            ansi: 'Redesign the predicate or add a dedicated search index.'
          ),
          like_both_wildcard: definition(
            'Wildcards on both sides usually force a full scan.',
            postgresql: "Use column % 'term' with the pg_trgm extension and an index.",
            sql_server: "Use CONTAINS(column, 'term') with a full-text index.",
            ansi: 'Use a search-specific index or redesign the lookup.'
          ),
          like_trailing_only: definition(
            'A trailing-only wildcard can use an index in many configurations.',
            postgresql: 'Keep the prefix search; confirm operator class, collation, and index use.',
            sql_server: 'Keep the prefix search; confirm collation and the execution plan.',
            ansi: 'Keep the prefix search, but verify collation and index behavior.'
          ),
          function_in_where: definition(
            'Applying a function to a filtered column can make the predicate non-sargable.',
            postgresql: 'Prefer ILIKE where appropriate or create a matching functional index.',
            sql_server: 'Prefer a case-insensitive collation or an indexed computed column.',
            ansi: 'Normalize data or compare against a separately indexed normalized column.'
          ),
          cartesian_join: definition(
            'Comma-separated entities without an explicit JOIN risk a Cartesian product.',
            postgresql: 'Use an explicit JOIN with an ON predicate.',
            sql_server: 'Use an explicit JOIN with an ON predicate.',
            ansi: 'Use an explicit JOIN with an ON predicate.'
          ),
          select_star: definition(
            'Selecting every column increases transfer and couples callers to schema changes.',
            postgresql: 'Project only the columns required by the caller.',
            sql_server: 'Project only the columns required by the caller.',
            ansi: 'Project only the columns required by the caller.'
          )
        }.freeze
      end
      # rubocop:enable Metrics/MethodLength

      def definition(message, **suggestions)
        { message: message.freeze, suggestions: suggestions.freeze }.freeze
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
