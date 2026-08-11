# frozen_string_literal: true

require 'puma'
require 'uri'

module Mxrb
  module Http
    # Case-insensitive HTTP header collection used by the internal request API.
    class Headers
      def initialize(values = {})
        @values = values.to_h { |name, value| [name.to_s.downcase, value.to_s] }
      end

      def [](name) = @values[name.to_s.downcase]
    end

    Request = Data.define(:path, :request_method, :body, :query, :headers) do
      def [](name) = headers[name]
    end

    # Mutable response keeps the existing MXRB dispatchers independent of Rack.
    class Response
      attr_accessor :status, :body
      attr_reader :headers

      def initialize
        @status = 200
        @body = ''
        @headers = {}
      end

      def [](name) = headers[name]

      def []=(name, value)
        headers[name] = value
      end
    end

    # Small embedded-Puma adapter for MXRB's loopback-only HTTP services.
    class Server
      DEFAULT_MAX_THREADS = 5

      attr_reader :host, :port, :puma

      def initialize(host:, port:, logger: nil, max_threads: DEFAULT_MAX_THREADS, &dispatcher)
        raise ArgumentError, 'HTTP dispatcher is required' unless dispatcher

        @host = host.to_s
        @port = Integer(port)
        @dispatcher = dispatcher
        @logger = logger
        @max_threads = Integer(max_threads)
      end

      def start
        @puma = Puma::Server.new(method(:call), nil, puma_options)
        @puma.add_tcp_listener(host, port)
        yield(@puma) if block_given?
        @thread = @puma.run
        @thread.join
      end

      def shutdown = @puma&.stop

      def call(environment)
        request = request_from(environment)
        response = Response.new
        @dispatcher.call(request, response)
        [response.status, response.headers, [response.body.to_s]]
      end

      private

      def puma_options
        {
          min_threads: 0,
          max_threads: @max_threads,
          environment: 'production',
          log_writer: @logger || Puma::LogWriter.null,
          queue_requests: true
        }
      end

      def request_from(environment)
        input = environment['rack.input']
        body = input ? input.read.to_s : ''
        input.rewind if input.respond_to?(:rewind)
        Request.new(
          path: "#{environment['SCRIPT_NAME']}#{environment.fetch('PATH_INFO', '/')}",
          request_method: environment.fetch('REQUEST_METHOD', 'GET'),
          body:,
          query: URI.decode_www_form(environment['QUERY_STRING'].to_s).to_h,
          headers: Headers.new(request_headers(environment))
        )
      end

      def request_headers(environment)
        environment.each_with_object({}) do |(name, value), headers|
          next unless name.start_with?('HTTP_')

          header = name.delete_prefix('HTTP_').split('_').map(&:capitalize).join('-')
          headers[header] = value
        end
      end
    end
  end
end
