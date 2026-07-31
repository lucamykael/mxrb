# frozen_string_literal: true

require 'json'
require 'time'

module Mxrb
  module Oql
    WorkloadDelta = Data.define(:query_id, :metric, :before, :after, :change_percent)
    WorkloadComparison = Data.define(:deltas) do
      def regressions = deltas.select { _1.change_percent.positive? }
      def improvements = deltas.select { _1.change_percent.negative? }
    end

    # Serializable workload snapshot and deterministic regression comparison.
    module WorkloadBaseline
      module_function

      METRICS = %w[total_time_ms mean_time_ms io_time_ms temp_writes rows].freeze

      def dump(report)
        JSON.pretty_generate(
          version: 1, engine: report.engine, captured_at: Time.now.utc.iso8601,
          queries: report.queries.to_h { [_1.query_id.to_s, _1.to_h] }
        ) << "\n"
      end

      def load(source)
        payload = source.is_a?(Hash) ? source : JSON.parse(File.read(source))
        raise ArgumentError, 'unsupported workload baseline version' unless payload['version'] == 1

        payload
      rescue JSON::ParserError, Errno::ENOENT => e
        raise ArgumentError, "cannot read workload baseline: #{e.message}"
      end

      def compare(report, baseline)
        previous = load(baseline).fetch('queries')
        deltas = report.queries.flat_map { query_deltas(_1, previous[_1.query_id.to_s]) }
        WorkloadComparison.new(deltas.freeze)
      end

      def query_deltas(query, before)
        return [] unless before

        METRICS.filter_map do |metric|
          delta(query.query_id, metric, Float(before.fetch(metric)), Float(query.to_h.fetch(metric.to_sym)))
        end
      end
      private_class_method :query_deltas

      def delta(query_id, metric, before, after)
        return if before.zero? && after.zero?

        percent = before.zero? ? 100.0 : ((after - before) * 100.0 / before).round(2)
        WorkloadDelta.new(query_id, metric.to_sym, before, after, percent)
      end
      private_class_method :delta
    end
  end
end
