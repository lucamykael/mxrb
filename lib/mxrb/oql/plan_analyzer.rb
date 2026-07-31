# frozen_string_literal: true

module Mxrb
  module Oql
    PlanFinding = Data.define(
      :rule, :severity, :node_type, :relation, :message, :suggestion, :metrics, :indexes
    )

    PlanReport = Data.define(
      :engine, :analyzed, :planning_time_ms, :execution_time_ms, :total_cost, :findings, :raw
    ) do
      def clean? = findings.none? { _1.severity == :warning }
      def warnings? = !clean?
      def analyzed? = analyzed
    end

    # Turns PostgreSQL EXPLAIN JSON into conservative, actionable diagnostics.
    # A sequential scan is not automatically an error: small-table scans are
    # often cheaper than an index lookup, so estimates and measured rows decide
    # whether MXRB emits a hint or a warning.
    class PlanAnalyzer # rubocop:disable Metrics/ClassLength
      LARGE_ROWS = 1_000
      HIGH_COST = 1_000.0
      MISESTIMATE_RATIO = 10.0
      METRIC_KEYS = [
        'Plan Rows', 'Actual Rows', 'Actual Loops', 'Rows Removed by Filter',
        'Startup Cost', 'Total Cost', 'Actual Total Time', 'Sort Space Used', 'Sort Space Type'
      ].freeze

      def initialize(indexes: [])
        @indexes = Array(indexes).freeze
      end

      def analyze(payload, analyzed: false)
        envelope = Array(payload).first
        raise ArgumentError, 'invalid PostgreSQL EXPLAIN JSON' unless envelope.is_a?(Hash)

        root = envelope['Plan']
        raise ArgumentError, 'PostgreSQL EXPLAIN JSON has no Plan' unless root.is_a?(Hash)

        findings = walk(root).flat_map { findings_for(_1) }.freeze
        PlanReport.new(
          :postgresql, analyzed, envelope['Planning Time'], envelope['Execution Time'],
          root['Total Cost'], findings, payload
        )
      end

      private

      def walk(node)
        [node, *Array(node['Plans']).flat_map { walk(_1) }]
      end

      def findings_for(node)
        [
          sequential_scan(node), filter_discard(node), cardinality_misestimation(node),
          nested_loop(node), disk_sort(node)
        ].compact
      end

      def sequential_scan(node)
        return unless node['Node Type'] == 'Seq Scan'

        large = relevant_rows(node) >= LARGE_ROWS || number(node['Total Cost']) >= HIGH_COST
        indexes = indexes_for(node)
        PlanFinding.new(
          :sequential_scan, large ? :warning : :hint, 'Seq Scan', qualified_relation(node),
          scan_message(large), scan_suggestion(node, indexes, large),
          node_metrics(node).freeze, indexes.freeze
        )
      end

      def scan_message(large)
        return 'A large sequential scan may dominate this query.' if large

        'A sequential scan was chosen; it may be optimal for a small relation.'
      end

      def filter_discard(node)
        removed = number(node['Rows Removed by Filter'])
        return unless removed >= LARGE_ROWS && removed > number(node['Actual Rows'])

        finding(
          :filter_discard, node,
          'The filter discarded more rows than it returned.',
          'Review predicate selectivity and whether a matching index can filter before heap access.'
        )
      end

      def cardinality_misestimation(node)
        estimated = number(node['Plan Rows'])
        actual = number(node['Actual Rows'])
        return if estimated.zero? || actual.zero?
        return unless [estimated, actual].max >= 100 && ratio(estimated, actual) >= MISESTIMATE_RATIO

        finding(
          :cardinality_misestimation, node,
          'Estimated and actual row counts differ by at least 10x.',
          'Run ANALYZE after representative data changes and review extended statistics for correlated columns.'
        )
      end

      def nested_loop(node)
        return unless node['Node Type'] == 'Nested Loop'

        rows = relevant_rows(node) * [number(node['Actual Loops']), 1].max
        return unless rows >= 10_000

        finding(
          :high_volume_nested_loop, node,
          'A nested loop processes a high estimated or measured row volume.',
          'Check join cardinality and indexes on the inner join keys; compare hash or merge join plans.'
        )
      end

      def disk_sort(node)
        disk = node['Sort Space Type'] == 'Disk' || node['Sort Method'].to_s.start_with?('external')
        return unless node['Node Type'] == 'Sort' && disk

        finding(
          :disk_sort, node,
          'The sort spilled to disk.',
          'Reduce sorted rows, use an order-compatible index, or review work_mem for this workload.'
        )
      end

      def finding(rule, node, message, suggestion)
        PlanFinding.new(
          rule, :warning, node['Node Type'], qualified_relation(node), message, suggestion,
          node_metrics(node).freeze, indexes_for(node).freeze
        )
      end

      def node_metrics(node)
        METRIC_KEYS.to_h { [_1.downcase.tr(' ', '_').to_sym, node[_1]] }.compact
      end

      def relevant_rows(node)
        [number(node['Plan Rows']), number(node['Actual Rows'])].max
      end

      def ratio(left, right)
        [left, right].max / [left, right].min
      end

      def number(value)
        value ? value.to_f : 0.0
      end

      def qualified_relation(node)
        relation = node['Relation Name']
        return unless relation

        schema = node['Schema']
        schema ? "#{schema}.#{relation}" : relation
      end

      def indexes_for(node)
        relation = node['Relation Name']
        schema = node['Schema']
        return [] unless relation

        @indexes.filter_map do |index|
          next unless index['tablename'] == relation
          next if schema && index['schemaname'] != schema

          { name: index['indexname'], definition: index['indexdef'] }.freeze
        end
      end

      def scan_suggestion(node, indexes, large)
        return 'No change is implied; compare with an index plan as data grows.' unless large

        filter = node['Filter']
        prefix = filter ? "Review the filter #{filter.inspect}. " : 'Review selective predicates. '
        suffix = if indexes.empty?
                   'No existing index was found for this relation.'
                 else
                   'Compare predicates with the listed existing indexes.'
                 end
        prefix + suffix
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
