# frozen_string_literal: true

require 'open3'

module Mxrb
  module Runtime
    # Read-only query-plan connection to an explicitly configured SQL Server
    # deployment. Credentials are passed through SQLCMDPASSWORD, never argv.
    class SqlServerDatabase
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

      private

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
