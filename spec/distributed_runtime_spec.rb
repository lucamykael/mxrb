# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Lint/ConstantDefinitionInBlock, Metrics/BlockLength, Metrics/ParameterLists
RSpec.describe 'Distributed Ruby runtime coordination' do
  DistributedContext = Data.define(:user, :user_roles, :module_roles, :attributes)
  DistributedSchedulerModule = Struct.new(:name, :scheduled_events)
  DistributedSchedulerProject = Struct.new(:modules)

  let(:policy) do
    Class.new do
      def context(user: nil, user_roles: nil, roles: nil, module_roles: nil, attributes: {}, **)
        DistributedContext.new(user, Array(user_roles || roles), Array(module_roles), attributes)
      end
    end.new
  end

  def users
    JSON.generate(
      'ada' => {
        'password' => 'secret', 'roles' => ['User'],
        'attributes' => { 'locale' => 'pt_BR' }
      }
    )
  end

  def scheduler_project
    event = {
      'Name' => 'Sweep', 'Microflow' => 'Sweep', 'Enabled' => true,
      'OnOverlap' => 'SkipNext', 'TimeZone' => 'UTC',
      'Schedule' => { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 }
    }
    DistributedSchedulerProject.new([DistributedSchedulerModule.new('Ops', [event])])
  end

  it 'shares login, authentication, and logout between independent managers' do
    Dir.mktmpdir('mxrb-shared-sessions-') do |dir|
      path = File.join(dir, 'coordination.sqlite3')
      first_store = Mxrb::Runtime::SQLiteSharedStore.new(path)
      second_store = Mxrb::Runtime::SQLiteSharedStore.new(path)
      now = Time.utc(2026, 8, 10, 12)
      first = Mxrb::RubyApp::SessionManager.new(
        policy, users:, tokens: nil, ttl: 60, clock: -> { now }, store: first_store
      )
      second = Mxrb::RubyApp::SessionManager.new(
        policy, users:, tokens: nil, ttl: 60, clock: -> { now }, store: second_store
      )

      login = first.login('ada', 'secret')
      header = "Bearer #{login.fetch(:token)}"
      expect(second.authenticate(header)).to have_attributes(
        user: 'ada', user_roles: ['User'], attributes: { 'locale' => 'pt_BR' }
      )
      rows = first_store.database.execute('SELECT identity_json FROM mxrb_runtime_sessions')
      expect(rows.to_s).not_to include('secret')
      expect(first_store.database.get_first_value('SELECT token FROM mxrb_runtime_sessions'))
        .not_to eq(login.fetch(:token))

      expect(second.logout(header)).to be(true)
      expect { first.authenticate(header) }
        .to raise_error(Mxrb::RubyApp::AuthenticationError, /invalid or expired/)
    ensure
      first_store&.close
      second_store&.close
    end
  end

  it 'dispatches a job slot only once across SQLite-backed scheduler instances' do
    Dir.mktmpdir('mxrb-shared-scheduler-') do |dir|
      path = File.join(dir, 'coordination.sqlite3')
      stores = 2.times.map { Mxrb::Runtime::SQLiteSharedStore.new(path) }
      calls = []
      schedulers = stores.each_with_index.map do |store, index|
        Mxrb::Runtime::Scheduler.new(
          scheduler_project, executor: ->(name) { calls << [index, name] }, coordinator: store,
                             owner: "instance-#{index}", async: false
        )
      end
      now = Time.utc(2026, 8, 10, 12)

      expect(schedulers.sum { _1.tick(now).size }).to eq(1)
      expect(calls).to contain_exactly([0, 'Ops.Sweep'])
    ensure
      stores&.each(&:close)
    end
  end

  it 'renews a running job lease so a long execution is not dispatched twice' do
    Dir.mktmpdir('mxrb-shared-heartbeat-') do |dir|
      path = File.join(dir, 'coordination.sqlite3')
      stores = 2.times.map { Mxrb::Runtime::SQLiteSharedStore.new(path) }
      entered = Queue.new
      release = Queue.new
      first = Mxrb::Runtime::Scheduler.new(
        scheduler_project, executor: lambda { |_name|
          entered << true
          release.pop
        }, coordinator: stores[0], owner: 'worker', lease_ttl: 0.06, async: true
      )
      standby = Mxrb::Runtime::Scheduler.new(
        scheduler_project, executor: ->(_name) { raise 'duplicate execution' },
                           coordinator: stores[1], owner: 'standby', lease_ttl: 0.06, async: false
      )
      now = Time.now.utc

      first.tick(now)
      entered.pop
      sleep 0.1
      expect(standby.tick(now + 0.1)).to be_empty
      release << true
      first.wait_for_jobs
    ensure
      release << true if defined?(release) && first&.instance_variable_get(:@workers)&.any?(&:alive?)
      first&.wait_for_jobs
      stores&.each(&:close)
    end
  end

  it 'reclaims an unfinished claim after lease expiration without accepting a stale completion' do
    Dir.mktmpdir('mxrb-shared-lease-') do |dir|
      path = File.join(dir, 'coordination.sqlite3')
      first = Mxrb::Runtime::SQLiteSharedStore.new(path)
      second = Mxrb::Runtime::SQLiteSharedStore.new(path)
      now = Time.utc(2026, 8, 10, 12)
      claim = { event: 'Ops.Sweep', slot: 'minute:1', now:, lease_until: now + 5,
                skip_overlap: true }

      expect(first.claim_scheduled_event(**claim, owner: 'crashed')).to be(true)
      expect(second.claim_scheduled_event(**claim, owner: 'standby')).to be(false)
      recovered = claim.merge(now: now + 6, lease_until: now + 11)
      expect(second.claim_scheduled_event(**recovered, owner: 'standby')).to be(true)

      first.complete_scheduled_event(event: 'Ops.Sweep', slot: 'minute:1', owner: 'crashed')
      expect(first.claim_scheduled_event(**recovered, owner: 'third')).to be(false)
      second.complete_scheduled_event(event: 'Ops.Sweep', slot: 'minute:1', owner: 'standby')
      expect(first.claim_scheduled_event(**recovered.merge(now: now + 12), owner: 'third')).to be(false)
    ensure
      first&.close
      second&.close
    end
  end

  it 'atomically elects one claimant when separate processes race for a slot' do
    skip 'fork is unavailable on this platform' unless Process.respond_to?(:fork)

    Dir.mktmpdir('mxrb-process-coordination-') do |dir|
      path = File.join(dir, 'coordination.sqlite3')
      Mxrb::Runtime::SQLiteSharedStore.new(path).close
      start_reader, start_writer = IO.pipe
      result_reader, result_writer = IO.pipe
      now = Time.utc(2026, 8, 10, 12)
      children = 2.times.map do |index|
        fork do
          start_writer.close
          result_reader.close
          start_reader.read(1)
          store = Mxrb::Runtime::SQLiteSharedStore.new(path)
          claimed = store.claim_scheduled_event(
            event: 'Ops.Sweep', slot: 'minute:1', owner: "process-#{index}", now:,
            lease_until: now + 60, skip_overlap: true
          )
          result_writer.write(claimed ? '1' : '0')
          store.close
          exit! 0
        end
      end
      start_reader.close
      result_writer.close
      start_writer.write('xx')
      start_writer.close
      children.each { Process.wait(_1) }

      expect(result_reader.read.chars.count('1')).to eq(1)
    ensure
      [start_reader, start_writer, result_reader, result_writer].compact.each do |io|
        io.close unless io.closed?
      end
    end
  end

  it 'keeps the default in-memory contracts available without external configuration' do
    store = Mxrb::Runtime::MemorySharedStore.new
    now = Time.utc(2026, 8, 10, 12)
    store.write_session(token: 'local', identity: { 'user' => 'ada' }, expires_at: now + 60)

    expect(store.read_session('local', now:).identity).to eq('user' => 'ada')
    expect(store.delete_session('missing')).to be(false)
    result = store.claim_scheduled_event(
      event: 'Ops.Sweep', slot: 'minute:1', owner: 'local', now:,
      lease_until: now + 60, skip_overlap: true
    )
    expect(result).to be(true)
    expect(store.claim_scheduled_event(
             event: 'Ops.Sweep', slot: 'minute:1', owner: 'duplicate', now:,
             lease_until: now + 60, skip_overlap: true
           )).to be(false)
    expect(store.claim_scheduled_event(
             event: 'Ops.Sweep', slot: 'minute:2', owner: 'overlap', now:,
             lease_until: now + 60, skip_overlap: true
           )).to be(false)
    expect(store.renew_scheduled_event(
             event: 'Ops.Sweep', slot: 'minute:1', owner: 'other', lease_until: now + 120
           )).to be(false)
    expect(store.renew_scheduled_event(
             event: 'Ops.Sweep', slot: 'minute:1', owner: 'local', lease_until: now + 120
           )).to be(true)
    expect(store.complete_scheduled_event(
             event: 'Ops.Sweep', slot: 'minute:1', owner: 'other', now:
           )).to be(true)
    expect(store.complete_scheduled_event(
             event: 'Ops.Sweep', slot: 'minute:1', owner: 'local', now:
           )).to be(true)
    expect(store.renew_scheduled_event(
             event: 'Ops.Sweep', slot: 'minute:1', owner: 'local', lease_until: now + 180
           )).to be(false)

    expect(store.claim_scheduled_event(
             event: 'Ops.Free', slot: 'minute:1', owner: 'local', now:,
             lease_until: now + 60, skip_overlap: false
           )).to be(true)
    expect(store.renew_scheduled_event(
             event: 'Ops.Free', slot: 'minute:1', owner: 'local', lease_until: now + 120
           )).to be(true)
    store.complete_scheduled_event(event: 'Ops.Free', slot: 'minute:1', owner: 'local', now:)

    contracts = Class.new do
      include Mxrb::Runtime::SessionStore
      include Mxrb::Runtime::SchedulerCoordinator
    end.new
    expect { contracts.write_session(token: 'x', identity: {}, expires_at: now) }
      .to raise_error(NotImplementedError)
    expect { contracts.read_session('x', now:) }.to raise_error(NotImplementedError)
    expect { contracts.delete_session('x') }.to raise_error(NotImplementedError)
    expect do
      contracts.claim_scheduled_event(
        event: 'x', slot: '1', owner: 'o', now:, lease_until: now + 1, skip_overlap: true
      )
    end.to raise_error(NotImplementedError)
    expect { contracts.complete_scheduled_event(event: 'x', slot: '1', owner: 'o', now:) }
      .to raise_error(NotImplementedError)
    expect { contracts.renew_scheduled_event(event: 'x', slot: '1', owner: 'o', lease_until: now + 1) }
      .to raise_error(NotImplementedError)
  end

  it 'covers SQLite validation, non-overlap claims, renewals, and rollback paths' do
    expect { Mxrb::Runtime::SQLiteSharedStore.new('') }
      .to raise_error(ArgumentError, /path must not be empty/)

    store = Mxrb::Runtime::SQLiteSharedStore.new(':memory:')
    now = Time.utc(2026, 8, 10, 12)
    claim = {
      event: 'Ops.Sweep', slot: 'minute:1', owner: 'worker', now:,
      lease_until: now + 60, skip_overlap: true
    }
    expect(store.claim_scheduled_event(**claim)).to be(true)
    expect(store.claim_scheduled_event(**claim.merge(slot: 'minute:2', owner: 'standby'))).to be(false)
    expect(store.renew_scheduled_event(
             event: 'Ops.Sweep', slot: 'minute:1', owner: 'stale', lease_until: now + 120
           )).to be(false)

    expect(store.claim_scheduled_event(
             event: 'Ops.Free', slot: 'minute:1', owner: 'worker', now:,
             lease_until: now + 60, skip_overlap: false
           )).to be(true)
    expect { store.send(:transaction) { raise 'rollback requested' } }
      .to raise_error(RuntimeError, /rollback requested/)
    store.close
    store.close

    database = double(transaction_active?: false)
    allow(database).to receive(:execute).with('BEGIN IMMEDIATE').and_raise(SQLite3::SQLException, 'busy')
    broken = Mxrb::Runtime::SQLiteSharedStore.allocate
    broken.instance_variable_set(:@database, database)
    broken.instance_variable_set(:@mutex, Mutex.new)
    expect { broken.send(:transaction) {} }.to raise_error(SQLite3::SQLException, /busy/)
  end

  it 'uses shared SQLite by default and supports explicit process-local mode' do
    Dir.mktmpdir('mxrb-application-coordination-') do |dir|
      application = Mxrb::RubyApp::Application.allocate
      application.instance_variable_set(:@root, dir)
      application.instance_variable_set(
        :@environment, Mxrb::Environment.new('qa', root: dir, process: {})
      )
      expect(application.send(:shared_store)).to be_a(Mxrb::Runtime::SQLiteSharedStore)
      expect(File).to exist(File.join(dir, '.mxrb', 'runtime', 'qa-shared.sqlite3'))
      application.close

      local = Mxrb::RubyApp::Application.allocate
      local.instance_variable_set(:@root, dir)
      local.instance_variable_set(
        :@environment,
        Mxrb::Environment.new('qa', root: dir, process: { 'MXRB_SHARED_STORE_PATH' => ':memory:' })
      )
      expect(local.send(:shared_store)).to be_a(Mxrb::Runtime::MemorySharedStore)
      local.close

      configured_path = File.join(dir, 'state', 'cluster.sqlite3')
      configured = Mxrb::RubyApp::Application.allocate
      configured.instance_variable_set(:@root, dir)
      configured.instance_variable_set(
        :@environment,
        Mxrb::Environment.new(
          'qa', root: dir, process: { 'MXRB_SHARED_STORE_PATH' => 'state/cluster.sqlite3' }
        )
      )
      expect(configured.send(:shared_store)).to be_a(Mxrb::Runtime::SQLiteSharedStore)
      expect(File).to exist(configured_path)
      configured.close
    end
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock, Metrics/BlockLength, Metrics/ParameterLists
