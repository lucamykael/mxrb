# frozen_string_literal: true

module Mxrb
  module Oql
    IndexCandidate = Data.define(:relation, :columns, :confidence, :query_ids, :reason)
    IndexAdvice = Data.define(:candidates, :redundant_indexes)

    # Produces hypotheses only when cumulative workload supplies repeatable evidence.
    class IndexAdvisor
      TABLE_PATTERN = /\b(?:FROM|JOIN)\s+["\[]?([\w$]+)["\]]?/i
      PREDICATE_PATTERN = /\b([A-Za-z_]\w*)\s*(?:=|<|>|<=|>=|LIKE|IN\s*\()/i

      def analyze(report)
        evidence = collect_evidence(report.queries)
        candidates = candidates_for(evidence, pressured_relations(report))
        IndexAdvice.new(candidates.freeze, redundant(report.index_stats).freeze)
      end

      private

      def collect_evidence(queries)
        evidence = Hash.new { |hash, key| hash[key] = [] }
        queries.each do |query|
          relations(query.query).product(predicates(query.query)).each do |relation, column|
            evidence[[relation.downcase, column.downcase]] << query
          end
        end
        evidence
      end

      def pressured_relations(report)
        report.findings.select { _1.rule == :table_sequential_pressure }
                       .map { _1.subject.to_s.split('.').last.downcase }
      end

      def candidates_for(evidence, pressured)
        evidence.filter_map do |(relation, column), queries|
          next unless pressured.include?(relation)
          next unless sufficient_evidence?(queries)

          IndexCandidate.new(
            relation, [column].freeze, confidence(queries), queries.map(&:query_id).uniq.freeze,
            'Repeated filtered workload coincides with cumulative sequential-scan pressure.'
          )
        end
      end

      def sufficient_evidence?(queries)
        queries.map(&:query_id).uniq.size >= 2 || queries.sum(&:total_time_ms) >= 1_000
      end

      def relations(sql) = sql.to_s.scan(TABLE_PATTERN).flatten.uniq
      def predicates(sql) = sql.to_s.scan(PREDICATE_PATTERN).flatten.uniq

      def confidence(queries)
        return :high if queries.map(&:query_id).uniq.size >= 3 || queries.sum(&:total_time_ms) >= 5_000

        :medium
      end

      def redundant(indexes)
        indexes.filter_map { index_signature(_1) }.group_by(&:first).values.flat_map do |entries|
          entries.combination(2).filter_map { redundant_pair(_1, _2) }
        end
      end

      def index_signature(index)
        columns = index['indexdef'].to_s[/\(([^)]+)\)/, 1]
        return unless columns

        [[index['schemaname'], index['relname']], [index['indexrelname'], normalize(columns)]]
      end

      def redundant_pair(left, right)
        left_name, left_columns = left.last
        right_name, right_columns = right.last
        [left_name, right_name].freeze if left_columns == right_columns
      end

      def normalize(columns)
        columns.downcase.gsub(/["\[\]\s]/, '')
      end
    end
  end
end
