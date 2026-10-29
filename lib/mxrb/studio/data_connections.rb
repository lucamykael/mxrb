# frozen_string_literal: true

require_relative '../runtime/database_workspace'
require_relative 'protocol'

module Mxrb
  module Studio
    # The database connections a Studio client may use for a model. Physical
    # schema, SQL/OQL and plans always name one of these explicitly: the
    # client chooses it, and every result echoes it, so a result is never
    # shown without the connection and environment it came from.
    class DataConnections
      # The Runtime port is part of the workspace fingerprint; without the
      # port the workspace was started with, schema currency is unknown.
      def initialize(project_path, database_port: 55_432, runtime_port: 18_080, workspace: nil)
        @path = File.expand_path(project_path)
        @database_port = Integer(database_port)
        @runtime_port = Integer(runtime_port)
        @workspace = workspace
      end

      def list = [descriptor]

      # The workspace behind a client's explicit choice; an absent or stale
      # choice is refused rather than silently replaced by a default.
      def resolve!(connection) # rubocop:disable Metrics/MethodLength
        id = connection.is_a?(Hash) ? connection['id'] : connection
        if !id.is_a?(String) || id.empty?
          raise Protocol::Failure.new(Protocol::CONNECTION_REQUIRED, 'choose a database connection first')
        end

        current = descriptor
        unless id == current[:id]
          raise Protocol::Failure.new(Protocol::CONNECTION_REQUIRED,
                                      'the chosen database connection is not available for this model',
                                      { connection: current })
        end

        [workspace, current]
      end

      def descriptor # rubocop:disable Metrics/MethodLength
        info, error = status
        base = {
          id: "mxrb-workspace:#{project_id}:#{@database_port}", kind: 'mxrb_database_workspace',
          label: 'MXRB database workspace', engine: 'postgresql', environment: 'local',
          environment_label: 'Local Docker workspace (PostgreSQL 13)', host: '127.0.0.1',
          port: @database_port, database: Runtime::DatabaseWorkspace::DATABASE,
          user: Runtime::DatabaseWorkspace::READER, read_only: true, model: @path
        }
        return base.merge(running: false, schema_current: false, error:) if error

        base.merge(
          host: info.host, port: info.port, database: info.database, user: info.reader_user,
          running: info.running == true, model_fingerprint: info.model_fingerprint,
          active_fingerprint: info.active_fingerprint,
          # nil: no record of the schema this workspace last synchronized.
          schema_current: info.active_fingerprint && info.active_fingerprint == info.model_fingerprint
        )
      end

      private

      def workspace
        @workspace ||= Runtime::DatabaseWorkspace.new(@path, port: @database_port, runtime_port: @runtime_port)
      end

      def status
        [workspace.status, nil]
      rescue StandardError => e
        [nil, { code: 'connection_status_unavailable', message: e.message }]
      end

      def project_id = Digest::SHA256.hexdigest(@path)[0, 12]
    end
  end
end
