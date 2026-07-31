# frozen_string_literal: true

require 'rexml/document'

module Mxrb
  module Oql
    # Parses SQL Server SHOWPLAN XML without executing or rewriting the query.
    # Missing-index entries are optimizer hypotheses, not DDL instructions.
    class SqlServerPlanAnalyzer # rubocop:disable Metrics/ClassLength
      LARGE_ROWS = 1_000
      HIGH_NESTED_ROWS = 10_000
      MISESTIMATE_RATIO = 10.0

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def analyze(xml)
        document = REXML::Document.new(xml.to_s)
        root = document.root
        raise ArgumentError, 'invalid SQL Server SHOWPLAN XML' unless root&.name == 'ShowPlanXML'

        findings = [*operator_findings(root), *missing_index_findings(root)].freeze
        statement = elements(root, 'StmtSimple').first
        runtime = elements(root, 'QueryTimeStats').first
        PlanReport.new(
          :sql_server, !runtime.nil?, nil, attribute_number(runtime, 'ElapsedTime'),
          attribute_number(statement, 'StatementSubTreeCost'), findings, xml.to_s.freeze
        )
      rescue REXML::ParseException => e
        raise ArgumentError, "invalid SQL Server SHOWPLAN XML: #{e.message}"
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

      def operator_findings(root)
        elements(root, 'RelOp').flat_map do |operator|
          [
            scan_finding(operator), nested_loop_finding(operator),
            spill_finding(operator), misestimate_finding(operator)
          ].compact
        end
      end

      def scan_finding(operator)
        physical = operator.attributes['PhysicalOp'].to_s
        return unless ['Table Scan', 'Clustered Index Scan'].include?(physical)
        return unless estimated_rows(operator) >= LARGE_ROWS

        object = operator_object(operator)
        PlanFinding.new(
          :sql_server_scan, :warning, physical, object[:relation],
          "#{physical} processes a large estimated row set.",
          'Review predicate selectivity and the actual plan; a scan can still be optimal.',
          operator_metrics(operator).freeze, object[:indexes].freeze
        )
      end

      def nested_loop_finding(operator)
        return unless operator.attributes['PhysicalOp'] == 'Nested Loops'
        return unless estimated_rows(operator) >= HIGH_NESTED_ROWS

        operator_finding(
          :sql_server_high_volume_nested_loop, operator,
          'A nested-loops join processes a high estimated row volume.',
          'Review indexes on inner join keys and compare hash or merge alternatives in the actual plan.'
        )
      end

      def spill_finding(operator)
        spill = descendants(operator).find do |element|
          %w[SpillToTempDb SortSpillDetails HashSpillDetails].include?(element.name)
        end
        return unless spill

        operator_finding(
          :sql_server_tempdb_spill, operator,
          'The actual plan reports a spill to tempdb.',
          'Reduce intermediate rows and review memory grants, cardinality estimates, sorts, and hashes.'
        )
      end

      def misestimate_finding(operator)
        estimated = estimated_rows(operator)
        actual = actual_rows(operator)
        return if estimated.zero? || actual.zero?
        return unless [estimated, actual].max >= 100 && ratio(estimated, actual) >= MISESTIMATE_RATIO

        operator_finding(
          :sql_server_cardinality_misestimation, operator,
          'Estimated and actual operator rows differ by at least 10x.',
          'Update statistics and inspect parameter sensitivity, predicates, and correlated columns.'
        )
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def missing_index_findings(root)
        elements(root, 'MissingIndexGroup').map do |group|
          index = elements(group, 'MissingIndex').first
          columns = elements(group, 'Column').map do |column|
            { name: clean_identifier(column.attributes['Name']),
              usage: column.parent.attributes['Usage'] }.freeze
          end
          relation = qualified_object(index)
          impact = attribute_number(group, 'Impact')
          PlanFinding.new(
            :sql_server_missing_index, :hint, 'MissingIndex', relation,
            "SQL Server estimates a missing-index impact of #{impact}%.",
            'Treat this as a hypothesis: compare with existing indexes, write cost, and representative workload.',
            { impact_percent: impact }.freeze, columns.freeze
          )
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def operator_finding(rule, operator, message, suggestion)
        object = operator_object(operator)
        PlanFinding.new(
          rule, :warning, operator.attributes['PhysicalOp'], object[:relation], message, suggestion,
          operator_metrics(operator).freeze, object[:indexes].freeze
        )
      end

      def operator_object(operator)
        object = descendants(operator).find { _1.name == 'Object' }
        return { relation: nil, indexes: [] } unless object

        index = clean_identifier(object.attributes['Index'])
        {
          relation: qualified_object(object),
          indexes: index ? [{ name: index, definition: nil }.freeze] : []
        }
      end

      def qualified_object(element)
        return unless element

        %w[Database Schema Table].filter_map do |name|
          clean_identifier(element.attributes[name])
        end.join('.')
      end

      def clean_identifier(value)
        text = value.to_s
        return if text.empty?

        text.delete_prefix('[').delete_suffix(']')
      end

      def operator_metrics(operator)
        {
          estimated_rows: estimated_rows(operator), actual_rows: actual_rows(operator),
          estimated_cost: attribute_number(operator, 'EstimatedTotalSubtreeCost'),
          actual_executions: runtime_counters(operator).sum do |counter|
            attribute_number(counter, 'ActualExecutions')
          end
        }
      end

      def estimated_rows(operator)
        attribute_number(operator, 'EstimateRows')
      end

      def actual_rows(operator)
        runtime_counters(operator).sum { attribute_number(_1, 'ActualRows') }
      end

      def runtime_counters(operator)
        descendants(operator).take_while { _1.name != 'RelOp' }
                             .select { _1.name == 'RunTimeCountersPerThread' }
      end

      def descendants(element)
        result = []
        element.each_recursive { result << _1 }
        result
      end

      def elements(element, name)
        descendants(element).select { _1.name == name }
      end

      def attribute_number(element, name)
        element ? element.attributes[name].to_f : 0.0
      end

      def ratio(left, right)
        [left, right].max / [left, right].min
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
