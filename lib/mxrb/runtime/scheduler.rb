# frozen_string_literal: true

require 'time'
require 'securerandom'
require_relative 'shared_store'

begin
  require 'tzinfo'
rescue LoadError
  # UTC, local time and numeric offsets remain available without tzinfo. IANA
  # names fail explicitly when resolved instead of silently becoming UTC.
end

# Schedule normalization and lifecycle state deliberately live together so a
# Scheduler instance owns all of its threads and overlap bookkeeping.
# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
# rubocop:disable Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity

module Mxrb
  module Runtime
    ScheduledJob = Data.define(
      :name, :qualified_name, :microflow, :schedule, :overlap, :enabled,
      :start_at, :time_zone, :source
    )

    # Small stdlib-only scheduled-event runner. Execution, time, and sleeping
    # are injectable so applications can connect it to their Ruby microflow
    # runtime and test it without waiting for wall-clock time.
    class Scheduler
      WEEK_DAYS = {
        'Sunday' => 0, 'Monday' => 1, 'Tuesday' => 2, 'Wednesday' => 3,
        'Thursday' => 4, 'Friday' => 5, 'Saturday' => 6
      }.freeze

      attr_reader :jobs, :errors

      def initialize(project, executor: nil, clock: -> { Time.now.utc },
                     sleeper: Kernel.method(:sleep), poll_interval: 1.0,
                     skip_overlap: true, async: true, on_error: nil, logger: nil,
                     coordinator: nil, lease_ttl: 300, owner: nil)
        raise ArgumentError, 'poll_interval must be positive' unless poll_interval.to_f.positive?
        raise ArgumentError, 'lease_ttl must be positive' unless lease_ttl.to_f.positive?

        @project = project
        @executor = executor || default_executor
        @clock = clock
        @sleeper = sleeper
        @poll_interval = poll_interval.to_f
        @skip_overlap = skip_overlap
        @async = async
        @on_error = on_error
        @logger = logger
        @coordinator = coordinator || MemorySharedStore.new
        @lease_ttl = lease_ttl.to_f
        @owner = owner || "#{Process.pid}-#{SecureRandom.uuid}"
        @time_zones = {}
        @jobs = load_jobs.freeze
        @errors = []
        @last_slots = {}
        @running_jobs = {}
        @workers = []
        @mutex = Mutex.new
        @stopping = false
        @thread = nil
      end

      def running? = @mutex.synchronize { @thread&.alive? == true }

      def start
        @mutex.synchronize do
          return self if @thread&.alive?

          @stopping = false
          @thread = Thread.new { run_loop }
          @thread.name = 'mxrb-scheduler' if @thread.respond_to?(:name=)
        end
        self
      end

      def shutdown(wait: true)
        thread = @mutex.synchronize do
          @stopping = true
          @thread
        end
        thread&.join if wait && thread != Thread.current
        wait_for_jobs if wait
        @mutex.synchronize { @thread = nil unless @thread&.alive? }
        self
      end
      alias stop shutdown

      # Evaluates all jobs once and returns the jobs that were dispatched.
      def tick(now = @clock.call, async: @async)
        cleanup_workers
        jobs.filter_map do |job|
          slot = due_slot(job, now)
          next unless slot
          next unless reserve(job, slot, now)

          dispatch(job, slot, async:)
          job
        end
      end

      def wait_for_jobs
        loop do
          workers = @mutex.synchronize { @workers.select(&:alive?) }
          break if workers.empty?

          workers.each { _1.join unless _1 == Thread.current }
        end
        cleanup_workers
        self
      end

      private

      def default_executor
        return @project.method(:execute_microflow) if @project.respond_to?(:execute_microflow)

        raise ArgumentError, 'executor is required unless project responds to execute_microflow'
      end

      def load_jobs
        @project.modules.flat_map do |mod|
          Array(mod.scheduled_events).map { normalize_job(mod.name, _1) }
        end
      end

      def normalize_job(module_name, source)
        name = fetch(source, 'Name', :name).to_s
        qualified = qualify(module_name, fetch(source, 'QualifiedName', :qualified_name) || name)
        microflow_name = fetch(source, 'Microflow', :microflow)
        microflow = qualify(module_name, microflow_name)
        enabled = fetch(source, 'Enabled', :enabled) != false
        schedule = enabled ? normalize_schedule(source) : nil
        ScheduledJob.new(
          name:, qualified_name: qualified, microflow:, schedule:,
          overlap: fetch(source, 'OnOverlap', :on_overlap, :overlap) || 'SkipNext',
          enabled:,
          start_at: parse_time(fetch(source, 'StartDateTime', :start_at)),
          time_zone: fetch(source, 'TimeZone', :time_zone).to_s,
          source:
        )
      end

      def normalize_schedule(source)
        return legacy_schedule(source) unless schedule_declared?(source)

        schedule = fetch(source, 'Schedule', :schedule)
        type = fetch(schedule, '$Type', :type).to_s
        case type
        when /MinuteSchedule\z/
          { type: :minute, every: positive(schedule_value(schedule, 'Multiplier', :multiplier)) }.freeze
        when /HourSchedule\z/
          {
            type: :hour,
            every: positive(schedule_value(schedule, 'Multiplier', :multiplier)),
            minute: schedule_integer(
              schedule, 'MinuteOffset', :minute_offset, range: 0..59
            )
          }.freeze
        when /DaySchedule\z/
          {
            type: :day, every: 1,
            hour: schedule_integer(schedule, 'HourOfDay', :hour_of_day, range: 0..23),
            minute: schedule_integer(schedule, 'MinuteOfHour', :minute_of_hour, range: 0..59)
          }.freeze
        when /WeekSchedule\z/
          week_schedule(schedule)
        else
          raise ArgumentError, "unsupported scheduled-event schedule type #{type.inspect}"
        end
      end

      def schedule_declared?(source)
        source.respond_to?(:key?) && (source.key?('Schedule') || source.key?(:schedule))
      end

      def week_schedule(schedule)
        days = WEEK_DAYS.filter_map do |name, number|
          number if schedule_value(schedule, name, name.downcase.to_sym) == true
        end
        raise ArgumentError, 'scheduled-event week schedule requires a day' if days.empty?

        {
          type: :week, days: days.freeze,
          hour: schedule_integer(schedule, 'HourOfDay', :hour_of_day, range: 0..23),
          minute: schedule_integer(schedule, 'MinuteOfHour', :minute_of_hour, range: 0..59)
        }.freeze
      end

      def schedule_integer(schedule, *keys, range:)
        value = integer(schedule_value(schedule, *keys), 0)
        return value if range.cover?(value)

        raise ArgumentError,
              "scheduled-event #{keys.first} must be in #{range.begin}..#{range.end}"
      end

      def schedule_value(schedule, *keys)
        value = fetch(schedule, *keys)
        return value unless value.nil?

        fetch(fetch(schedule, 'Properties', :properties), *keys)
      end

      def legacy_schedule(source)
        type = fetch(source, 'IntervalType', :interval_type).to_s.downcase
        every = positive(fetch(source, 'Interval', :interval))
        case type
        when 'minute' then { type: :minute, every: }.freeze
        when 'hour' then { type: :hour, every:, minute: 0 }.freeze
        when 'day' then { type: :day, every:, hour: 0, minute: 0 }.freeze
        else
          raise ArgumentError, "unsupported scheduled-event interval #{type.inspect}"
        end
      end

      def due_slot(job, now)
        return unless job.enabled

        time = event_time(now, job.time_zone)
        start = job.start_at && event_time(job.start_at, job.time_zone)
        return if start && time < start

        schedule = job.schedule
        case schedule.fetch(:type)
        when :minute
          minute = time.to_i / 60
          anchor = start ? start.to_i / 60 : 0
          minute if ((minute - anchor) % schedule.fetch(:every)).zero?
        when :hour
          return unless time.min == schedule.fetch(:minute)

          hour = time.to_i / 3600
          anchor = start ? start.to_i / 3600 : 0
          hour if ((hour - anchor) % schedule.fetch(:every)).zero?
        when :day
          return unless time.hour == schedule.fetch(:hour) && time.min == schedule.fetch(:minute)

          day = time.to_date.jd
          anchor = start ? start.to_date.jd : 0
          day if ((day - anchor) % schedule.fetch(:every)).zero?
        when :week
          return unless schedule.fetch(:days).include?(time.wday)
          return unless time.hour == schedule.fetch(:hour) && time.min == schedule.fetch(:minute)

          time.to_date.jd
        end
      end

      def reserve(job, slot, now)
        @mutex.synchronize do
          return false if @last_slots[job.qualified_name] == slot
          return false if skip_overlap?(job) && @running_jobs[job.qualified_name]

          slot_key = "#{job.schedule.fetch(:type)}:#{slot}"
          claimed = @coordinator.claim_scheduled_event(
            event: job.qualified_name, slot: slot_key, owner: @owner,
            now:, lease_until: now + @lease_ttl, skip_overlap: skip_overlap?(job)
          )
          return false unless claimed

          @last_slots[job.qualified_name] = slot
          @running_jobs[job.qualified_name] = slot_key
          true
        end
      end

      def skip_overlap?(job)
        @skip_overlap || job.overlap.to_s.match?(/(?:skip|delay)/i)
      end

      def dispatch(job, slot = nil, async:)
        slot_key = slot && "#{job.schedule.fetch(:type)}:#{slot}"
        slot_key ||= @running_jobs[job.qualified_name] || "manual:#{SecureRandom.uuid}"
        unless async
          execute(job, slot_key)
          return
        end

        worker = Thread.new { execute(job, slot_key) }
        worker.name = "mxrb-job-#{job.qualified_name}" if worker.respond_to?(:name=)
        @mutex.synchronize { @workers << worker }
      end

      def execute(job, slot)
        heartbeat = start_heartbeat(job, slot)
        invoke_executor(job)
      rescue StandardError => e
        @mutex.synchronize { @errors << [job, e].freeze }
        @on_error&.call(job, e)
        @logger&.error("scheduled event #{job.qualified_name} failed: #{e.message}")
      ensure
        stop_heartbeat(heartbeat)
        begin
          @coordinator.complete_scheduled_event(
            event: job.qualified_name, slot:, owner: @owner
          )
        rescue StandardError => e
          @logger&.error("scheduled event #{job.qualified_name} lease completion failed: #{e.message}")
        ensure
          @mutex.synchronize { @running_jobs.delete(job.qualified_name) }
        end
      end

      def start_heartbeat(job, slot)
        return unless @coordinator.respond_to?(:renew_scheduled_event)

        state = { mutex: Mutex.new, condition: ConditionVariable.new, stopping: false }
        state[:thread] = Thread.start do
          heartbeat_loop(job, slot, state)
        end
        state[:thread].name = "mxrb-lease-#{job.qualified_name}"
        state
      end

      def heartbeat_loop(job, slot, state)
        interval = [@lease_ttl / 3.0, 0.01].max
        loop do
          stopping = state.fetch(:mutex).synchronize do
            if state.fetch(:stopping)
              true
            else
              state.fetch(:condition).wait(state.fetch(:mutex), interval)
              state.fetch(:stopping)
            end
          end
          break if stopping

          now = @clock.call
          renewed = @coordinator.renew_scheduled_event(
            event: job.qualified_name, slot:, owner: @owner,
            lease_until: now + @lease_ttl
          )
          break unless renewed
        end
      rescue StandardError => e
        @logger&.error("scheduled event #{job.qualified_name} lease renewal failed: #{e.message}")
      end

      def stop_heartbeat(state)
        return unless state

        state.fetch(:mutex).synchronize do
          state[:stopping] = true
          state.fetch(:condition).broadcast
        end
        state.fetch(:thread).join
      end

      def invoke_executor(job)
        callable = if @executor.respond_to?(:execute_microflow)
                     @executor.method(:execute_microflow)
                   elsif @executor.respond_to?(:call)
                     @executor
                   else
                     raise ArgumentError, 'executor must be callable or implement execute_microflow'
                   end
        case callable.arity
        when 0 then callable.call
        when 1 then callable.call(job.microflow)
        else callable.call(job.microflow, scheduled_event: job)
        end
      end

      def run_loop
        until stopping?
          tick
          @sleeper.call(@poll_interval) unless stopping?
        end
      rescue StandardError => e
        @mutex.synchronize { @errors << [nil, e].freeze }
        @on_error&.call(nil, e)
        @logger&.error("scheduler failed: #{e.message}")
      ensure
        @mutex.synchronize { @thread = nil if @thread == Thread.current }
      end

      def stopping? = @mutex.synchronize { @stopping }

      def cleanup_workers
        @mutex.synchronize do
          @workers.each { _1.join if !_1.alive? && _1 != Thread.current }
          @workers.select!(&:alive?)
        end
      end

      def event_time(time, zone)
        return time.getutc if zone.empty? || zone.casecmp('UTC').zero?
        return time.getlocal if zone.casecmp('local').zero?
        return time.getlocal(zone) if zone.match?(/\A[+-]\d{2}:?\d{2}\z/)

        time_zone(zone).utc_to_local(time.getutc)
      end

      def time_zone(name)
        unless defined?(TZInfo::Timezone)
          raise ArgumentError,
                "IANA time zone #{name.inspect} requires the tzinfo gem"
        end

        @time_zones[name] ||= TZInfo::Timezone.get(name)
      rescue StandardError => e
        raise unless defined?(TZInfo::InvalidTimezoneIdentifier) &&
                     e.is_a?(TZInfo::InvalidTimezoneIdentifier)

        raise ArgumentError, "unknown scheduled-event time zone #{name.inspect}"
      end

      def parse_time(raw)
        return raw if raw.respond_to?(:to_time)
        return if raw.nil? || raw.to_s.empty?

        Time.iso8601(raw.to_s)
      rescue ArgumentError
        nil
      end

      def qualify(module_name, raw)
        name = raw.to_s
        return name if name.empty? || name.include?('.')

        "#{module_name}.#{name}"
      end

      def fetch(hash, *keys)
        return nil unless hash.respond_to?(:key?)

        keys.each { return hash[_1] if hash.key?(_1) }
        nil
      end

      def positive(value)
        number = integer(value, 1)
        raise ArgumentError, 'scheduled-event interval must be positive' unless number.positive?

        number
      end

      def integer(value, fallback) = value.nil? ? fallback : Integer(value)
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
# rubocop:enable Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
