# frozen_string_literal: true

require_relative '../progress'
require_relative 'protocol'

module Mxrb
  module Studio
    # Cooperative cancellation, progress and notifications for one request.
    # Long MXRB operations already report through Mxrb::Progress; while a
    # request runs, its thread's progress task is a ProgressTask, so every
    # progress update becomes a protocol notification and a cancellation point.
    class RequestContext
      attr_reader :id

      def initialize(id: nil, notifier: nil)
        @id = id
        @notifier = notifier
        @cancelled = false
        @hooks = {}
        @mutex = Mutex.new
      end

      def cancel!
        hooks = @mutex.synchronize do
          @cancelled = true
          @hooks.values
        end
        hooks.each(&:call)
      end

      def cancelled? = @cancelled

      def check!
        raise Cancelled, 'request cancelled' if @cancelled
      end

      # Registers a hook that runs once when the request is cancelled (or now,
      # when it already was). Returns a handle for #remove_cancel_hook.
      def on_cancel(&hook)
        handle = Object.new
        immediate = @mutex.synchronize do
          @hooks[handle] = hook unless @cancelled
          @cancelled
        end
        hook.call if immediate
        handle
      end

      def remove_cancel_hook(handle)
        @mutex.synchronize { @hooks.delete(handle) }
      end

      def notify(method, params)
        @notifier&.call(method, params)
      end

      def with_progress(label, total: nil)
        previous = Thread.current[Mxrb::Progress::THREAD_KEY]
        task = ProgressTask.new(self, label, total:).start
        Thread.current[Mxrb::Progress::THREAD_KEY] = task
        result = yield task
        task.finish
        result
      rescue StandardError => e
        task&.fail(e.message)
        raise
      ensure
        Thread.current[Mxrb::Progress::THREAD_KEY] = previous
      end
    end

    # Mxrb::Progress task that reports `$/progress` notifications.
    class ProgressTask
      INTERVAL = 0.1
      attr_reader :label, :total, :current, :detail

      class << self
        attr_writer :interval

        def interval = @interval || INTERVAL
      end

      def initialize(context, label, total: nil)
        @context = context
        @label = label.to_s
        @total = total
        @current = 0
        @detail = nil
        @reported_at = nil
      end

      def enabled? = true

      def start
        emit('begin', force: true)
        self
      end

      def update(current: nil, total: nil, detail: nil, force: false)
        @total = Integer(total) unless total.nil?
        @current = Integer(current) unless current.nil?
        @detail = detail.to_s unless detail.nil?
        emit('report', force:)
        self
      end

      def advance(amount = 1, detail: nil, force: false)
        update(current: @current + amount, detail:, force:)
      end

      def add_total(amount)
        @total = (@total || 0) + Integer(amount)
        self
      end

      def finish(detail = nil)
        @detail = detail.to_s unless detail.nil?
        emit('end', force: true)
      end

      def fail(message = nil)
        @detail = message.to_s unless message.nil?
        emit('end', force: true, failed: true)
      end

      private

      def emit(kind, force:, failed: false)
        @context.check! unless kind == 'end'
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return self unless force || @reported_at.nil? || now - @reported_at >= self.class.interval

        @reported_at = now
        payload = { token: @context.id, kind:, label:, current:, total:, detail: }
        payload[:failed] = true if failed
        @context.notify('$/progress', payload)
        self
      end
    end
  end
end
