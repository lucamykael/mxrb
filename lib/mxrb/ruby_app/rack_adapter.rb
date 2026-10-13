# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Exposes the same generic MXRB backend through the Rack protocol. Puma,
    # Sinatra and Rails presets mount this adapter instead of duplicating API
    # behavior or introducing a second application state.
    class RackAdapter
      Request = Struct.new(:path, :request_method, :body, :query, :headers) do
        def [](name) = headers[name]
      end

      # Minimal mutable response consumed by Server#dispatch.
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

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root)
        @server_mutex = Mutex.new
      end

      def server
        @server || @server_mutex.synchronize { @server ||= Server.new(root, port: 0) }
      end

      def call(environment)
        request = rack_request(environment)
        response = Response.new
        server.send(:dispatch, request, response)
        [response.status, response.headers, [response.body.to_s]]
      end

      def close = @server&.application&.close

      private

      def rack_request(environment)
        input = environment['rack.input']
        body = input ? input.read.to_s : ''
        input.rewind if input.respond_to?(:rewind)
        query = URI.decode_www_form(environment['QUERY_STRING'].to_s).to_h
        headers = {
          'Authorization' => environment['HTTP_AUTHORIZATION'].to_s,
          'Cookie' => environment['HTTP_COOKIE'].to_s,
          'X-CSRF-Token' => environment['HTTP_X_CSRF_TOKEN'].to_s
        }
        path = "#{environment['SCRIPT_NAME']}#{environment.fetch('PATH_INFO', '/')}"
        Request.new(
          path, environment.fetch('REQUEST_METHOD', 'GET'),
          body, query, headers
        )
      end
    end
    # rubocop:enable Metrics
  end
end
