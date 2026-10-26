# frozen_string_literal: true

require_relative 'protocol'
require_relative 'request_context'

module Mxrb
  module Studio
    # Runs untrusted or memory-hungry work (evaluating a Ruby project, exporting
    # a model) in a forked child, so a definition that exits, loops or leaks
    # cannot take the long-lived backend down. Progress and the result travel
    # back over a pipe; cancelling the request terminates the child.
    module Isolated
      # Child-side Mxrb::Progress task that forwards updates to the parent.
      class ChildProgress
        def initialize(writer) = @writer = writer
        def enabled? = true
        def start = self
        def finish(*) = self
        def fail(*) = self

        def update(current: nil, total: nil, detail: nil, force: false) # rubocop:disable Lint/UnusedMethodArgument
          Isolated.write_frame(@writer, [:progress, { current:, total:, detail: }])
          self
        end

        def advance(amount = 1, detail: nil, force: false) # rubocop:disable Lint/UnusedMethodArgument
          Isolated.write_frame(@writer, [:advance, { amount:, detail: }])
          self
        end

        def add_total(amount)
          Isolated.write_frame(@writer, [:add_total, { amount: }])
          self
        end
      end

      module_function

      def run(context, roots: [], &) # rubocop:disable Metrics/MethodLength
        reader, writer = ::IO.pipe
        pid = fork { begin; serve_child(reader, writer, roots, &); ensure; exit!(0); end }
        writer.close
        hook = context.on_cancel { terminate(pid) }
        begin
          result = receive(reader, context)
        ensure
          context.remove_cancel_hook(hook)
          reader.close
          Process.wait(pid)
        end
        context.check!
        unpack(result)
      end

      # Child side of #run, kept free of process control so it can be tested.
      def serve_child(reader, writer, roots) # rubocop:disable Metrics/MethodLength
        reader.close
        Thread.current[Mxrb::Progress::THREAD_KEY] = ChildProgress.new(writer)
        frame = begin
          [:ok, yield]
        rescue SystemExit => e
          [:error, failure_payload(RubySourceError.new("Ruby code exited with status #{e.status}"), roots)]
        rescue Exception => e # rubocop:disable Lint/RescueException
          [:error, failure_payload(e, roots)]
        end
        write_frame(writer, frame)
      ensure
        writer.close
      end

      def failure_payload(error, roots)
        Protocol.error_object(error, roots:)
      end

      def receive(reader, context)
        task = Thread.current[Mxrb::Progress::THREAD_KEY] || Mxrb::Progress::NullTask.instance
        loop do
          kind, payload = read_frame(reader)
          return [kind, payload] unless kind && %i[progress advance add_total].include?(kind)

          forward(task, kind, payload, context)
        end
      end

      def forward(task, kind, payload, context)
        case kind
        when :progress then task.update(**payload)
        when :advance then task.advance(payload[:amount], detail: payload[:detail])
        else task.add_total(payload[:amount])
        end
      rescue Cancelled
        context.cancel!
      end

      def unpack(result)
        kind, payload = result
        raise Protocol::Failure.new(Protocol::INTERNAL_ERROR, 'isolated worker ended without a result') unless kind
        return payload if kind == :ok

        data = payload.fetch(:data)
        raise Protocol::Failure.new(payload.fetch(:code), payload.fetch(:message), data)
      end

      def terminate(pid)
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        nil
      end

      def write_frame(writer, frame)
        bytes = Marshal.dump(frame)
        writer.write([bytes.bytesize].pack('Q<'), bytes)
      end

      def read_frame(reader)
        header = reader.read(8)
        return unless header&.bytesize == 8

        Marshal.load(reader.read(header.unpack1('Q<'))) # rubocop:disable Security/MarshalLoad
      end
    end
  end
end
