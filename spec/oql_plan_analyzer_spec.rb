# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Oql::PlanAnalyzer do
  def envelope(plan, **timings)
    [{ 'Plan' => plan, **timings }]
  end

  it 'finds costly scans, discarded rows, misestimates, nested loops and disk sorts' do
    indexes = [
      {
        'schemaname' => 'public', 'tablename' => 'sales$order',
        'indexname' => 'sales_order_status_idx',
        'indexdef' => 'CREATE INDEX sales_order_status_idx ON public.sales$order(status)'
      },
      {
        'schemaname' => 'archive', 'tablename' => 'sales$order',
        'indexname' => 'archive_idx', 'indexdef' => 'CREATE INDEX archive_idx ...'
      },
      {
        'schemaname' => 'public', 'tablename' => 'sales$customer',
        'indexname' => 'customer_idx', 'indexdef' => 'CREATE INDEX customer_idx ...'
      }
    ]
    plan = {
      'Node Type' => 'Nested Loop', 'Plan Rows' => 20_000, 'Actual Rows' => 3_000,
      'Actual Loops' => 20, 'Total Cost' => 4_000.5,
      'Plans' => [
        {
          'Node Type' => 'Seq Scan', 'Schema' => 'public', 'Relation Name' => 'sales$order',
          'Plan Rows' => 100, 'Actual Rows' => 2_000, 'Actual Loops' => 1,
          'Rows Removed by Filter' => 5_000, 'Total Cost' => 2_000,
          'Filter' => "(status = 'Open')"
        },
        {
          'Node Type' => 'Sort', 'Plan Rows' => 50, 'Actual Rows' => 50,
          'Sort Space Type' => 'Disk', 'Sort Space Used' => 2_048, 'Sort Method' => 'quicksort'
        }
      ]
    }

    report = described_class.new(indexes:).analyze(
      envelope(plan, 'Planning Time' => 1.25, 'Execution Time' => 20.5), analyzed: true
    )

    expect(report).to have_attributes(
      engine: :postgresql, analyzed: true, planning_time_ms: 1.25,
      execution_time_ms: 20.5, total_cost: 4_000.5
    )
    expect(report).not_to be_clean
    expect(report).to be_warnings
    expect(report.findings.map(&:rule)).to contain_exactly(
      :high_volume_nested_loop, :sequential_scan, :filter_discard,
      :cardinality_misestimation, :disk_sort
    )
    scan = report.findings.find { _1.rule == :sequential_scan }
    expect(scan).to have_attributes(severity: :warning, relation: 'public.sales$order')
    expect(scan.indexes.map { _1.fetch(:name) }).to eq(['sales_order_status_idx'])
    expect(scan.suggestion).to include('status', 'listed existing indexes')
    expect(scan.metrics).to include(plan_rows: 100, actual_rows: 2_000)
  end

  it 'treats a small sequential scan as a hint and handles plan-only estimates' do
    plan = {
      'Node Type' => 'Seq Scan', 'Relation Name' => 'tiny',
      'Plan Rows' => 4, 'Total Cost' => 1.2
    }
    report = described_class.new.analyze(envelope(plan))

    expect(report).to be_clean
    expect(report).not_to be_warnings
    expect(report.findings.first).to have_attributes(
      rule: :sequential_scan, severity: :hint, relation: 'tiny', indexes: []
    )
    expect(report.findings.first.suggestion).to include('No change is implied')
  end

  it 'reports a large unindexed scan without inventing a column recommendation' do
    plan = {
      'Node Type' => 'Seq Scan', 'Schema' => 'public', 'Relation Name' => 'large_table',
      'Plan Rows' => 5_000, 'Total Cost' => 1
    }
    report = described_class.new.analyze(envelope(plan))
    finding = report.findings.first
    expect(finding.suggestion).to eq(
      'Review selective predicates. No existing index was found for this relation.'
    )
  end

  it 'detects external sorts and ignores low-volume or incomplete runtime metrics' do
    plan = {
      'Node Type' => 'Append',
      'Plans' => [
        { 'Node Type' => 'Sort', 'Sort Method' => 'external merge', 'Plan Rows' => 2 },
        { 'Node Type' => 'Nested Loop', 'Plan Rows' => 2 },
        { 'Node Type' => 'Index Scan', 'Plan Rows' => 0, 'Actual Rows' => 500 },
        { 'Node Type' => 'Index Scan', 'Plan Rows' => 100, 'Actual Rows' => 500 }
      ]
    }
    report = described_class.new.analyze(envelope(plan))
    expect(report.findings.map(&:rule)).to eq([:disk_sort])
  end

  it 'rejects malformed PostgreSQL explain payloads' do
    expect { described_class.new.analyze([]) }
      .to raise_error(ArgumentError, /invalid PostgreSQL/)
    expect { described_class.new.analyze([{ 'Planning Time' => 1 }]) }
      .to raise_error(ArgumentError, /has no Plan/)
  end
end
# rubocop:enable Metrics/BlockLength
