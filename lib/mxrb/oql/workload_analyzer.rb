# frozen_string_literal: true

module Mxrb
  module Oql
    WorkloadQuery = Data.define(
      :query_id, :query, :calls, :total_time_ms, :mean_time_ms, :rows,
      :shared_hits, :shared_reads, :temp_writes, :io_time_ms, :cache_hit_ratio
    )
    WorkloadFinding = Data.define(:rule, :severity, :subject, :message, :suggestion, :metrics)
    WorkloadReport = Data.define(:engine, :queries, :table_stats, :index_stats, :findings) do
      def clean? = findings.none? { _1.severity == :warning }
      def warnings? = !clean?
    end

    # Interprets cumulative PostgreSQL statistics without pretending that one
    # threshold is universally optimal. Findings retain the measured values so
    # callers can rank them against their own latency and throughput budgets.
    class WorkloadAnalyzer # rubocop:disable Metrics/ClassLength
      TOTAL_TIME_MS = 1_000.0
      MEAN_TIME_MS = 100.0
      MIN_BUFFER_BLOCKS = 100
      MIN_CACHE_HIT_RATIO = 0.90
      HIGH_ROWS_PER_CALL = 10_000
      LARGE_UNUSED_INDEX_BYTES = 1_048_576
      HEAVY_SEQ_ROWS = 100_000

      def analyze(query_rows:, table_rows:, index_rows:)
        queries = query_rows.map { query_entry(_1) }.freeze
        findings = [
          *queries.flat_map { query_findings(_1) },
          *table_rows.filter_map { table_finding(_1) },
          *index_rows.filter_map { index_finding(_1) }
        ].freeze
        WorkloadReport.new(:postgresql, queries, table_rows.freeze, index_rows.freeze, findings)
      end

      private

      def query_entry(row) # rubocop:disable Metrics/AbcSize
        hits = integer(row['shared_blks_hit'])
        reads = integer(row['shared_blks_read'])
        total_blocks = hits + reads
        ratio = total_blocks.zero? ? 1.0 : hits.to_f / total_blocks
        WorkloadQuery.new(
          row['queryid'], row['query'], integer(row['calls']), float(row['total_exec_time']),
          float(row['mean_exec_time']), integer(row['rows']), hits, reads,
          integer(row['temp_blks_written']), float(row['blk_read_time']) + float(row['blk_write_time']),
          ratio.round(4)
        )
      end

      def query_findings(entry)
        [
          cumulative_time(entry), slow_mean(entry), low_cache_hit(entry),
          temporary_writes(entry), high_rows(entry)
        ].compact
      end

      def cumulative_time(entry)
        return unless entry.total_time_ms >= TOTAL_TIME_MS

        query_finding(
          :high_cumulative_time, entry,
          'This query fingerprint consumes substantial cumulative execution time.',
          'Prioritize it by total time, then inspect its real plan with db explain --analyze.'
        )
      end

      def slow_mean(entry)
        return unless entry.mean_time_ms >= MEAN_TIME_MS

        query_finding(
          :high_mean_time, entry, 'Mean execution time exceeds 100 ms.',
          'Inspect plan stability, cardinality estimates, locks, I/O, and returned row volume.'
        )
      end

      def low_cache_hit(entry)
        blocks = entry.shared_hits + entry.shared_reads
        return unless blocks >= MIN_BUFFER_BLOCKS && entry.cache_hit_ratio < MIN_CACHE_HIT_RATIO

        query_finding(
          :low_cache_hit, entry, 'A significant share of shared blocks came from storage.',
          'Check working-set size, access locality, indexes, and whether the query reads excess rows.'
        )
      end

      def temporary_writes(entry)
        return unless entry.temp_writes.positive?

        query_finding(
          :temporary_block_writes, entry, 'The query wrote temporary blocks.',
          'Inspect sorts and hashes, reduce intermediate rows, and review work_mem per workload.'
        )
      end

      def high_rows(entry)
        return if entry.calls.zero? || entry.rows / entry.calls < HIGH_ROWS_PER_CALL

        query_finding(
          :high_rows_per_call, entry, 'The query returns or processes many rows per call.',
          'Project only required columns and rows; consider pagination or a narrower aggregation.'
        )
      end

      def query_finding(rule, entry, message, suggestion)
        WorkloadFinding.new(
          rule, :warning, entry.query_id, message, suggestion,
          {
            calls: entry.calls, total_time_ms: entry.total_time_ms,
            mean_time_ms: entry.mean_time_ms, rows: entry.rows,
            cache_hit_ratio: entry.cache_hit_ratio, temp_writes: entry.temp_writes,
            io_time_ms: entry.io_time_ms
          }.freeze
        )
      end

      def table_finding(row) # rubocop:disable Metrics/MethodLength
        seq_rows = integer(row['seq_tup_read'])
        seq_scans = integer(row['seq_scan'])
        index_scans = integer(row['idx_scan'])
        return unless seq_rows >= HEAVY_SEQ_ROWS && seq_scans > index_scans

        WorkloadFinding.new(
          :table_sequential_pressure, :warning, qualified(row, 'relname'),
          'Cumulative table statistics show more sequential than index scans.',
          'Inspect the highest-cost query fingerprints before adding or changing indexes.',
          { seq_scan: seq_scans, seq_tup_read: seq_rows, idx_scan: index_scans,
            live_rows: integer(row['n_live_tup']) }.freeze
        )
      end

      def index_finding(row)
        return if truthy?(row['indisunique']) || truthy?(row['indisprimary'])

        size = integer(row['index_bytes'])
        return unless integer(row['idx_scan']).zero? && size >= LARGE_UNUSED_INDEX_BYTES

        WorkloadFinding.new(
          :unused_large_index, :warning, qualified(row, 'indexrelname'),
          'A non-unique index occupies at least 1 MiB but has no scans in the current statistics window.',
          'Confirm the statistics reset time and production workload before considering removal.',
          { idx_scan: 0, index_bytes: size, idx_tup_read: integer(row['idx_tup_read']) }.freeze
        )
      end

      def qualified(row, name_key)
        [row['schemaname'], row[name_key]].compact.join('.')
      end

      def truthy?(value)
        %w[t true 1].include?(value.to_s.downcase)
      end

      def integer(value) = value.to_i
      def float(value) = value.to_f
    end # rubocop:enable Metrics/ClassLength
  end
end
