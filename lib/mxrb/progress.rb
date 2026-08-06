# frozen_string_literal: true

require 'io/console'
require 'singleton'

module Mxrb
  # Terminal progress rendering shared by every long-running MXRB operation.
  # It is enabled automatically only for an interactive terminal, writes to
  # stderr, and therefore never contaminates command output or JSON on stdout.
  module Progress
    THREAD_KEY = :mxrb_progress_task
    FALSE_VALUES = %w[0 false no off].freeze

    # No-op object returned when progress rendering is disabled.
    class NullTask
      include Singleton

      def start = self
      def update(**) = self
      def advance(*, **) = self
      def add_total(*) = self
      def finish(*) = self
      def fail(*) = self
      def enabled? = false
    end

    # Thread-safe terminal renderer for a single operation.
    class Task # rubocop:disable Metrics/ClassLength
      SPINNER = %w[| / - \\].freeze
      BAR_WIDTH = 28
      REFRESH_INTERVAL = 0.08

      attr_reader :label, :total, :current

      def initialize(label, total: nil, io: $stderr)
        @label = label.to_s
        @total = normalize_total(total)
        @io = io
        @current = 0
        @detail = nil
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_rendered_at = 0.0
        @spinner_index = 0
        @mutex = Mutex.new
        @finished = false
      end

      def enabled? = true

      def start
        render(force: true)
        start_spinner unless determinate?
        self
      end

      def update(current: nil, total: nil, detail: nil, force: false)
        became_determinate = false
        @mutex.synchronize do
          became_determinate = @total.nil? && !total.nil?
          @total = normalize_total(total) unless total.nil?
          @current = [[Integer(current), 0].max, @total || Float::INFINITY].min unless current.nil?
          @detail = detail.to_s unless detail.nil?
        end
        stop_spinner if became_determinate
        render(force:)
        self
      end

      def advance(amount = 1, detail: nil, force: false)
        @mutex.synchronize do
          @current += amount
          @current = [@current, @total].min if @total
          @detail = detail.to_s unless detail.nil?
        end
        render(force:)
        self
      end

      def add_total(amount)
        @mutex.synchronize { @total = (@total || 0) + Integer(amount) }
        render(force: true)
        self
      end

      def finish(detail = nil)
        stop_spinner
        @mutex.synchronize do
          return self if @finished

          @detail = detail.to_s if detail
          @current = @total if @total
          @finished = true
        end
        render(force: true, final: true)
        self
      end

      def fail(message = nil)
        stop_spinner
        @mutex.synchronize do
          return self if @finished

          @detail = message.to_s unless message.to_s.empty?
          @finished = true
        end
        render(force: true, final: true, failed: true)
        self
      end

      private

      def normalize_total(value)
        return nil if value.nil?

        [Integer(value), 1].max
      end

      def determinate? = !@total.nil?

      def start_spinner
        return unless dynamic_terminal?

        @spinner_thread = Thread.new do
          loop do
            sleep REFRESH_INTERVAL
            break if @mutex.synchronize { @finished }

            render(force: true)
          end
        end
      end

      def stop_spinner
        thread = @spinner_thread
        return unless thread

        @mutex.synchronize { @finished = true }
        thread.join
        @spinner_thread = nil
        @mutex.synchronize { @finished = false }
      end

      def render(force: false, final: false, failed: false) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        line = nil
        @mutex.synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return if !force && !final && now - @last_rendered_at < REFRESH_INTERVAL

          @last_rendered_at = now
          line = rendered_line(now, failed:)
        end
        prefix = dynamic_terminal? ? "\r\e[2K" : ''
        suffix = final || !dynamic_terminal? ? "\n" : ''
        @io.write("#{prefix}#{truncate(line)}#{suffix}")
        @io.flush if @io.respond_to?(:flush)
      rescue IOError, Errno::EPIPE
        nil
      end

      def rendered_line(now, failed:)
        detail = @detail.to_s.empty? ? '' : " - #{@detail}"
        elapsed = format('%.1fs', now - @started_at)
        return "[mxrb] [FAILED] #{@label}#{detail} (#{elapsed})" if failed

        determinate_line(detail, elapsed) || spinner_line(detail, elapsed)
      end

      def determinate_line(detail, elapsed)
        return unless determinate?

        ratio = [@current.fdiv(@total), 1.0].min
        filled = (ratio * BAR_WIDTH).round
        bar = '#' * filled + '-' * (BAR_WIDTH - filled)
        "[mxrb] [#{bar}] #{format('%3d%%', ratio * 100)} #{@label}#{detail} (#{elapsed})"
      end

      def spinner_line(detail, elapsed)
        frame = SPINNER[@spinner_index % SPINNER.length]
        @spinner_index += 1
        "[mxrb] [#{frame}] #{@label}#{detail} (#{elapsed})"
      end

      def dynamic_terminal?
        @io.respond_to?(:tty?) && @io.tty?
      end

      def truncate(line)
        width = @io.respond_to?(:winsize) ? @io.winsize.last : 100
        width = 100 unless width.to_i.positive?
        return line if line.length <= width

        "#{line[0, width - 3]}..."
      rescue IOError, Errno::ENOTTY
        line
      end
    end # rubocop:enable Metrics/ClassLength

    class << self
      attr_writer :io

      def configure(enabled: nil, io: nil)
        @enabled = enabled unless enabled.nil?
        @io = io if io
      end

      def reset!
        @enabled = nil
        @io = nil
      end

      def enabled?
        return @enabled unless @enabled.nil?
        return false if FALSE_VALUES.include?(ENV.fetch('MXRB_PROGRESS', '').downcase)

        output.respond_to?(:tty?) && output.tty?
      end

      def with(label, total: nil) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        active = Thread.current[THREAD_KEY]
        return yield(active) if active
        return yield(NullTask.instance) unless enabled?

        task = Task.new(label, total:, io: output).start
        Thread.current[THREAD_KEY] = task
        result = yield(task)
        task.finish
        result
      rescue StandardError => e
        task&.fail(e.message)
        raise
      ensure
        Thread.current[THREAD_KEY] = nil if defined?(task) && task
      end

      def current = Thread.current[THREAD_KEY] || NullTask.instance

      private

      def output = @io || $stderr
    end
  end
end
