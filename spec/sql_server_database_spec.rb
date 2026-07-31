# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::SqlServerDatabase do
  def status(successful)
    Struct.new(:success?).new(successful)
  end

  def showplan
    '<ShowPlanXML><BatchSequence><Batch><Statements>' \
      '<StmtSimple StatementSubTreeCost="1"><QueryPlan /></StmtSimple>' \
      '</Statements></Batch></BatchSequence></ShowPlanXML>'
  end

  it 'uses SQLCMDPASSWORD and captures estimated or actual read-only plans' do
    calls = []
    runner = lambda do |environment, *command|
      calls << [environment, command]
      ["rows before plan\n#{showplan}\n", '', status(true)]
    end
    subject = described_class.new(
      server: 'db.example:1433', database: 'Shop', user: 'analyst',
      password: 'secret', sqlcmd: '/usr/bin/sqlcmd', runner:
    )

    expect(subject.explain('SELECT * FROM dbo.Product')).to have_attributes(engine: :sql_server)
    environment, command = calls.last
    expect(environment).to eq('SQLCMDPASSWORD' => 'secret')
    expect(command).to include('/usr/bin/sqlcmd', '-S', 'db.example:1433', '-d', 'Shop', '-U', 'analyst')
    expect(command.join(' ')).not_to include('secret')
    expect(command.last).to include('SET SHOWPLAN_XML ON')

    expect(subject.explain('WITH p AS (SELECT 1 AS id) SELECT id FROM p', analyze: true))
      .to have_attributes(engine: :sql_server)
    expect(calls.last.last.last).to include('SET STATISTICS XML ON')
  end

  it 'rejects unsafe input, missing configuration, sqlcmd errors and absent plans' do
    expect do
      described_class.new(server: '', database: 'Shop', user: 'u', password: 'p')
    end.to raise_error(ArgumentError, /host is required/)
    expect do
      described_class.new(server: 'db', database: '', user: 'u', password: 'p')
    end.to raise_error(ArgumentError, /database is required/)
    expect do
      described_class.new(server: 'db', database: 'Shop', user: '', password: 'p')
    end.to raise_error(ArgumentError, /user is required/)
    expect do
      described_class.new(server: 'db', database: 'Shop', user: 'u', password: nil)
    end.to raise_error(ArgumentError, /MXRB_SQLSERVER_PASSWORD is required/)

    failing = described_class.new(
      server: 'db', database: 'Shop', user: 'u', password: 'p',
      runner: ->(*) { ['out', 'err', status(false)] }
    )
    expect { failing.explain('SELECT 1') }.to raise_error(Mxrb::ToolchainError, /outerr/)

    missing = described_class.new(
      server: 'db', database: 'Shop', user: 'u', password: 'p',
      runner: ->(*) { ['no plan', '', status(true)] }
    )
    expect { missing.explain('SELECT 1') }.to raise_error(Mxrb::ToolchainError, /no SHOWPLAN/)
    expect { missing.explain('') }.to raise_error(ArgumentError, /must not be empty/)
    expect { missing.explain("SELECT\0") }.to raise_error(ArgumentError, /NUL/)
    expect { missing.explain('DELETE FROM Product') }.to raise_error(ArgumentError, /read-only/)
    expect { missing.explain('SELECT 1; SELECT 2') }.to raise_error(ArgumentError, /read-only/)
    expect { missing.explain('WITH p AS (SELECT 1) UPDATE Product SET Name = NULL') }
      .to raise_error(ArgumentError, /mutating keywords/)
    expect { missing.explain('SELECT Name INTO ProductCopy FROM Product') }
      .to raise_error(ArgumentError, /mutating keywords/)
  end

  it 'uses Open3 as the default sqlcmd runner' do
    allow(Open3).to receive(:capture3).and_return([showplan, '', status(true)])
    subject = described_class.new(
      server: 'db', database: 'Shop', user: 'analyst', password: 'secret'
    )
    expect(subject.explain('SELECT 1')).to have_attributes(engine: :sql_server)
    expect(Open3).to have_received(:capture3).with(
      { 'SQLCMDPASSWORD' => 'secret' }, 'sqlcmd', '-S', 'db', '-d', 'Shop', '-U', 'analyst',
      '-C', '-b', '-h', '-1', '-W', '-y', '0', '-Q', a_string_including('SHOWPLAN_XML')
    )
  end

  it 'collects read-only workload snapshots from SQL Server DMVs' do
    responses = [
      '[{"query_hash":"0x1","query_text":"SELECT 1","execution_count":1,' \
        '"total_elapsed_time":2000000,"total_rows":1,"total_logical_reads":1,' \
        '"total_physical_reads":0}]',
      '[{"relation":"dbo.Product","user_scans":100,"user_seeks":1}]',
      '[{"index_name":"Old","user_scans":0,"user_seeks":0,"index_bytes":2000000}]'
    ]
    runner = ->(*) { [responses.shift, '', status(true)] }
    database = described_class.new(
      server: 'db', database: 'Shop', user: 'analyst', password: 'secret', runner:
    )
    report = database.workload(limit: 10)
    expect(report.engine).to eq(:sql_server)
    expect(report.findings.map(&:rule)).to include(:sql_server_expensive_query)
    expect { database.workload(limit: 0) }.to raise_error(ArgumentError, /between 1 and 1000/)
  end
end
# rubocop:enable Metrics/BlockLength
