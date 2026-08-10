# frozen_string_literal: true

require 'spec_helper'
require_relative '../lib/mxrb/runtime/scheduler'

# rubocop:disable Lint/ConstantDefinitionInBlock, Metrics/BlockLength

RSpec.describe Mxrb::Runtime::Scheduler do
  SchedulerMod = Struct.new(:name, :scheduled_events)
  SchedulerProject = Struct.new(:modules)

  def event(name, microflow:, schedule:, enabled: true, overlap: 'SkipNext')
    {
      'Name' => name, 'Microflow' => microflow, 'Schedule' => schedule,
      'Enabled' => enabled, 'OnOverlap' => overlap, 'TimeZone' => 'UTC'
    }
  end

  def project_with(*events)
    SchedulerProject.new([SchedulerMod.new('Sales', events)])
  end

  it 'loads and executes minute, hour, and day schedules exactly once per slot' do
    events = [
      event('EveryFive', microflow: 'Cleanup',
                         schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 5 }),
      event('Hourly', microflow: 'Sales.Hourly',
                      schedule: { '$Type' => 'ScheduledEvents$HourSchedule',
                                  'Multiplier' => 1, 'MinuteOffset' => 10 }),
      event('Daily', microflow: 'Daily',
                     schedule: { '$Type' => 'ScheduledEvents$DaySchedule',
                                 'HourOfDay' => 12, 'MinuteOfHour' => 10 }),
      event('Disabled', microflow: 'Never',
                        schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 },
                        enabled: false)
    ]
    calls = []
    scheduler = described_class.new(project_with(*events), executor: ->(name) { calls << name },
                                                           async: false)
    now = Time.utc(2026, 8, 10, 12, 10, 30)

    expect(scheduler.tick(now).map(&:qualified_name)).to eq(
      %w[Sales.EveryFive Sales.Hourly Sales.Daily]
    )
    expect(scheduler.tick(now)).to be_empty
    expect(calls).to eq(%w[Sales.Cleanup Sales.Hourly Sales.Daily])
  end

  it 'supports legacy IntervalType documents and a scheduled-event keyword' do
    source = {
      'Name' => 'Legacy', 'Microflow' => 'Tick', 'IntervalType' => 'Minute',
      'Interval' => 2, 'Enabled' => true
    }
    calls = []
    executor = lambda do |microflow, scheduled_event:|
      calls << [microflow, scheduled_event.qualified_name]
    end
    scheduler = described_class.new(project_with(source), executor:, async: false)

    scheduler.tick(Time.utc(2026, 8, 10, 12, 10))
    expect(calls).to eq([['Sales.Tick', 'Sales.Legacy']])
  end

  it 'skips overlap and permits the missed slot after the running job finishes' do
    source = event(
      'Slow', microflow: 'Slow',
              schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 }
    )
    entered = Queue.new
    release = Queue.new
    calls = 0
    executor = lambda do |_microflow|
      calls += 1
      entered << true
      release.pop
    end
    scheduler = described_class.new(project_with(source), executor:, async: true)

    first = Time.utc(2026, 8, 10, 12, 10)
    scheduler.tick(first)
    entered.pop
    expect(scheduler.tick(first + 60)).to be_empty
    release << true
    scheduler.wait_for_jobs

    expect(scheduler.tick(first + 60).size).to eq(1)
    entered.pop
    release << true
    scheduler.wait_for_jobs
    expect(calls).to eq(2)
  end

  it 'captures execution errors and invokes the error callback' do
    source = event(
      'Broken', microflow: 'Broken',
                schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 }
    )
    reported = []
    scheduler = described_class.new(
      project_with(source), executor: ->(_name) { raise 'boom' },
                            on_error: ->(job, error) { reported << [job.name, error.message] }, async: false
    )

    expect { scheduler.tick(Time.utc(2026, 8, 10, 12, 10)) }.not_to raise_error
    expect(reported).to eq([%w[Broken boom]])
    expect(scheduler.errors.first.last.message).to eq('boom')
  end

  it 'starts and shuts down a scheduler loop cleanly with injected time primitives' do
    source = event(
      'Tick', microflow: 'Tick',
              schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 }
    )
    calls = Queue.new
    sleeps = Queue.new
    scheduler = described_class.new(
      project_with(source), executor: ->(name) { calls << name },
                            clock: -> { Time.utc(2026, 8, 10, 12, 10) },
                            sleeper: lambda { |_duration|
                              sleeps << true
                              Thread.pass
                            }, async: false
    )

    expect(scheduler.start).to equal(scheduler)
    expect(scheduler.start).to equal(scheduler)
    expect(calls.pop).to eq('Sales.Tick')
    sleeps.pop
    expect(scheduler.running?).to be true
    scheduler.shutdown
    expect(scheduler.running?).to be false
  end

  it 'rejects invalid schedules without an optional scheduler dependency' do
    bad = event('Bad', microflow: 'Bad', schedule: {}, enabled: true)
    expect do
      described_class.new(project_with(bad), executor: ->(_name) {})
    end.to raise_error(ArgumentError, /unsupported scheduled-event interval/)
  end

  it 'supports default executors, executor objects, and every callable arity' do
    source = event(
      'Invoke', microflow: 'Invoke',
                schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 }
    )
    project_class = Struct.new(:modules, :calls) do
      def execute_microflow(name) = calls << name
    end
    runtime_project = project_class.new(project_with(source).modules, [])
    scheduler = described_class.new(runtime_project, async: false)
    scheduler.tick(Time.utc(2026, 8, 10, 12, 10))
    expect(runtime_project.calls).to eq(['Sales.Invoke'])

    executor = Object.new
    received = []
    executor.define_singleton_method(:execute_microflow) { |name| received << name }
    described_class.new(project_with(source), executor:, async: false)
                   .tick(Time.utc(2026, 8, 10, 12, 10))
    expect(received).to eq(['Sales.Invoke'])

    zero_calls = 0
    described_class.new(project_with(source), executor: -> { zero_calls += 1 }, async: false)
                   .tick(Time.utc(2026, 8, 10, 12, 10))
    expect(zero_calls).to eq(1)

    invalid = described_class.new(project_with(source), executor: Object.new, async: false)
    invalid.tick(Time.utc(2026, 8, 10, 12, 10))
    expect(invalid.errors.first.last).to be_a(ArgumentError)

    expect { described_class.new(project_with(source)) }
      .to raise_error(ArgumentError, /executor is required/)
  end

  it 'normalizes legacy hour/day schedules and schedule boundary branches' do
    hour = {
      'Name' => 'LegacyHour', 'Microflow' => 'Hour', 'IntervalType' => 'Hour',
      'Interval' => 1, 'Enabled' => true
    }
    day = {
      'Name' => 'LegacyDay', 'Microflow' => 'Day', 'IntervalType' => 'Day',
      'Interval' => 1, 'Enabled' => true
    }
    calls = []
    scheduler = described_class.new(project_with(hour, day), executor: ->(name) { calls << name }, async: false)
    scheduler.tick(Time.utc(2026, 8, 10, 0, 0))
    expect(calls).to contain_exactly('Sales.Hour', 'Sales.Day')

    future = event(
      'Future', microflow: 'Future',
                schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 2 }
    ).merge('StartDateTime' => '2030-01-01T00:00:00Z')
    future_scheduler = described_class.new(project_with(future), executor: ->(_name) {}, async: false)
    expect(future_scheduler.tick(Time.utc(2026, 8, 10))).to be_empty
    expect(future_scheduler.tick(Time.utc(2030, 1, 1, 0, 1))).to be_empty

    expect(scheduler.tick(Time.utc(2026, 8, 10, 0, 1))).to be_empty
    expect(scheduler.tick(Time.utc(2026, 8, 11, 1, 1))).to be_empty
    unknown = Mxrb::Runtime::ScheduledJob.new(
      name: 'Unknown', qualified_name: 'Sales.Unknown', microflow: 'Sales.Unknown',
      schedule: { type: :unknown }, overlap: 'Allow', enabled: true,
      start_at: nil, time_zone: 'UTC', source: {}
    )
    expect(scheduler.send(:due_slot, unknown, Time.utc(2026, 8, 10))).to be_nil

    every_two_hours = scheduler.jobs.first.with(schedule: { type: :hour, every: 2, minute: 0 })
    expect(scheduler.send(:due_slot, every_two_hours, Time.utc(2026, 8, 10, 1, 0))).to be_nil
    anchored_hour = every_two_hours.with(start_at: Time.utc(2026, 8, 10, 0, 0))
    expect(scheduler.send(:due_slot, anchored_hour, Time.utc(2026, 8, 10, 2, 0))).not_to be_nil
    every_two_days = scheduler.jobs.last.with(schedule: { type: :day, every: 2, hour: 0, minute: 0 })
    first = Time.utc(2026, 8, 10)
    candidate = scheduler.send(:due_slot, every_two_days, first) ? first + 86_400 : first
    expect(scheduler.send(:due_slot, every_two_days, candidate)).to be_nil
    anchored_day = every_two_days.with(start_at: first)
    expect(scheduler.send(:due_slot, anchored_day, first + (2 * 86_400))).not_to be_nil
  end

  it 'handles lifecycle failures, overlap options, and thread edge paths' do
    source = event(
      'Lifecycle', microflow: 'Lifecycle', overlap: 'Allow',
                   schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 }
    )
    logger = double('logger', error: nil)
    reported = []
    scheduler = described_class.new(
      project_with(source), executor: ->(_name) {}, clock: -> { raise 'clock failed' },
                            sleeper: ->(_duration) {}, skip_overlap: false,
                            on_error: ->(job, error) { reported << [job, error.message] }, logger:, async: false
    )
    scheduler.send(:run_loop)
    expect(reported).to eq([[nil, 'clock failed']])
    expect(scheduler.errors.first.first).to be_nil
    expect(logger).to have_received(:error).with(/scheduler failed/)

    normal = described_class.new(project_with(source), executor: ->(_name) {},
                                                       skip_overlap: false, async: false)
    expect(normal.send(:skip_overlap?, normal.jobs.first)).to be false
    expect(normal.shutdown(wait: false)).to equal(normal)
    expect(normal.shutdown).to equal(normal)

    live_thread = Object.new
    live_thread.define_singleton_method(:alive?) { true }
    normal.instance_variable_set(:@thread, live_thread)
    expect(normal.shutdown(wait: false)).to equal(normal)
    expect(normal.instance_variable_get(:@thread)).to equal(live_thread)
    normal.instance_variable_set(:@thread, nil)

    entered = Queue.new
    waiter = Thread.new do
      normal.instance_variable_get(:@mutex).synchronize do
        normal.instance_variable_set(:@workers, [Thread.current])
      end
      entered << true
      normal.wait_for_jobs
    end
    entered.pop
    normal.instance_variable_get(:@mutex).synchronize do
      normal.instance_variable_set(:@workers, [])
    end
    waiter.join

    fake_worker = Object.new
    fake_worker.define_singleton_method(:alive?) { false }
    allow(Thread).to receive(:new).and_return(fake_worker)
    normal.send(:dispatch, normal.jobs.first, async: true)
    expect(normal.instance_variable_get(:@workers)).to include(fake_worker)

    start_without_name = described_class.new(project_with(source), executor: ->(_name) {}, async: false)
    expect(start_without_name.start).to equal(start_without_name)

    execution_logger = double('execution logger', error: nil)
    broken = described_class.new(
      project_with(source), executor: ->(_name) { raise 'execution failed' },
                            logger: execution_logger, async: false
    )
    broken.tick(Time.utc(2026, 8, 10, 12, 10))
    expect(execution_logger).to have_received(:error).with(/scheduled event/)

    silent_failure = described_class.new(
      project_with(source), executor: ->(_name) {}, clock: -> { raise 'silent clock failure' },
                            sleeper: ->(_duration) {}, async: false
    )
    silent_failure.send(:run_loop)
    expect(silent_failure.errors.first.last.message).to eq('silent clock failure')

    deterministic = nil
    deterministic = described_class.new(
      project_with(source), executor: ->(_name) {},
                            clock: -> { Time.utc(2026, 8, 10, 12, 10) },
                            sleeper: lambda { |_duration|
                              deterministic.instance_variable_set(:@stopping, true)
                            }, async: false
    )
    deterministic.send(:run_loop)
    expect(deterministic.errors).to be_empty

    skip_sleep = nil
    skip_sleep = described_class.new(
      project_with(source),
      executor: ->(_name) { skip_sleep.instance_variable_set(:@stopping, true) },
      clock: -> { Time.utc(2026, 8, 10, 12, 10) },
      sleeper: ->(_duration) { raise 'sleeper should be skipped' }, async: false
    )
    skip_sleep.send(:run_loop)
    expect(skip_sleep.errors).to be_empty
  end

  it 'supports timezone, time parsing, validation, and private defensive paths' do
    source = event(
      'Time', microflow: '',
              schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 }
    )
    scheduler = described_class.new(project_with(source), executor: ->(_name) {}, async: false)
    time = Time.utc(2026, 8, 10, 12, 10)

    expect(scheduler.send(:event_time, time, 'local')).to eq(time.getlocal)
    expect(scheduler.send(:event_time, time, '+02:00').utc_offset).to eq(7200)
    boa_vista = scheduler.send(:event_time, time, 'America/Boa_Vista')
    expect(boa_vista.utc_offset).to eq(-14_400)
    expect(boa_vista.hour).to eq(8)
    expect(scheduler.send(:parse_time, '2026-08-10T12:10:00Z')).to eq(time)
    expect(scheduler.send(:parse_time, time)).to equal(time)
    expect(scheduler.send(:parse_time, 'invalid')).to be_nil
    expect(scheduler.send(:fetch, nil, :missing)).to be_nil
    expect(scheduler.send(:fetch, {}, :missing)).to be_nil

    expect do
      described_class.new(project_with(source), executor: ->(_name) {}, poll_interval: 0)
    end.to raise_error(ArgumentError, /poll_interval/)
    expect do
      described_class.new(project_with(source), executor: ->(_name) {}, lease_ttl: 0)
    end.to raise_error(ArgumentError, /lease_ttl/)
    bad_interval = event(
      'BadInterval', microflow: 'Bad',
                     schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 0 }
    )
    expect do
      described_class.new(project_with(bad_interval), executor: ->(_name) {})
    end.to raise_error(ArgumentError, /interval must be positive/)
  end

  it 'handles coordinator completion and heartbeat failures without losing scheduler state' do
    source = event(
      'Coordinated', microflow: 'Coordinated',
                     schedule: { '$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 1 }
    )
    coordinator = Object.new
    coordinator.define_singleton_method(:claim_scheduled_event) { |**| true }
    coordinator.define_singleton_method(:complete_scheduled_event) { |**| raise 'completion failed' }
    logger = double('coordination logger', error: nil)
    logged = described_class.new(
      project_with(source), executor: ->(_name) {}, coordinator:, logger:, async: false
    )
    expect(logged.tick(Time.utc(2026, 8, 10, 12, 10)).size).to eq(1)
    expect(logger).to have_received(:error).with(/lease completion failed/)
    expect(logged.instance_variable_get(:@running_jobs)).to be_empty

    silent = described_class.new(
      project_with(source), executor: ->(_name) {}, coordinator:, async: false
    )
    expect(silent.tick(Time.utc(2026, 8, 10, 12, 10)).size).to eq(1)
    expect(silent.send(:stop_heartbeat, nil)).to be_nil

    job = silent.jobs.first
    state = -> { { mutex: Mutex.new, condition: ConditionVariable.new, stopping: false } }
    stops = Object.new
    stops.define_singleton_method(:claim_scheduled_event) { |**| true }
    stops.define_singleton_method(:complete_scheduled_event) { |**| true }
    stops.define_singleton_method(:renew_scheduled_event) { |**| false }
    stopping = described_class.new(
      project_with(source), executor: ->(_name) {}, coordinator: stops, lease_ttl: 0.01, async: false
    )
    expect(stopping.send(:heartbeat_loop, job, 'minute:1', state.call)).to be_nil

    broken = Object.new
    broken.define_singleton_method(:claim_scheduled_event) { |**| true }
    broken.define_singleton_method(:complete_scheduled_event) { |**| true }
    broken.define_singleton_method(:renew_scheduled_event) { |**| raise 'renewal failed' }
    noisy = described_class.new(
      project_with(source), executor: ->(_name) {}, coordinator: broken,
                            logger:, lease_ttl: 0.01, async: false
    )
    expect(noisy.send(:heartbeat_loop, job, 'minute:1', state.call)).to be_nil
    expect(logger).to have_received(:error).with(/lease renewal failed/)
    quiet = described_class.new(
      project_with(source), executor: ->(_name) {}, coordinator: broken,
                            lease_ttl: 0.01, async: false
    )
    expect(quiet.send(:heartbeat_loop, job, 'minute:1', state.call)).to be_nil
  end

  it 'uses IANA daylight-saving transitions and de-duplicates repeated daily wall-clock slots' do
    daily = event(
      'DailyNewYork', microflow: 'Daily',
                      schedule: { '$Type' => 'ScheduledEvents$DaySchedule',
                                  'HourOfDay' => 1, 'MinuteOfHour' => 30 }
    ).merge('TimeZone' => 'America/New_York')
    calls = []
    scheduler = described_class.new(
      project_with(daily), executor: ->(name) { calls << name }, async: false
    )

    before_spring = scheduler.send(:event_time, Time.utc(2026, 3, 8, 6, 30), 'America/New_York')
    after_spring = scheduler.send(:event_time, Time.utc(2026, 3, 8, 7, 30), 'America/New_York')
    expect([before_spring.hour, before_spring.utc_offset]).to eq([1, -18_000])
    expect([after_spring.hour, after_spring.utc_offset]).to eq([3, -14_400])

    first_fold = Time.utc(2026, 11, 1, 5, 30)
    second_fold = Time.utc(2026, 11, 1, 6, 30)
    first_local = scheduler.send(:event_time, first_fold, 'America/New_York')
    second_local = scheduler.send(:event_time, second_fold, 'America/New_York')
    expect([first_local.hour, first_local.utc_offset]).to eq([1, -14_400])
    expect([second_local.hour, second_local.utc_offset]).to eq([1, -18_000])
    expect(scheduler.tick(first_fold).size).to eq(1)
    expect(scheduler.tick(second_fold)).to be_empty
    expect(calls).to eq(['Sales.Daily'])
  end

  it 'runs both repeated hourly slots and rejects unknown IANA zones explicitly' do
    hourly = event(
      'HourlyNewYork', microflow: 'Hourly',
                       schedule: { '$Type' => 'ScheduledEvents$HourSchedule',
                                   'Multiplier' => 1, 'MinuteOffset' => 30 }
    ).merge('TimeZone' => 'America/New_York')
    calls = []
    scheduler = described_class.new(
      project_with(hourly), executor: ->(name) { calls << name }, async: false
    )

    expect(scheduler.tick(Time.utc(2026, 11, 1, 5, 30)).size).to eq(1)
    expect(scheduler.tick(Time.utc(2026, 11, 1, 6, 30)).size).to eq(1)
    expect(calls).to eq(%w[Sales.Hourly Sales.Hourly])
    expect do
      scheduler.send(:event_time, Time.utc(2026), 'Mars/Olympus_Mons')
    end.to raise_error(ArgumentError, /unknown scheduled-event time zone/)

    hide_const('TZInfo')
    fresh = described_class.new(project_with(hourly), executor: ->(_name) {}, async: false)
    expect do
      fresh.send(:event_time, Time.utc(2026), 'America/New_York')
    end.to raise_error(ArgumentError, /requires the tzinfo gem/)
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock, Metrics/BlockLength
