# frozen_string_literal: true

module Mxrb
  module Oql
    SqlServerWorkloadQuery = Data.define(
      :query_id, :query, :calls, :total_time_ms, :mean_time_ms, :rows,
      :logical_reads, :physical_reads, :temp_writes, :io_time_ms, :cache_hit_ratio
    )

    # Normalizes read-only SQL Server DMV snapshots into the shared workload report.
    class SqlServerWorkloadAnalyzer
      def analyze(query_rows:, table_rows:, index_rows:)
        queries = query_rows.map { query_entry(_1) }.freeze
        findings = [
          *queries.filter_map { query_finding(_1) },
          *table_rows.filter_map { table_finding(_1) },
          *index_rows.filter_map { index_finding(_1) }
        ].freeze
        WorkloadReport.new(:sql_server, queries, table_rows.freeze, index_rows.freeze, findings)
      end

      private

      def query_entry(row) # rubocop:disable Metrics/AbcSize
        calls = row['execution_count'].to_i
        total = row['total_elapsed_time'].to_f / 1_000.0
        SqlServerWorkloadQuery.new(
          row['query_hash'], row['query_text'], calls, total,
          calls.zero? ? 0.0 : total / calls, row['total_rows'].to_i,
          row['total_logical_reads'].to_i, row['total_physical_reads'].to_i,
          0, 0.0, cache_ratio(row)
        )
      end

      def cache_ratio(row)
        logical = row['total_logical_reads'].to_i
        physical = row['total_physical_reads'].to_i
        return 1.0 if logical.zero?

        (1.0 - physical.to_f / logical).clamp(0.0, 1.0).round(4)
      end

      def query_finding(query)
        return unless query.total_time_ms >= 1_000 || query.mean_time_ms >= 100

        WorkloadFinding.new(
          :sql_server_expensive_query, :warning, query.query_id,
          'The DMV snapshot reports substantial elapsed time for this query fingerprint.',
          'Inspect Query Store history and the actual plan for regressions and parameter sensitivity.',
          query.to_h.freeze
        )
      end

      def table_finding(row)
        scans = row['user_scans'].to_i
        seeks = row['user_seeks'].to_i
        return unless scans > seeks && scans >= 100

        WorkloadFinding.new(
          :sql_server_scan_pressure, :warning, row['relation'],
          'Index usage DMVs report more scans than seeks.',
          'Correlate the table with expensive fingerprints before changing indexes.',
          { user_scans: scans, user_seeks: seeks }.freeze
        )
      end

      def index_finding(row)
        return unless row['user_seeks'].to_i.zero? && row['user_scans'].to_i.zero?
        return unless row['index_bytes'].to_i >= 1_048_576

        WorkloadFinding.new(
          :sql_server_unused_large_index, :warning, row['index_name'],
          'A large index has no seeks or scans in the current DMV window.',
          'Confirm restart time and representative workload before considering removal.',
          { index_bytes: row['index_bytes'].to_i }.freeze
        )
      end
    end
  end
end
