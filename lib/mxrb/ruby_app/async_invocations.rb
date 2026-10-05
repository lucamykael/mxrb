# frozen_string_literal: true

require 'securerandom'

module Mxrb
  module RubyApp
    # HTTP requests enqueue once and poll without holding the application's
    # execution lock. Results belong to the session which submitted the call.
    class AsyncInvocations
      def initialize(application, limit: 1000, retention: 3600, clock: lambda {
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      })
        @application = application
        @limit = limit
        @retention = retention
        @clock = clock
        @jobs = {}
        @mutex = Mutex.new
        @queue = Queue.new
        @closed = false
      end

      def submit(name, arguments, owner:, context:)
        validate_arguments(name, arguments)

        @mutex.synchronize do
          raise ArgumentError, 'asynchronous invocations are closed' if @closed

          prune
          raise ArgumentError, 'asynchronous invocation capacity exceeded' if @jobs.length >= @limit

          enqueue(name, arguments, owner, context)
        end
      end

      def fetch(id, owner:)
        @mutex.synchronize do
          prune
          job = @jobs[id]
          next unless job && job.fetch(:owner) == owner

          job.slice(:status, :result, :error)
        end
      end

      def close
        worker = @mutex.synchronize do
          next if @closed

          @closed = true
          next unless @worker

          @queue << nil
          @worker
        end
        worker&.join
      end

      private

      def validate_arguments(name, arguments)
        raise ArgumentError, 'microflow name must be a nonempty string' unless name.is_a?(String) && !name.empty?
        raise ArgumentError, 'arguments must be an object' unless arguments.is_a?(Hash)
      end

      def enqueue(name, arguments, owner, context)
        snapshot = Marshal.load(Marshal.dump(arguments))
        id = SecureRandom.uuid
        @jobs[id] = { owner:, status: 'pending', created_at: @clock.call }
        @worker ||= Thread.new { work }
        @queue << [id, name, snapshot, context]
        { id:, status: 'pending' }
      end

      def work
        while (task = @queue.pop)
          id, name, arguments, context = task
          begin
            result = @application.invoke_service(name, arguments, context:)
            complete(id, status: 'completed', result:)
          rescue StandardError => e
            complete(id, status: 'failed', error: { code: 'invocation_failed', message: e.message })
          end
        end
      end

      def complete(id, **values)
        @mutex.synchronize { @jobs.fetch(id).merge!(values, completed_at: @clock.call) }
      end

      def prune
        now = @clock.call
        @jobs.delete_if { |_id, job| job[:completed_at] && now - job.fetch(:completed_at) >= @retention }
      end
    end
  end
end
