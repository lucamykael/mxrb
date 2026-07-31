# frozen_string_literal: true

require 'json'
require 'webrick'

module Mxrb
  module Oql
    # Loopback-only JSON API for read-only queries against a synchronized
    # Mendix Runtime database.
    class Server
      MAX_BODY_BYTES = 1_048_576

      attr_reader :host, :port

      # rubocop:disable Metrics/ParameterLists
      def initialize(project_path, host: '127.0.0.1', port: 4567, database_port: 55_432,
                     workspace: nil, logger: nil)
        @host = host
        raise ArgumentError, 'the query server must bind to a loopback address' \
          unless %w[127.0.0.1 ::1 localhost].include?(@host)

        @port = Integer(port)
        @workspace = workspace || Runtime::DatabaseWorkspace.new(project_path, port: database_port)
        @logger = logger || WEBrick::Log.new(File::NULL)
      end
      # rubocop:enable Metrics/ParameterLists

      def start(prepare: true)
        @workspace.up if prepare
        @server = WEBrick::HTTPServer.new(
          BindAddress: @host, Port: @port, Logger: @logger, AccessLog: []
        )
        @server.mount_proc('/query') { |request, response| dispatch(request, response) }
        yield(@server) if block_given?
        @server.start
      end

      def shutdown = @server&.shutdown

      # rubocop:disable Metrics/MethodLength
      def execute(payload)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sql, warnings = query_sql(payload)
        rows = @workspace.query_rows(sql)
        {
          ok: true, rows:, row_count: rows.size, elapsed_ms: elapsed_ms(started),
          warnings:
        }
      rescue ArgumentError, JSON::ParserError => e
        error_payload(e, started, 'invalid_request')
      rescue StandardError => e
        error_payload(e, started, 'query_failed')
      end
      # rubocop:enable Metrics/MethodLength

      private

      # rubocop:disable Metrics/MethodLength
      def dispatch(request, response)
        if request.request_method != 'POST'
          return render(response, 405, ok: false, error: {
            code: 'method_not_allowed', message: 'use POST /query'
          })
        end
        if request.body.to_s.bytesize > MAX_BODY_BYTES
          return render(response, 413, ok: false, error: {
            code: 'request_too_large', message: 'request body exceeds 1 MiB'
          })
        end

        payload = JSON.parse(request.body.to_s)
        result = execute(payload)
        render(response, result[:ok] ? 200 : error_status(result), result)
      rescue JSON::ParserError => e
        render(response, 400, ok: false, error: {
          code: 'invalid_json', message: e.message
        })
      end
      # rubocop:enable Metrics/MethodLength

      # rubocop:disable Metrics/AbcSize
      def query_sql(payload)
        raise ArgumentError, 'JSON body must be an object' unless payload.is_a?(Hash)

        sql = payload['sql']
        oql = payload['oql']
        raise ArgumentError, 'provide exactly one of sql or oql' if sql.to_s.empty? == oql.to_s.empty?
        return [sql, []] unless sql.to_s.empty?

        view = Translator.new(dialect: :postgresql).translate_source(oql)
        raise ArgumentError, view.warnings.join('; ') unless view.supported?
        raise ArgumentError, 'parameterized OQL is not supported by the HTTP endpoint' \
          unless view.parameters.empty?

        [view.sql, view.warnings]
      end
      # rubocop:enable Metrics/AbcSize

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
      end

      def error_payload(error, started, code)
        {
          ok: false, error: { code:, message: error.message },
          elapsed_ms: elapsed_ms(started)
        }
      end

      def error_status(result)
        result.dig(:error, :code) == 'invalid_request' ? 400 : 422
      end

      def render(response, status, payload)
        response.status = status
        response['Content-Type'] = 'application/json; charset=utf-8'
        response.body = JSON.generate(payload)
      end
    end
  end
end
