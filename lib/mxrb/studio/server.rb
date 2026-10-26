# frozen_string_literal: true

require 'json'
require_relative 'protocol'
require_relative 'request_context'
require_relative 'service'

module Mxrb
  module Studio
    # Long-lived JSON-RPC 2.0 server over a pair of streams (stdin/stdout for
    # an IDE). One message per line: JSON text never contains a raw newline.
    # Requests run concurrently on their own threads; `$/cancelRequest`
    # cancels one, `$/progress` and method-specific notifications report
    # while it runs, and every failure is a structured error object.
    class Server # rubocop:disable Metrics/ClassLength
      NOTIFICATIONS = %w[$/progress tasks/started tasks/output].freeze

      def initialize(input: $stdin, output: $stdout, service: Service.new)
        @input = input
        @output = output
        @service = service
        @write = Mutex.new
        @pending = {}
        @threads = []
        @initialized = false
        @shutdown = false
        @roots = []
      end

      def run
        @output.sync = true if @output.respond_to?(:sync=)
        while (line = @input.gets)
          next if line.strip.empty?

          break if handle(line) == :exit
        end
        finish
      end

      def handle(line)
        message = JSON.parse(line)
        return reply_error(nil, Protocol::INVALID_REQUEST, 'expected a JSON-RPC object') unless message.is_a?(Hash)
        return reply_error(message['id'], Protocol::INVALID_REQUEST, 'jsonrpc must be "2.0"') unless valid?(message)

        message.key?('id') ? request(message) : notification(message)
      rescue JSON::ParserError => e
        reply_error(nil, Protocol::PARSE_ERROR, e.message)
      end

      private

      def valid?(message)
        message['jsonrpc'] == '2.0' && message['method'].is_a?(String) &&
          (!message.key?('id') || message['id'].is_a?(String) || message['id'].is_a?(Integer))
      end

      def notification(message)
        case message['method']
        when '$/cancelRequest' then @pending[message.dig('params', 'id')]&.cancel!
        when 'exit' then :exit
        end
      end

      def request(message) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
        id = message['id']
        case message['method']
        when 'initialize' then reply(id, initialize_session(message['params'] || {}))
        when 'shutdown'
          @shutdown = true
          @threads.each(&:join)
          reply(id, nil)
        else
          return reply_error(id, Protocol::NOT_INITIALIZED, 'send initialize first') unless @initialized
          return reply_error(id, Protocol::INVALID_REQUEST, 'the server is shutting down') if @shutdown

          spawn(id, message['method'], message['params'])
        end
      rescue Protocol::Failure => e
        reply_error(id, e.code, e.message, e.data)
      end

      def initialize_session(params) # rubocop:disable Metrics/MethodLength
        versions = Array(params.fetch('protocol_versions', [params.fetch('protocol_version', Protocol::VERSION)]))
        unless versions.include?(Protocol::VERSION)
          raise Protocol::Failure.new(Protocol::UNSUPPORTED_PROTOCOL,
                                      "protocol #{versions.join(', ')} is not supported",
                                      { supported: [Protocol::VERSION] })
        end

        @roots = Array(params['roots']).map(&:to_s)
        @initialized = true
        { protocol: { name: Protocol::NAME, version: Protocol::VERSION },
          server: { name: 'mxrb', version: Mxrb::VERSION, ruby: RUBY_VERSION, pid: Process.pid },
          methods: @service.methods_list, notifications: NOTIFICATIONS,
          capabilities: { cancellation: true, progress: true, isolation: 'fork', undo: true, sync: true,
                          locks: true, framing: 'ndjson' } }
      end

      def spawn(id, method, params) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        context = RequestContext.new(id:, notifier: ->(name, payload) { send_message(method: name, params: payload) })
        @pending[id] = context
        thread = Thread.new do
          Thread.current.report_on_exception = false
          result = @service.dispatch(method, params, context)
          context.check!
          reply(id, result)
        rescue StandardError, ScriptError => e
          error = Protocol.error_object(e, roots: @roots + request_roots(params))
          reply_error(id, error[:code], error[:message], error[:data])
        ensure
          @pending.delete(id)
        end
        @threads << thread
        @threads.select!(&:alive?)
        nil
      end

      def request_roots(params)
        return [] unless params.is_a?(Hash)

        params.values_at('root', 'ruby_root', 'workspace_root').compact.map(&:to_s)
      end

      def reply(id, result) = send_message(id:, result:)

      def reply_error(id, code, message, data = nil)
        error = { code:, message: }
        error[:data] = data || { kind: Protocol::KINDS.fetch(code) }
        send_message(id:, error:)
      end

      def send_message(payload)
        line = JSON.generate({ jsonrpc: '2.0' }.merge(payload))
        @write.synchronize { @output.write("#{line}\n") }
        nil
      end

      def finish
        @pending.each_value(&:cancel!)
        @threads.each(&:join)
        @service.close
      end
    end
  end
end
