# frozen_string_literal: true

require 'open3'
require 'json'

module Mxrb
  module Runtime
    # Read-only query-plan connection to an explicitly configured SQL Server
    # deployment. Credentials are passed through SQLCMDPASSWORD, never argv.
    class SqlServerDatabase # rubocop:disable Metrics/ClassLength
      MUTATING_SQL = /\b(?:ALTER|CREATE|DELETE|DROP|EXEC(?:UTE)?|INSERT|INTO|MERGE|TRUNCATE|UPDATE)\b/i

      # rubocop:disable Metrics/ParameterLists
      def initialize(server:, database:, user:, password: ENV['MXRB_SQLSERVER_PASSWORD'],
                     sqlcmd: 'sqlcmd', runner: nil)
        @server = required(server, 'SQL Server host')
        @database = required(database, 'SQL Server database')
        @user = required(user, 'SQL Server user')
        @password = required(password, 'MXRB_SQLSERVER_PASSWORD')
        @sqlcmd = sqlcmd
        @runner = runner || method(:capture)
      end
      # rubocop:enable Metrics/ParameterLists

      def explain(sql, analyze: false)
        statement = read_only_statement(sql)
        mode = analyze ? 'STATISTICS XML' : 'SHOWPLAN_XML'
        output = run!("SET #{mode} ON; #{statement}; SET #{mode} OFF;")
        Oql::SqlServerPlanAnalyzer.new.analyze(extract_showplan(output))
      end

      def workload(limit: 20)
        maximum = Integer(limit)
        raise ArgumentError, 'workload limit must be between 1 and 1000' unless (1..1000).cover?(maximum)

        Oql::SqlServerWorkloadAnalyzer.new.analyze(
          query_rows: query_workload(maximum), table_rows: table_workload,
          index_rows: index_workload
        )
      end

      private

      def query_workload(limit) # rubocop:disable Metrics/MethodLength
        run_json(<<~SQL)
          SELECT TOP (#{limit})
            CONVERT(varchar(66), qs.query_hash, 1) AS query_hash,
            SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
              ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS query_text,
            qs.execution_count, qs.total_elapsed_time, qs.total_rows,
            qs.total_logical_reads, qs.total_physical_reads
          FROM sys.dm_exec_query_stats qs
          CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
          ORDER BY qs.total_elapsed_time DESC FOR JSON PATH
        SQL
      end

      def table_workload
        run_json(<<~SQL)
          SELECT CONCAT(OBJECT_SCHEMA_NAME(i.object_id), '.', OBJECT_NAME(i.object_id)) AS relation,
                 SUM(COALESCE(s.user_scans, 0)) AS user_scans,
                 SUM(COALESCE(s.user_seeks, 0)) AS user_seeks
          FROM sys.indexes i
          LEFT JOIN sys.dm_db_index_usage_stats s
            ON s.database_id = DB_ID() AND s.object_id = i.object_id AND s.index_id = i.index_id
          WHERE i.object_id > 0
          GROUP BY i.object_id FOR JSON PATH
        SQL
      end

      def index_workload # rubocop:disable Metrics/MethodLength
        run_json(<<~SQL)
          SELECT CONCAT(OBJECT_SCHEMA_NAME(i.object_id), '.', OBJECT_NAME(i.object_id)) AS relation,
                 i.name AS index_name, COALESCE(s.user_scans, 0) AS user_scans,
                 COALESCE(s.user_seeks, 0) AS user_seeks,
                 SUM(COALESCE(p.reserved_page_count, 0)) * 8192 AS index_bytes
          FROM sys.indexes i
          LEFT JOIN sys.dm_db_index_usage_stats s
            ON s.database_id = DB_ID() AND s.object_id = i.object_id AND s.index_id = i.index_id
          LEFT JOIN sys.dm_db_partition_stats p
            ON p.object_id = i.object_id AND p.index_id = i.index_id
          WHERE i.name IS NOT NULL
          GROUP BY i.object_id, i.name, s.user_scans, s.user_seeks FOR JSON PATH
        SQL
      end

      def run_json(sql)
        source = run!(sql).strip
        JSON.parse(source.empty? ? '[]' : source)
      rescue JSON::ParserError => e
        raise ToolchainError, "sqlcmd returned invalid workload JSON: #{e.message}"
      end

      def run!(sql)
        environment = { 'SQLCMDPASSWORD' => @password }
        command = [
          @sqlcmd, '-S', @server, '-d', @database, '-U', @user,
          '-C', '-b', '-h', '-1', '-W', '-y', '0', '-Q', sql
        ]
        output, error, status = @runner.call(environment, *command)
        raise ToolchainError, "sqlcmd failed:\n#{output}#{error}" unless status.success?

        output.to_s
      end

      def extract_showplan(output)
        start = output.index('<ShowPlanXML')
        finish = output.rindex('</ShowPlanXML>')
        raise ToolchainError, 'sqlcmd returned no SHOWPLAN XML' unless start && finish

        output[start..(finish + '</ShowPlanXML>'.length - 1)]
      end

      def read_only_statement(sql)
        source = sql.to_s
        raise ArgumentError, 'SQL contains a NUL byte' if source.include?("\0")

        statement = source.strip
        validate_read_only_statement!(statement)
        statement
      end

      def validate_read_only_statement!(statement)
        raise ArgumentError, 'SQL must not be empty' if statement.empty?
        unless statement.match?(/\A(?:SELECT|WITH)\b/i) && !statement.include?(';')
          raise ArgumentError, 'SQL Server plan analysis accepts one read-only SELECT or WITH statement'
        end
        return unless statement.match?(MUTATING_SQL)

        raise ArgumentError, 'SQL Server plan analysis rejects mutating keywords, including writable CTEs'
      end

      def required(value, label)
        text = value.to_s
        raise ArgumentError, "#{label} is required" if text.empty? || text.include?("\0")

        text
      end

      def capture(environment, *command)
        Open3.capture3(environment, *command)
      end
    end
  end
end
