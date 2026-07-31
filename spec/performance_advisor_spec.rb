# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'workload baselines and index advice' do
  def report(queries:, findings: [], indexes: [])
    Mxrb::Oql::WorkloadReport.new(:postgresql, queries, [], indexes, findings)
  end

  def query(id, sql, total: 2_000, mean: 200, rows: 100)
    Mxrb::Oql::WorkloadQuery.new(id, sql, 2, total, mean, rows, 10, 2, 0, 1.0, 0.8)
  end

  it 'serializes baselines and reports regressions and improvements' do
    previous = report(queries: [query('q1', 'SELECT 1', total: 1_000, mean: 100)])
    current = report(queries: [query('q1', 'SELECT 1', total: 1_500, mean: 80)])

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'baseline.json')
      File.write(path, Mxrb::Oql::WorkloadBaseline.dump(previous))
      comparison = Mxrb::Oql::WorkloadBaseline.compare(current, path)
      expect(comparison.regressions).to include(have_attributes(metric: :total_time_ms))
      expect(comparison.improvements).to include(have_attributes(metric: :mean_time_ms))
    end
  end

  it 'rejects malformed baselines and handles zero and absent fingerprints' do
    current = report(queries: [query('new', 'SELECT 1', total: 0, mean: 0, rows: 0)])
    expect(Mxrb::Oql::WorkloadBaseline.compare(
      current, 'version' => 1, 'queries' => {}
    ).deltas).to be_empty
    expect do
      Mxrb::Oql::WorkloadBaseline.load('version' => 2)
    end.to raise_error(ArgumentError, /version/)
    expect do
      Mxrb::Oql::WorkloadBaseline.load('/missing/baseline.json')
    end.to raise_error(ArgumentError, /cannot read/)
  end

  it 'suggests only evidence-backed columns and detects duplicate definitions' do
    queries = [
      query('q1', 'SELECT * FROM sales$order WHERE status = 1', total: 600),
      query('q2', 'SELECT id FROM sales$order WHERE status = 2', total: 600)
    ]
    pressure = Mxrb::Oql::WorkloadFinding.new(
      :table_sequential_pressure, :warning, 'public.sales$order', '', '', {}
    )
    indexes = [
      { 'schemaname' => 'public', 'relname' => 'sales$order', 'indexrelname' => 'a',
        'indexdef' => 'CREATE INDEX a ON sales$order (status)' },
      { 'schemaname' => 'public', 'relname' => 'sales$order', 'indexrelname' => 'b',
        'indexdef' => 'CREATE INDEX b ON sales$order ("status")' }
    ]
    advice = Mxrb::Oql::IndexAdvisor.new.analyze(
      report(queries:, findings: [pressure], indexes:)
    )
    expect(advice.candidates.first).to have_attributes(
      relation: 'sales$order', columns: ['status'], confidence: :medium,
      query_ids: %w[q1 q2]
    )
    expect(advice.redundant_indexes).to eq([%w[a b]])
  end

  it 'supports configurable workload thresholds and rejects unknown settings' do
    rows = [{
      'queryid' => 'q', 'query' => 'SELECT 1', 'calls' => '1',
      'total_exec_time' => '10', 'mean_exec_time' => '10', 'rows' => '1',
      'shared_blks_hit' => '1', 'shared_blks_read' => '0',
      'temp_blks_written' => '0', 'blk_read_time' => '0', 'blk_write_time' => '0'
    }]
    analyzer = Mxrb::Oql::WorkloadAnalyzer.new(total_time_ms: 5, mean_time_ms: 5)
    findings = analyzer.analyze(query_rows: rows, table_rows: [], index_rows: []).findings
    expect(findings.map(&:rule)).to contain_exactly(:high_cumulative_time, :high_mean_time)
    expect { Mxrb::Oql::WorkloadAnalyzer.new(unknown: 1) }
      .to raise_error(ArgumentError, /unknown workload thresholds/)
  end
end

RSpec.describe Mxrb::Oql::SqlServerWorkloadAnalyzer do
  it 'normalizes DMV rows and reports expensive queries, scans, and unused indexes' do
    report = described_class.new.analyze(
      query_rows: [{
        'query_hash' => '0x1', 'query_text' => 'SELECT * FROM Product',
        'execution_count' => '2', 'total_elapsed_time' => '4000000', 'total_rows' => '10',
        'total_logical_reads' => '100', 'total_physical_reads' => '20'
      }],
      table_rows: [{ 'relation' => 'dbo.Product', 'user_scans' => '200', 'user_seeks' => '1' }],
      index_rows: [{ 'index_name' => 'OldIndex', 'user_scans' => '0', 'user_seeks' => '0',
                     'index_bytes' => '2000000' }]
    )
    expect(report.engine).to eq(:sql_server)
    expect(report.queries.first).to have_attributes(mean_time_ms: 2000.0, cache_hit_ratio: 0.8)
    expect(report.findings.map(&:rule)).to contain_exactly(
      :sql_server_expensive_query, :sql_server_scan_pressure,
      :sql_server_unused_large_index
    )
  end
end
# rubocop:enable Metrics/BlockLength
