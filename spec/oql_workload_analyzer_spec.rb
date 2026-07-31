# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Oql::WorkloadAnalyzer do
  it 'ranks cumulative time, latency, I/O, temp writes, row volume, tables and indexes' do
    query_rows = [{
      'queryid' => '42', 'query' => 'SELECT * FROM sales$order', 'calls' => '2',
      'total_exec_time' => '2400.5', 'mean_exec_time' => '1200.25', 'rows' => '40000',
      'shared_blks_hit' => '100', 'shared_blks_read' => '900',
      'temp_blks_written' => '12', 'blk_read_time' => '30', 'blk_write_time' => '2.5'
    }]
    table_rows = [{
      'schemaname' => 'public', 'relname' => 'sales$order', 'seq_scan' => '50',
      'seq_tup_read' => '200000', 'idx_scan' => '10', 'n_live_tup' => '50000'
    }]
    index_rows = [{
      'schemaname' => 'public', 'indexrelname' => 'sales_order_old_idx',
      'idx_scan' => '0', 'idx_tup_read' => '0', 'index_bytes' => '2097152',
      'indisunique' => 'f', 'indisprimary' => 'false'
    }]

    report = described_class.new.analyze(
      query_rows:, table_rows:, index_rows:
    )

    expect(report).to have_attributes(engine: :postgresql)
    expect(report).not_to be_clean
    expect(report).to be_warnings
    expect(report.queries.first).to have_attributes(
      query_id: '42', calls: 2, total_time_ms: 2400.5, mean_time_ms: 1200.25,
      cache_hit_ratio: 0.1, io_time_ms: 32.5
    )
    expect(report.findings.map(&:rule)).to contain_exactly(
      :high_cumulative_time, :high_mean_time, :low_cache_hit,
      :temporary_block_writes, :high_rows_per_call,
      :table_sequential_pressure, :unused_large_index
    )
    expect(report.findings.map(&:subject)).to include(
      '42', 'public.sales$order', 'public.sales_order_old_idx'
    )
  end

  it 'keeps a low-cost workload clean and protects useful or constrained indexes' do
    queries = [
      {
        'queryid' => 'empty', 'query' => 'SELECT 1', 'calls' => '0',
        'total_exec_time' => '1', 'mean_exec_time' => '1', 'rows' => '0',
        'shared_blks_hit' => '0', 'shared_blks_read' => '0',
        'temp_blks_written' => '0', 'blk_read_time' => nil, 'blk_write_time' => nil
      },
      {
        'queryid' => 'cached', 'query' => 'SELECT id FROM product', 'calls' => '10',
        'total_exec_time' => '20', 'mean_exec_time' => '2', 'rows' => '100',
        'shared_blks_hit' => '99', 'shared_blks_read' => '1',
        'temp_blks_written' => '0', 'blk_read_time' => '0', 'blk_write_time' => '0'
      }
    ]
    tables = [{
      'schemaname' => 'public', 'relname' => 'product', 'seq_scan' => '1',
      'seq_tup_read' => '5', 'idx_scan' => '10', 'n_live_tup' => '5'
    }]
    indexes = [
      { 'index_bytes' => '999', 'idx_scan' => '0', 'indisunique' => 'f' },
      { 'index_bytes' => '2000000', 'idx_scan' => '1', 'indisunique' => 'f' },
      { 'index_bytes' => '2000000', 'idx_scan' => '0', 'indisunique' => 'true' },
      { 'index_bytes' => '2000000', 'idx_scan' => '0', 'indisprimary' => '1' }
    ]

    report = described_class.new.analyze(
      query_rows: queries, table_rows: tables, index_rows: indexes
    )
    expect(report).to be_clean
    expect(report).not_to be_warnings
    expect(report.findings).to be_empty
    expect(report.queries.first.cache_hit_ratio).to eq(1.0)
  end
end
# rubocop:enable Metrics/BlockLength
