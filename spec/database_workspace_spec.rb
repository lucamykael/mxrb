# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::DatabaseWorkspace do
  def status(successful)
    Struct.new(:success?).new(successful)
  end

  def inspect_output(command, running: 'true', fallback: 'true')
    format = command[command.index('--format').to_i + 1] if command.include?('--format')
    return command.last[/mxrb-([0-9a-f]{12})/, 1] if format&.include?('mxrb.project')
    return running if format

    fallback
  end

  def make_project(dir)
    path = File.join(dir, 'database.mpr')
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) { entity :Product }
    end
    path
  end

  def plan
    instance_double(
      Mxrb::Runtime::Plan,
      available?: true,
      toolchain_path: '/opt/mendix/10.18.0',
      builder_image: 'mxrb/builder:test',
      runtime_image: 'eclipse-temurin:17-jre',
      java_version: '17'
    )
  end

  def workspace(path, state, &runner)
    allow(Mxrb::Runtime::Toolchain).to receive(:new).and_return(instance_double(
                                                                  Mxrb::Runtime::Toolchain,
                                                                  plan: plan
                                                                ))
    described_class.new(
      path, state_dir: state, port: 55_999,
            runner: runner, sleeper: ->(_seconds) {}
    )
  end

  it 'cold-starts an isolated builder, network, PostgreSQL, reader, and Runtime' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      commands = []
      ready_checks = 0
      runner = lambda do |*command|
        commands << command
        case command
        in ['docker', 'image', 'inspect', *]
          ['', '', status(false)]
        in ['docker', 'network', 'inspect', *]
          ['', '', status(false)]
        in ['docker', 'container', 'inspect', name] if name.end_with?('-postgres')
          ['', '', status(false)]
        in ['docker', 'container', 'inspect', name] if name.end_with?('-runtime')
          ['', '', status(false)]
        in ['docker', 'volume', 'inspect', *]
          ['', '', status(false)]
        in ['docker', 'exec', _, 'pg_isready', *]
          ready_checks += 1
          ['', '', status(ready_checks > 1)]
        in ['docker', 'logs', *]
          ['Mendix Runtime successfully started', '', status(true)]
        else
          ['ok', '', status(true)]
        end
      end

      info = workspace(path, File.join(dir, 'state'), &runner).up

      expect(info.running).to be true
      expect(info.host).to eq('127.0.0.1')
      expect(info.port).to eq(55_999)
      expect(commands).to include(
        include('docker', 'build'),
        include('docker', 'network', 'create')
      )
      expect(commands.flatten).to include(
        a_string_starting_with('POSTGRES_PASSWORD='),
        'RUNTIME_PARAMS_DATABASETYPE=POSTGRESQL',
        a_string_including(
          "pg_advisory_xact_lock(hashtext('mxrb.configure_reader'))",
          'GRANT pg_read_all_stats TO mxrb_reader'
        )
      )
      credentials = File.join(info.state_dir, 'credentials.json')
      expect(File.stat(credentials).mode & 0o777).to eq(0o600)
      expect(File).to exist(File.join(info.state_dir, 'runtime.json'))
    end
  end

  it 'reuses a current package and database while restarting only what is needed' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      state = File.join(dir, 'state')
      FileUtils.mkdir_p(state)
      File.write(
        File.join(state, 'credentials.json'),
        JSON.generate(
          'owner_password' => 'owner', 'reader_password' => 'reader',
          'admin_password' => 'admin'
        )
      )
      fingerprint = Mxrb.open(path) { Mxrb::Semantic::Index.fingerprint(_1) }
      File.write(File.join(state, 'runtime.json'), JSON.generate('fingerprint' => fingerprint))
      commands = []
      runner = lambda do |*command|
        commands << command
        output = if command[0, 2] == %w[docker logs]
                   'Mendix Runtime successfully started'
                 else
                   inspect_output(
                     command,
                     running: command.last.end_with?('-postgres') ? 'false' : 'true'
                   )
                 end
        [output, '', status(true)]
      end

      info = workspace(path, state, &runner).up

      expect(info.running).to be true
      expect(commands).to include(include('docker', 'start'))
      expect(commands).to include(include('docker', 'rm', '-f'))
      expect(commands.flatten).not_to include('build')
      expect(commands.flatten).not_to include('POSTGRES_PASSWORD=owner')
    end
  end

  it 'forces a rebuild for sync and repairs invalid build markers' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      %w[invalid missing].each do |name|
        state = File.join(dir, name)
        FileUtils.mkdir_p(state)
        marker = name == 'invalid' ? '{' : JSON.generate('other' => 'value')
        File.write(File.join(state, 'runtime.json'), marker)
        commands = []
        runner = lambda do |*command|
          commands << command
          output = if command[0, 2] == %w[docker logs]
                     'Mendix Runtime successfully started'
                   else
                     inspect_output(command)
                   end
          [output, '', status(true)]
        end

        subject = workspace(path, state, &runner)
        subject.up
        expect(commands).to include(include('docker', 'run', '--rm'))
        subject.sync if name == 'missing'
      end
    end
  end

  it 'reports status and stops running containers without deleting the data volume' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      commands = []
      running = true
      runner = lambda do |*command|
        commands << command
        output = inspect_output(command, running: running ? 'true' : 'false', fallback: '')
        [output, '', status(true)]
      end
      subject = workspace(path, File.join(dir, 'state'), &runner)

      expect(subject.status.running).to be true
      stopped = subject.down
      expect(stopped.running).to be false
      expect(commands.count { _1.include?('stop') }).to eq(2)
      running = false
      expect(subject.status.running).to be false
      subject.down
      expect(commands.flatten).not_to include('volume', 'rm')
    end
  end

  it 'executes read-only SQL by default and requires an explicit write role' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      commands = []
      runner = lambda do |*command|
        commands << command
        ['rows', '', status(true)]
      end
      subject = workspace(path, File.join(dir, 'state'), &runner)

      expect(subject.query('SELECT * FROM shop$product')).to eq('rows')
      reader_command = commands.last
      expect(reader_command).to include('mxrb_reader')
      expect(reader_command).to include('BEGIN READ ONLY', 'COMMIT', 'SELECT * FROM shop$product')

      expect(subject.query('VACUUM', write: true)).to eq('rows')
      expect(commands.last).to include('mxrb_runtime', 'VACUUM')
      expect { subject.query(' ') }.to raise_error(ArgumentError, /must not be empty/)
      expect { subject.query("SELECT\0") }.to raise_error(ArgumentError, /NUL/)
    end
  end

  it 'returns structured rows for one read-only online query' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      commands = []
      subject = workspace(path, File.join(dir, 'state')) do |*command|
        commands << command
        copy = command.any? { _1.start_with?('COPY (SELECT') }
        output = copy ? "name,count\nWidget,2\n" : ''
        [output, '', status(true)]
      end

      expected = [{ 'name' => 'Widget', 'count' => '2' }]
      expect(subject.query_rows('SELECT name, count FROM products')).to eq(expected)
      expect(commands.last).to include('--csv', '--quiet', 'mxrb_reader')
      expect(commands.last.last).to include('COPY (SELECT name, count FROM products)')
      expect { subject.query_rows(' ') }.to raise_error(ArgumentError, /must not be empty/)
      expect { subject.query_rows("SELECT\0") }.to raise_error(ArgumentError, /NUL/)
      expect { subject.query_rows('DELETE FROM products') }
        .to raise_error(ArgumentError, /read-only SELECT/)
      expect { subject.query_rows('SELECT 1; SELECT 2') }
        .to raise_error(ArgumentError, /read-only SELECT/)
    end
  end

  it 'explains read-only queries with optional execution and real index metadata' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      commands = []
      subject = workspace(path, File.join(dir, 'state')) do |*command|
        commands << command
        output = if command.last.start_with?('EXPLAIN')
                   JSON.generate([{ 'Plan' => {
                     'Node Type' => 'Seq Scan', 'Schema' => 'public',
                     'Relation Name' => 'shop$product', 'Plan Rows' => 2_000,
                     'Total Cost' => 2_000
                   } }])
                 elsif command.any? { _1.include?('FROM pg_indexes') }
                   "schemaname,tablename,indexname,indexdef\n" \
                     "public,shop$product,product_name_idx,CREATE INDEX product_name_idx\n"
                 else
                   ''
                 end
        [output, '', status(true)]
      end

      report = subject.explain('SELECT * FROM shop$product')
      expect(report).to have_attributes(engine: :postgresql, analyzed: false)
      expect(report.findings.first.indexes.first.fetch(:name)).to eq('product_name_idx')
      explain = commands.find { _1.last.start_with?('EXPLAIN') }.last
      expect(explain).to include('FORMAT JSON', 'SETTINGS TRUE')
      expect(explain).not_to include('ANALYZE TRUE')

      expect(subject.explain('WITH products AS (SELECT 1) SELECT * FROM products', analyze: true))
        .to be_analyzed
      expect(commands.reverse.find { _1.last.start_with?('EXPLAIN') }.last)
        .to include('ANALYZE TRUE', 'BUFFERS TRUE', 'TIMING TRUE')
    end
  end

  it 'rejects invalid explain JSON without hiding the database boundary' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      subject = workspace(path, File.join(dir, 'state')) do |*command|
        output = command.last.start_with?('EXPLAIN') ? 'not-json' : ''
        [output, '', status(true)]
      end

      expect { subject.explain('SELECT 1') }
        .to raise_error(Mxrb::ToolchainError, /invalid EXPLAIN JSON/)
      expect { subject.explain('UPDATE products SET name = NULL') }
        .to raise_error(ArgumentError, /read-only SELECT/)
    end
  end

  it 'reports cumulative query, table, and index workload statistics' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      commands = []
      subject = workspace(path, File.join(dir, 'state')) do |*command|
        commands << command
        sql = command.last
        output = if sql.include?('FROM pg_stat_statements')
                   'queryid,calls,total_exec_time,mean_exec_time,rows,shared_blks_hit,' \
                     "shared_blks_read,temp_blks_written,blk_read_time,blk_write_time,query\n" \
                     "1,2,2000,1000,20,10,90,1,3,2,SELECT 1\n"
                 elsif sql.include?('FROM pg_stat_user_tables')
                   "schemaname,relname,seq_scan,seq_tup_read,idx_scan,n_live_tup\n" \
                     "public,product,20,200000,1,1000\n"
                 elsif sql.include?('FROM pg_stat_user_indexes')
                   'schemaname,relname,indexrelname,idx_scan,idx_tup_read,idx_tup_fetch,' \
                     "index_bytes,indisunique,indisprimary\n" \
                     "public,product,old_idx,0,0,0,2000000,f,f\n"
                 else
                   ''
                 end
        [output, '', status(true)]
      end

      report = subject.workload(limit: '10')
      expect(report.queries.first.query_id).to eq('1')
      expect(report.findings.map(&:rule)).to include(
        :high_cumulative_time, :table_sequential_pressure, :unused_large_index
      )
      expect { subject.workload(limit: 0) }.to raise_error(ArgumentError, /between 1 and 1000/)
      expect { subject.workload(limit: 'many') }.to raise_error(ArgumentError, /invalid value/)
      expect(commands.flatten).to include(
        a_string_including("query ~* '^[[:space:]]*(SELECT|WITH)")
      )
    end
  end

  it 'enables PostgreSQL statistics safely and avoids unnecessary restarts' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      commands = []
      values = { 'SHOW shared_preload_libraries' => '', 'SHOW track_io_timing' => 'off' }
      subject = workspace(path, File.join(dir, 'state')) do |*command|
        commands << command
        [values.fetch(command.last, ''), '', status(true)]
      end
      subject.send(:configure_monitoring!)
      expect(commands.flatten).to include(
        "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'",
        'restart', 'ALTER SYSTEM SET track_io_timing = on',
        'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'
      )

      commands.clear
      values = {
        'SHOW shared_preload_libraries' => 'auto_explain, pg_stat_statements',
        'SHOW track_io_timing' => 'on'
      }
      subject.send(:configure_monitoring!)
      expect(commands.flatten).not_to include('restart', 'ALTER SYSTEM SET track_io_timing = on')
      expect(commands).to include(include('CREATE EXTENSION IF NOT EXISTS pg_stat_statements'))

      commands.clear
      values = {
        'SHOW shared_preload_libraries' => 'auto_explain',
        'SHOW track_io_timing' => 'on'
      }
      subject.send(:configure_monitoring!)
      expect(commands.flatten).to include(
        "ALTER SYSTEM SET shared_preload_libraries = 'auto_explain,pg_stat_statements'"
      )
    end
  end

  it 'creates the application database when an owned retained volume predates it' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      commands = []
      exists = false
      subject = workspace(path, File.join(dir, 'state')) do |*command|
        commands << command
        output = if command.last.include?('SELECT 1 FROM pg_database')
                   exists ? '1' : ''
                 else
                   ''
                 end
        [output, '', status(true)]
      end

      subject.send(:ensure_application_database!)
      expect(commands).to include(include('createdb', '--username', 'mxrb_runtime', 'mxrb'))
      exists = true
      commands.clear
      subject.send(:ensure_application_database!)
      expect(commands.flatten).not_to include('createdb')
    end
  end

  it 'provides read-only connection and shell details without exposing owner credentials' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      subject = workspace(path, File.join(dir, 'state')) do |*|
        ['', '', status(true)]
      end

      expect(subject.connection_url).to match(
        %r{\Apostgresql://mxrb_reader:[0-9a-f]{48}@127\.0\.0\.1:55999/mxrb\z}
      )
      expect(subject.shell_command).to include('mxrb_reader')
      expect(subject.shell_command(write: true)).to include('mxrb_runtime')
    end
  end

  it 'fails clearly for missing inputs, unavailable tools, Docker errors, and startup timeouts' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      failing = ->(*) { ['denied', '', status(false)] }
      subject = workspace(path, File.join(dir, 'state'), &failing)
      expect { subject.up }.to raise_error(Mxrb::ToolchainError, /docker failed/)

      allow(Mxrb::Runtime::Toolchain).to receive(:new).and_return(instance_double(
                                                                    Mxrb::Runtime::Toolchain,
                                                                    plan: instance_double(
                                                                      Mxrb::Runtime::Plan,
                                                                      available?: false,
                                                                      toolchain_path: '/missing'
                                                                    )
                                                                  ))
      unavailable = described_class.new(path, state_dir: File.join(dir, 'unavailable'), runner: failing)
      expect { unavailable.up }.to raise_error(Mxrb::ToolchainError, /unavailable/)

      missing = described_class.new(
        File.join(dir, 'missing.mpr'), state_dir: File.join(dir, 'missing'), runner: failing
      )
      expect { missing.up }.to raise_error(ArgumentError, /file not found/)
    end
  end

  it 'times out when PostgreSQL never becomes ready and accepts two-value runners' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      calls = 0
      runner = lambda do |*command|
        calls += 1 if command.include?('pg_isready')
        inspection = command.include?('inspect') && !command.include?('--format')
        ok = !command.include?('pg_isready') && !inspection
        ['', status(ok)]
      end
      subject = workspace(path, File.join(dir, 'state'), &runner)

      expect { subject.up }.to raise_error(Mxrb::ToolchainError, /did not become ready/)
      expect(calls).to eq(30)
    end
  end

  it 'waits for schema synchronization and reports stopped or timed-out Runtimes' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      logs = 0
      runner = lambda do |*command|
        if command[0, 2] == %w[docker logs]
          logs += 1
          text = logs > 1 ? 'Mendix Runtime successfully started' : 'synchronizing'
          [text, '', status(true)]
        else
          ['true', '', status(true)]
        end
      end
      subject = workspace(path, File.join(dir, 'ready'), &runner)
      expect(subject.send(:wait_for_runtime!)).to be_nil

      stopped = workspace(path, File.join(dir, 'stopped')) do |*command|
        output = command.include?('--format') ? 'false' : 'stopped'
        [output, '', status(true)]
      end
      expect { stopped.send(:wait_for_runtime!) }
        .to raise_error(Mxrb::ToolchainError, /stopped during synchronization/)

      attempts = 0
      timed_out = workspace(path, File.join(dir, 'timeout')) do |*command|
        attempts += 1 if command[0, 2] == %w[docker logs]
        output = command.include?('--format') ? 'true' : 'still synchronizing'
        [output, '', status(true)]
      end
      expect { timed_out.send(:wait_for_runtime!) }
        .to raise_error(Mxrb::ToolchainError, /synchronization timed out/)
      expect(attempts).to eq(120)
    end
  end

  it 'uses the default command runner and XDG state location' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      previous = ENV['XDG_STATE_HOME']
      ENV['XDG_STATE_HOME'] = dir
      allow(Open3).to receive(:capture3).and_return(['false', '', status(true)])

      subject = described_class.new(path)
      expect(subject.status.state_dir).to start_with(dir)
      expect(Open3).to have_received(:capture3).with(
        'docker', 'container', 'inspect', '--format', '{{.State.Running}}',
        a_string_ending_with('-postgres')
      )
      ENV.delete('XDG_STATE_HOME')
      allow(Dir).to receive(:home).and_return(dir)
      expect(described_class.new(path).status.state_dir).to start_with(
        File.join(dir, '.local', 'state')
      )
    ensure
      ENV['XDG_STATE_HOME'] = previous
    end
  end

  it 'refuses unowned resources and destroys only explicitly confirmed owned state' do
    Dir.mktmpdir do |dir|
      path = make_project(dir)
      unowned = workspace(path, File.join(dir, 'unowned')) do |*command|
        output = command.include?('--format') ? 'someone-else' : 'true'
        [output, '', status(true)]
      end
      expect { unowned.up }.to raise_error(Mxrb::ToolchainError, /unowned Docker/)
      expect { unowned.destroy }.to raise_error(ArgumentError, /explicit confirmation/)

      state = File.join(dir, 'owned')
      FileUtils.mkdir_p(state)
      commands = []
      owned = workspace(path, state) do |*command|
        commands << command
        [inspect_output(command), '', status(true)]
      end
      owned.send(:ensure_database_volume!)
      result = owned.destroy(confirm: true)

      expect(result.running).to be false
      expect(File).not_to exist(state)
      expect(commands).to include(
        include('docker', 'volume', 'rm'),
        include('docker', 'network', 'rm')
      )

      absent = workspace(path, File.join(dir, 'absent')) do |*|
        ['', '', status(false)]
      end
      expect(absent.destroy(confirm: true).running).to be false
    end
  end
end
# rubocop:enable Metrics/BlockLength
