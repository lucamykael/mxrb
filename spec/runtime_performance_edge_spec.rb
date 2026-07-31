# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::DatabaseWorkspace, 'performance helpers' do
  subject(:workspace) do
    described_class.allocate.tap do |value|
      value.instance_variable_set(:@port, 54_321)
      allow(value).to receive(:database_container).and_return('db-container')
      allow(value).to receive(:credentials).and_return('reader_password' => 'secret')
    end
  end

  it 'builds shell commands and reader connection URLs' do
    expect(workspace.shell_command).to include('mxrb_reader', 'db-container')
    expect(workspace.shell_command(write: true)).to include('mxrb_runtime')
    expect(workspace.connection_url).to eq(
      'postgresql://mxrb_reader:secret@127.0.0.1:54321/mxrb'
    )
  end

  it 'binds scalar and null parameters without treating PostgreSQL casts as parameters' do
    statement, variables = workspace.send(
      :bind_parameters,
      'SELECT :name, :count, :active, :missing, value::text',
      name: 'Animal', count: 2, active: false, missing: nil
    )
    expect(statement).to include(
      ":'mxrb_name'", ":'mxrb_count'", ":'mxrb_active'", 'NULL', 'value::text'
    )
    expect(variables).to include('--set', 'mxrb_name=Animal', 'mxrb_count=2', 'mxrb_active=false')
    expect(workspace.send(:bind_parameters, 'SELECT 1', {})).to eq(['SELECT 1', []])
  end

  it 'rejects invalid, missing, unused, and non-scalar parameters' do
    expect do
      workspace.send(:bind_parameters, 'SELECT :valid', 'bad-name' => 1)
    end.to raise_error(ArgumentError, /invalid parameter names/)
    expect do
      workspace.send(:bind_parameters, 'SELECT :missing', other: 1)
    end.to raise_error(ArgumentError, /missing query parameter/)
    expect do
      workspace.send(:bind_parameters, 'SELECT 1', unused: 1)
    end.to raise_error(ArgumentError, /unused query parameters/)
    expect do
      workspace.send(:bind_parameters, 'SELECT :items', items: [])
    end.to raise_error(ArgumentError, /unsupported parameter value/)
    expect(workspace.send(:parameter_scalar?, true)).to be(true)
    expect(workspace.send(:parameter_scalar?, Object.new)).to be(false)
  end

  it 'analyzes workloads, produces index advice, and validates limits' do
    allow(workspace).to receive(:workload_queries).and_return([])
    allow(workspace).to receive(:workload_tables).and_return([])
    allow(workspace).to receive(:workload_indexes).and_return([])
    report = workspace.workload(limit: 1)
    expect(report).to be_a(Mxrb::Oql::WorkloadReport)
    expect(workspace.index_advice(limit: 1)).to be_a(Mxrb::Oql::IndexAdvice)
    expect { workspace.workload(limit: 0) }.to raise_error(ArgumentError, /between/)
    expect { workspace.workload(limit: 1001) }.to raise_error(ArgumentError, /between/)
  end

  it 'constructs the CSV query command' do
    command = workspace.send(:query_rows_command, 'SELECT 1', ['--set', 'x=1'])
    expect(command).to include('db-container', '--csv', 'COPY (SELECT 1) TO STDOUT WITH CSV HEADER')
  end
end

RSpec.describe Mxrb::Runtime::SqlServerDatabase, 'JSON errors' do
  it 'returns an empty collection and reports malformed sqlcmd JSON' do
    database = described_class.allocate
    allow(database).to receive(:run!).and_return('')
    expect(database.send(:run_json, 'query')).to eq([])
    allow(database).to receive(:run!).and_return('{broken')
    expect { database.send(:run_json, 'query') }
      .to raise_error(Mxrb::ToolchainError, /invalid workload JSON/)
  end
end
# rubocop:enable Metrics/BlockLength
