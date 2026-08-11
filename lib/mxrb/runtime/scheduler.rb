# frozen_string_literal: true

require 'time'

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
      attr_reader :jobs, :errors

      def initialize(project, executor: nil, clock: -> { Time.now.utc },
                     sleeper: Kernel.method(:sleep), poll_interval: 1.0,
                     skip_overlap: true, async: true, on_error: nil, logger: nil)
        raise ArgumentError, 'poll_interval must be positive' unless poll_interval.to_f.positive?

        @project = project
        @executor = executor || default_executor
        @clock = clock
        @sleeper = sleeper
        @poll_interval = poll_interval.to_f
        @skip_overlap = skip_overlap
        @async = async
        @on_error = on_error
        @logger = logger
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
          next unless reserve(job, slot)

          dispatch(job, async:)
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
        microflow = qualify(module_name, fetch(source, 'Microflow', :microflow))
        schedule = normalize_schedule(source)
        ScheduledJob.new(
          name:, qualified_name: qualified, microflow:, schedule:,
          overlap: fetch(source, 'OnOverlap', :on_overlap, :overlap) || 'SkipNext',
          enabled: fetch(source, 'Enabled', :enabled) != false,
          start_at: parse_time(fetch(source, 'StartDateTime', :start_at)),
          time_zone: fetch(source, 'TimeZone', :time_zone).to_s,
          source:
        )
      end

      def normalize_schedule(source)
        schedule = fetch(source, 'Schedule', :schedule)
        type = fetch(schedule, '$Type', :type).to_s
        case type
        when /MinuteSchedule\z/
          { type: :minute, every: positive(fetch(schedule, 'Multiplier', :multiplier)) }.freeze
        when /HourSchedule\z/
          {
            type: :hour, every: positive(fetch(schedule, 'Multiplier', :multiplier)),
            minute: integer(fetch(schedule, 'MinuteOffset', :minute_offset), 0) % 60
          }.freeze
        when /DaySchedule\z/
          {
            type: :day, every: 1,
            hour: integer(fetch(schedule, 'HourOfDay', :hour_of_day), 0) % 24,
            minute: integer(fetch(schedule, 'MinuteOfHour', :minute_of_hour), 0) % 60
          }.freeze
        else
          legacy_schedule(source)
        end
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
        end
      end

      def reserve(job, slot)
        @mutex.synchronize do
          return false if @last_slots[job.qualified_name] == slot
          return false if skip_overlap?(job) && @running_jobs[job.qualified_name]

          @last_slots[job.qualified_name] = slot
          @running_jobs[job.qualified_name] = true
          true
        end
      end

      def skip_overlap?(job)
        @skip_overlap || job.overlap.to_s.match?(/skip/i)
      end

      def dispatch(job, async:)
        unless async
          execute(job)
          return
        end

        worker = Thread.new { execute(job) }
        worker.name = "mxrb-job-#{job.qualified_name}" if worker.respond_to?(:name=)
        @mutex.synchronize { @workers << worker }
      end

      def execute(job)
        invoke_executor(job)
      rescue StandardError => e
        @mutex.synchronize { @errors << [job, e].freeze }
        @on_error&.call(job, e)
        @logger&.error("scheduled event #{job.qualified_name} failed: #{e.message}")
      ensure
        @mutex.synchronize { @running_jobs.delete(job.qualified_name) }
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
