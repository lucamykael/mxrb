# frozen_string_literal: true

require 'digest'
require 'csv'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'

module Mxrb
  module Runtime
    DatabaseInfo = Data.define(
      :project_id, :state_dir, :database_container, :runtime_container,
      :host, :port, :database, :reader_user, :running, :model_fingerprint,
      :runtime_url, :active_fingerprint, :disposition
    )
    AdminCredentials = Data.define(:username, :password, :state_dir, :path)

    # Materializes a private PostgreSQL database for one MPR. The Mendix Runtime
    # owns schema synchronization; analyst access uses a separate read-only role.
    # rubocop:disable Metrics/ClassLength
    class DatabaseWorkspace
      POSTGRES_IMAGE = 'postgres:13-alpine'
      DATABASE = 'mxrb'
      OWNER = 'mxrb_runtime'
      READER = 'mxrb_reader'
      NATIVE_INPUT_DIRECTORIES = %w[
        mprcontents deployment javasource javascriptsource userlib vendorlib
        resources widgets theme theme-cache themesource
      ].freeze

      def initialize(project_path, state_dir: nil, port: 55_432, runtime_port: 18_080, # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists
                     runner: nil, sleeper: nil)
        @project_path = File.expand_path(project_path)
        @project_id = Digest::SHA256.hexdigest(@project_path)[0, 12]
        @state_dir = File.expand_path(state_dir || default_state_dir)
        @port = Integer(port)
        @runtime_port = Integer(runtime_port)
        raise ArgumentError, 'database port must be between 1 and 65535' unless (1..65_535).cover?(@port)
        raise ArgumentError, 'runtime port must be between 1 and 65535' unless (1..65_535).cover?(@runtime_port)

        @runner = runner || method(:capture)
        @sleeper = sleeper || Kernel.method(:sleep)
        @plan = Toolchain.new(@project_path).plan
      end

      def up(force_build: false, reconcile: :prompt, input: $stdin, output: $stderr)
        validate!
        prepare_state
        with_workspace_lock do
          reconcile_up(force_build:, reconcile:, input:, output:)
        end
      end

      def sync(reconcile: :prompt, input: $stdin, output: $stderr) =
        up(force_build: true, reconcile:, input:, output:)

      def down
        prepare_lock_directory
        with_workspace_lock do
          stop_container(runtime_container)
          stop_container(database_container)
          info(running: false, disposition: :stopped)
        end
      end

      def destroy(confirm: false) # rubocop:disable Metrics/MethodLength
        raise ArgumentError, 'destroy requires explicit confirmation' unless confirm

        prepare_lock_directory
        result = nil
        with_workspace_lock do
          remove_container(runtime_container)
          remove_container(database_container)
          remove_owned_resource('volume', database_volume)
          remove_owned_resource('network', network_name)
          result = info(running: false, disposition: :destroyed)
        end
        FileUtils.rm_rf(@state_dir)
        result
      end

      def status
        info(running: container_running?(database_container) && container_running?(runtime_container))
      end

      # Keeping the transaction envelope next to role selection makes the
      # read-only default auditable.
      # rubocop:disable Metrics/MethodLength
      def query(sql, write: false)
        raise ArgumentError, 'SQL must not be empty' if sql.to_s.strip.empty?
        raise ArgumentError, 'SQL contains a NUL byte' if sql.include?("\0")

        configure_reader! unless write
        role = write ? OWNER : READER
        command = [
          'docker', 'exec', database_container,
          'psql', '--no-psqlrc', '--set', 'ON_ERROR_STOP=1',
          '--username', role, '--dbname', DATABASE
        ]
        command.concat(['--command', 'BEGIN READ ONLY']) unless write
        command.concat(['--command', sql])
        command.concat(['--command', 'COMMIT']) unless write
        run!(*command)
      end
      # rubocop:enable Metrics/MethodLength

      def query_rows(sql, params: {})
        statement = read_only_statement(sql)
        statement, variables = bind_parameters(statement, params)

        configure_reader!
        output = run!(*query_rows_command(statement, variables))
        CSV.parse(output, headers: true).map(&:to_h).freeze
      end

      # Uses PostgreSQL's machine-readable planner output. ANALYZE is opt-in
      # because it executes the SELECT, although the analyst role remains in a
      # read-only transaction and cannot mutate application data.
      def explain(sql, analyze: false)
        statement = read_only_statement(sql)
        configure_reader!
        payload = JSON.parse(run_explain(statement, analyze).strip)
        Oql::PlanAnalyzer.new(indexes: index_catalog).analyze(payload, analyzed: analyze)
      rescue JSON::ParserError => e
        raise ToolchainError, "PostgreSQL returned invalid EXPLAIN JSON: #{e.message}"
      end

      def workload(limit: 20)
        maximum = Integer(limit)
        raise ArgumentError, 'workload limit must be between 1 and 1000' unless (1..1000).cover?(maximum)

        Oql::WorkloadAnalyzer.new.analyze(
          query_rows: workload_queries(maximum),
          table_rows: workload_tables,
          index_rows: workload_indexes
        )
      end

      def index_advice(limit: 50)
        Oql::IndexAdvisor.new.analyze(workload(limit:))
      end

      def shell_command(write: false)
        role = write ? OWNER : READER
        [
          'docker', 'exec', '-it', database_container,
          'psql', '--no-psqlrc', '--username', role, '--dbname', DATABASE
        ].freeze
      end

      def connection_url
        secret = credentials.fetch('reader_password')
        "postgresql://#{READER}:#{secret}@127.0.0.1:#{@port}/#{DATABASE}"
      end

      def admin_credentials
        unless File.file?(credentials_path)
          raise ToolchainError,
                "Runtime credentials not found; run `mxrb db up #{@project_path}` first"
        end

        values = JSON.parse(File.read(credentials_path))
        password = values.fetch('admin_password')
        AdminCredentials.new(admin_user_name, password, @state_dir, credentials_path)
      rescue JSON::ParserError, KeyError => e
        raise ToolchainError, "invalid Runtime credentials file #{credentials_path}: #{e.message}"
      end

      private

      def admin_user_name
        mpr = IO::MprFile.open(@project_path, readonly: true)
        begin
          security = mpr.all_units.lazy.map { mpr.parse_contents(_1) }
                        .find { _1['$Type'] == 'Security$ProjectSecurity' }
          name = security.to_h.fetch('AdminUserName', '').to_s
          raise ToolchainError, 'MPR has no configured administrator user' if name.empty?

          name
        ensure
          mpr.close
        end
      end

      def bind_parameters(statement, params)
        values = params.to_h.transform_keys(&:to_s)
        return [statement, []] if values.empty?

        validate_parameter_names!(values, statement)
        bound = statement.gsub(/(?<!:):([A-Za-z][A-Za-z0-9_]*)/) do
          name = Regexp.last_match(1)
          values[name].nil? ? 'NULL' : ":'mxrb_#{name}'"
        end
        [bound, parameter_arguments(values)]
      end

      def validate_parameter_names!(values, statement)
        invalid = values.keys.reject { _1.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/) }
        expected = statement.scan(/(?<!:):([A-Za-z][A-Za-z0-9_]*)/).flatten.uniq
        parameter_error!('invalid parameter names', invalid)
        parameter_error!('missing query parameter', expected - values.keys)
        parameter_error!('unused query parameters', values.keys - expected)
      end

      def parameter_error!(label, names)
        raise ArgumentError, "#{label}: #{names.join(', ')}" unless names.empty?
      end

      def parameter_arguments(values)
        values.reject { |_name, value| value.nil? }.flat_map do |name, value|
          raise ArgumentError, "unsupported parameter value for #{name}" unless parameter_scalar?(value)

          ['--set', "mxrb_#{name}=#{value}"]
        end
      end

      def parameter_scalar?(value)
        value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end

      def query_rows_command(statement, variables)
        [
          'docker', 'exec', database_container,
          'psql', '--no-psqlrc', '--set', 'ON_ERROR_STOP=1', *variables,
          '--username', READER, '--dbname', DATABASE,
          '--csv', '--quiet', '--command', "COPY (#{statement}) TO STDOUT WITH CSV HEADER"
        ]
      end

      def prepare_database!
        ensure_network!
        ensure_database!
        configure_monitoring!
      end

      def run_explain(statement, analyze)
        run!(
          'docker', 'exec', database_container,
          'psql', '--no-psqlrc', '--set', 'ON_ERROR_STOP=1',
          '--username', READER, '--dbname', DATABASE, '--tuples-only', '--no-align', '--quiet',
          '--command', explain_sql(statement, analyze)
        )
      end

      def read_only_statement(sql)
        source = sql.to_s
        raise ArgumentError, 'SQL contains a NUL byte' if source.include?("\0")

        statement = source.strip
        raise ArgumentError, 'SQL must not be empty' if statement.empty?
        unless statement.match?(/\A(?:SELECT|WITH)\b/i) && !statement.include?(';')
          raise ArgumentError, 'online queries must be one read-only SELECT or WITH statement'
        end

        statement
      end

      def explain_sql(statement, analyze)
        options = ['FORMAT JSON', 'COSTS TRUE', 'VERBOSE TRUE', 'SETTINGS TRUE']
        options.concat(['ANALYZE TRUE', 'BUFFERS TRUE', 'TIMING TRUE']) if analyze
        "EXPLAIN (#{options.join(', ')}) #{statement}"
      end

      def index_catalog
        query_rows(<<~SQL)
          SELECT schemaname, tablename, indexname, indexdef
          FROM pg_indexes
          WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
          ORDER BY schemaname, tablename, indexname
        SQL
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength,
      # rubocop:disable Metrics/PerceivedComplexity
      def reconcile_up(force_build:, reconcile:, input:, output:)
        rebuild = force_build || stale_runtime?
        if rebuild && container_running?(runtime_container)
          decision = reconciliation_decision(reconcile, input:, output:)
          if decision == :keep_current
            return info(
              running: true, active_fingerprint: stored_runtime_fingerprint,
              disposition: :kept_current
            )
          end
        end

        candidate = build_runtime_candidate! if rebuild
        prepare_database!
        disposition = if rebuild
                        deploy_runtime_candidate!(candidate)
                        :recreated
                      else
                        ensure_runtime_started!
                      end
        configure_reader!
        cleanup_owned_obsolete_resources! if rebuild
        info(running: true, active_fingerprint: runtime_fingerprint, disposition:)
      ensure
        FileUtils.rm_rf(candidate) if defined?(candidate) && candidate && File.exist?(candidate)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength,
      # rubocop:enable Metrics/PerceivedComplexity

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      def reconciliation_decision(policy, input:, output:)
        choice = policy.to_sym
        return :recreate if choice == :recreate
        return :keep_current if choice == :keep_current
        raise ArgumentError, 'reconcile must be prompt, recreate, or keep_current' unless choice == :prompt

        unless input.respond_to?(:tty?) && input.tty?
          raise ToolchainError,
                'a previous Docker version is running; use --recreate or --keep-current'
        end

        output.puts '[mxrb] A running Docker runtime is older than the current project.'
        output.puts "[mxrb] Active fingerprint : #{stored_runtime_fingerprint || '(unknown)'}"
        output.puts "[mxrb] Current fingerprint: #{runtime_fingerprint}"
        output.print '[mxrb] Stop the active runtime and recreate it? [y/N] '
        answer = input.gets.to_s.strip.downcase
        %w[y yes s sim].include?(answer) ? :recreate : :keep_current
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

      def validate!
        raise ArgumentError, "#{@project_path}: file not found" unless File.file?(@project_path)
        raise ToolchainError, "Mendix Runtime #{@plan.runtime_path} is unavailable" unless @plan.available?

        run!('docker', 'version', '--format', '{{.Server.Version}}')
      end

      def prepare_state
        FileUtils.mkdir_p(@state_dir)
        File.chmod(0o700, @state_dir)
        credentials
      end

      def prepare_lock_directory
        FileUtils.mkdir_p(@state_dir)
        File.chmod(0o700, @state_dir)
      end

      def with_workspace_lock
        File.open(workspace_lock, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          begin
            lock.flock(File::LOCK_UN)
          rescue StandardError
            nil
          end
        end
      end

      def credentials
        @credentials ||= if File.file?(credentials_path)
                           JSON.parse(File.read(credentials_path))
                         else
                           create_credentials
                         end
      end

      def create_credentials
        values = {
          'owner_password' => SecureRandom.hex(24),
          'reader_password' => SecureRandom.hex(24),
          'admin_password' => SecureRandom.hex(24)
        }
        FileUtils.mkdir_p(@state_dir)
        File.write(credentials_path, JSON.pretty_generate(values))
        File.chmod(0o600, credentials_path)
        values
      end

      def stale_runtime?
        !File.directory?(runtime_dir) || !File.file?(runtime_marker) ||
          stored_runtime_fingerprint != runtime_fingerprint
      rescue JSON::ParserError, KeyError
        true
      end

      def stored_runtime_fingerprint
        return unless File.file?(runtime_marker)

        JSON.parse(File.read(runtime_marker)).fetch('fingerprint')
      rescue JSON::ParserError, KeyError
        nil
      end

      def build_runtime_candidate! # rubocop:disable Metrics/MethodLength
        FileUtils.mkdir_p(build_dir)
        package = File.join(build_dir, 'runtime.zip')
        FileUtils.rm_f(package)
        build_native_package(package)
        candidate = File.join(
          @state_dir, "runtime.next-#{Process.pid}-#{SecureRandom.hex(6)}"
        )
        FileUtils.mkdir_p(candidate)
        # The package is always authoritative for this generated directory.
        # Some unzip builds can still observe files created by a just-removed
        # bind-mounted Runtime and prompt on stdin unless overwrite is explicit.
        run!('unzip', '-oq', package, '-d', candidate)
        candidate
      rescue StandardError
        FileUtils.rm_rf(candidate) if defined?(candidate) && candidate
        raise
      end

      def build_native_package(output)
        Dir.mktmpdir('mxrb-db-build-', build_dir) do |root|
          project = copy_native_input(root)
          deployment = File.join(File.dirname(project), 'deployment')
          compile_native(project, deployment, output)
        end
      rescue CompilationError => e
        raise ToolchainError, "MXRB native database build failed: #{e.message}"
      end

      def compile_native(project, deployment, output)
        Compiler::DeploymentMaterializer.new(
          project, deployment:, mendix_home: @plan.toolchain_path
        ).materialize
        Compiler::ProjectJarBuilder.new(
          project, deployment:, mendix_home: @plan.toolchain_path
        ).build
        compile_web(project, deployment)
        Compiler::PortablePackager.new(
          project, deployment:, mendix_home: @plan.toolchain_path
        ).pack(output:, force: true)
      end

      def compile_web(project, deployment)
        Compiler::WebBundleBuilder.new(
          project, deployment:, mendix_home: @plan.toolchain_path
        ).build
      end

      def copy_native_input(root)
        destination = File.join(root, 'project')
        FileUtils.mkdir_p(destination)
        FileUtils.cp(@project_path, destination)
        project_root = File.dirname(@project_path)
        copy_native_directories(project_root, destination)
        File.join(destination, File.basename(@project_path))
      end

      def copy_native_directories(project_root, destination)
        NATIVE_INPUT_DIRECTORIES.each do |name|
          source = File.join(project_root, name)
          next unless File.directory?(source)
          if Dir.glob(File.join(source, '**', '*'), File::FNM_DOTMATCH).any? { File.symlink?(_1) }
            raise ToolchainError, "native database input contains a symlink: #{source}"
          end

          FileUtils.cp_r(source, destination)
        end
      end

      def ensure_network!
        if successful?('docker', 'network', 'inspect', network_name)
          assert_owned_resource!('network', network_name)
          return
        end

        run!(
          'docker', 'network', 'create', '--label', ownership_label,
          '--label', 'mxrb.resource=network', network_name
        )
      end

      def ensure_database!
        if container_exists?(database_container)
          assert_owned_container!(database_container)
          run!('docker', 'start', database_container) unless container_running?(database_container)
        else
          create_database_container!
        end
        wait_for_database!
        ensure_application_database!
      end

      def ensure_application_database!
        exists = run!(
          'docker', 'exec', database_container, 'psql', '--no-psqlrc', '--tuples-only',
          '--no-align', '--username', OWNER, '--dbname', 'postgres', '--command',
          "SELECT 1 FROM pg_database WHERE datname = '#{DATABASE}'"
        ).strip == '1'
        return if exists

        create_application_database!
      end

      def create_application_database!
        command = ['docker', 'exec', database_container, 'createdb', '--username', OWNER, DATABASE]
        output, status = run_command(*command)
        return if status.success? || output.include?('already exists')

        raise ToolchainError, "docker failed:\n#{output}"
      end

      def create_database_container! # rubocop:disable Metrics/MethodLength
        ensure_database_volume!
        run!(
          'docker', 'run', '-d', '--name', database_container,
          '--label', ownership_label, '--label', 'mxrb.resource=database',
          '--network', network_name,
          '--mount', "type=volume,source=#{database_volume},target=/var/lib/postgresql/data",
          '-p', "127.0.0.1:#{@port}:5432",
          '-e', "POSTGRES_DB=#{DATABASE}", '-e', "POSTGRES_USER=#{OWNER}",
          '-e', "POSTGRES_PASSWORD=#{credentials.fetch('owner_password')}",
          POSTGRES_IMAGE, 'postgres',
          '-c', 'shared_preload_libraries=pg_stat_statements',
          '-c', 'track_io_timing=on'
        )
      end

      def ensure_database_volume!
        if successful?('docker', 'volume', 'inspect', database_volume)
          assert_owned_resource!('volume', database_volume)
        else
          run!(
            'docker', 'volume', 'create', '--label', ownership_label,
            '--label', 'mxrb.resource=data', '--label', 'mxrb.persistent=true',
            database_volume
          )
        end
      end

      def wait_for_database! # rubocop:disable Metrics/MethodLength
        consecutive_ready = 0
        30.times do
          ready = successful?(
            'docker', 'exec', database_container,
            'pg_isready', '--username', OWNER, '--dbname', DATABASE
          )
          consecutive_ready = ready ? consecutive_ready + 1 : 0
          return if consecutive_ready >= 2

          @sleeper.call(1)
        end
        raise ToolchainError, 'PostgreSQL did not become ready'
      end

      def configure_monitoring!
        ensure_statistics_preload!
        ensure_io_timing!
        database_owner_sql('CREATE EXTENSION IF NOT EXISTS pg_stat_statements')
      end

      def ensure_statistics_preload!
        libraries = database_scalar('SHOW shared_preload_libraries').split(',').map(&:strip)
        return if libraries.include?('pg_stat_statements')

        value = (libraries.reject(&:empty?) + ['pg_stat_statements']).join(',')
        database_owner_sql("ALTER SYSTEM SET shared_preload_libraries = '#{value}'")
        run!('docker', 'restart', database_container)
        wait_for_database!
      end

      def ensure_io_timing!
        return if database_scalar('SHOW track_io_timing') == 'on'

        database_owner_sql('ALTER SYSTEM SET track_io_timing = on')
        database_owner_sql('SELECT pg_reload_conf()')
      end

      def database_scalar(sql)
        run!(
          'docker', 'exec', database_container, 'psql', '--no-psqlrc', '--tuples-only',
          '--no-align', '--username', OWNER, '--dbname', DATABASE, '--command', sql
        ).strip
      end

      def database_owner_sql(sql)
        run!(
          'docker', 'exec', database_container, 'psql', '--no-psqlrc',
          '--set', 'ON_ERROR_STOP=1', '--username', OWNER, '--dbname', DATABASE,
          '--command', sql
        )
      end

      def workload_queries(limit) # rubocop:disable Metrics/MethodLength
        query_rows(<<~SQL)
          SELECT queryid::text, calls, total_exec_time, mean_exec_time, rows,
                 shared_blks_hit, shared_blks_read, temp_blks_written,
                 blk_read_time, blk_write_time, query
          FROM pg_stat_statements
          WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
            AND query NOT ILIKE '%pg_stat_statements%'
            AND query ~* '^[[:space:]]*(SELECT|WITH)([[:space:]]|$)'
          ORDER BY total_exec_time DESC
          LIMIT #{limit}
        SQL
      end

      def workload_tables
        query_rows(<<~SQL)
          SELECT schemaname, relname, seq_scan, seq_tup_read, idx_scan, n_live_tup,
                 last_analyze, last_autoanalyze
          FROM pg_stat_user_tables
          ORDER BY seq_tup_read DESC
        SQL
      end

      def workload_indexes
        query_rows(<<~SQL)
          SELECT s.schemaname, s.relname, s.indexrelname, s.idx_scan,
                 s.idx_tup_read, s.idx_tup_fetch, pg_relation_size(s.indexrelid) AS index_bytes,
                 i.indisunique, i.indisprimary, pg_get_indexdef(s.indexrelid) AS indexdef
          FROM pg_stat_user_indexes s
          JOIN pg_index i ON i.indexrelid = s.indexrelid
          ORDER BY index_bytes DESC
        SQL
      end

      def wait_for_runtime!
        120.times do
          output, status = run_command('docker', 'logs', runtime_container)
          return if status.success? && output.include?('Mendix Runtime successfully started')
          raise ToolchainError, "Mendix Runtime stopped during synchronization:\n#{output}" \
            unless container_running?(runtime_container)

          @sleeper.call(1)
        end
        raise ToolchainError, 'Mendix Runtime schema synchronization timed out'
      end

      # The grants form one atomic security policy and intentionally stay together.
      # rubocop:disable Metrics/MethodLength
      def configure_reader!
        return if @reader_configured

        password = credentials.fetch('reader_password')
        sql = <<~SQL
          BEGIN;
          SELECT pg_advisory_xact_lock(hashtext('mxrb.configure_reader'));
          DO $mxrb$ BEGIN
            CREATE ROLE #{READER} LOGIN PASSWORD '#{password}';
          EXCEPTION WHEN duplicate_object THEN
            ALTER ROLE #{READER} LOGIN PASSWORD '#{password}';
          END $mxrb$;
          ALTER ROLE #{READER} SET default_transaction_read_only = on;
          GRANT CONNECT ON DATABASE #{DATABASE} TO #{READER};
          GRANT USAGE ON SCHEMA public TO #{READER};
          GRANT SELECT ON ALL TABLES IN SCHEMA public TO #{READER};
          GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO #{READER};
          GRANT pg_read_all_stats TO #{READER};
          ALTER DEFAULT PRIVILEGES FOR ROLE #{OWNER} IN SCHEMA public
            GRANT SELECT ON TABLES TO #{READER};
          ALTER DEFAULT PRIVILEGES FOR ROLE #{OWNER} IN SCHEMA public
            GRANT SELECT ON SEQUENCES TO #{READER};
          COMMIT;
        SQL
        run!(
          'docker', 'exec', database_container,
          'psql', '--no-psqlrc', '--set', 'ON_ERROR_STOP=1',
          '--username', OWNER, '--dbname', DATABASE, '--command', sql
        )
        @reader_configured = true
      end
      # rubocop:enable Metrics/MethodLength

      # Runtime database settings stay adjacent so no credential or safety
      # override can be omitted from one execution path.
      # rubocop:disable Metrics/MethodLength
      def restart_runtime!(fingerprint: runtime_fingerprint)
        remove_container(runtime_container)
        secret = credentials
        run!(
          'docker', 'run', '-d', '--name', runtime_container,
          '--label', ownership_label, '--label', 'mxrb.resource=runtime',
          '--label', "mxrb.fingerprint=#{fingerprint}", '--network', network_name,
          '--publish', "127.0.0.1:#{@runtime_port}:8080",
          '--mount', bind_mount(runtime_dir, '/mendix', readonly: false),
          '-e', 'HOME=/tmp', '-e', "M2EE_ADMIN_PASS=#{secret.fetch('admin_password')}",
          '-e', "RUNTIME_ADMINUSER_PASSWORD=#{secret.fetch('admin_password')}",
          '-e', 'RUNTIME_PARAMS_DATABASETYPE=POSTGRESQL',
          '-e', "RUNTIME_PARAMS_DATABASEHOST=#{database_container}:5432",
          '-e', "RUNTIME_PARAMS_DATABASEJDBCURL=jdbc:postgresql://#{database_container}:5432/#{DATABASE}",
          '-e', "RUNTIME_PARAMS_DATABASENAME=#{DATABASE}",
          '-e', "RUNTIME_PARAMS_DATABASEUSERNAME=#{OWNER}",
          '-e', "RUNTIME_PARAMS_DATABASEPASSWORD=#{secret.fetch('owner_password')}",
          '-e', 'RUNTIME_PARAMS_DATABASEUSESSL=false',
          '-w', '/mendix', @plan.runtime_image, './bin/start', 'etc/Default'
        )
      end
      # rubocop:enable Metrics/MethodLength

      def ensure_runtime_started!
        if container_exists?(runtime_container)
          assert_owned_container!(runtime_container)
          return :reused if container_running?(runtime_container)

          run!('docker', 'start', runtime_container)
        else
          restart_runtime!
        end
        wait_for_runtime!
        :started
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def deploy_runtime_candidate!(candidate)
        backup = File.join(@state_dir, "runtime.previous-#{Process.pid}")
        previous_marker = File.file?(runtime_marker) ? File.binread(runtime_marker) : nil
        remove_container(runtime_container)
        FileUtils.rm_rf(backup)
        FileUtils.mv(runtime_dir, backup) if File.directory?(runtime_dir)
        FileUtils.mv(candidate, runtime_dir)
        write_runtime_marker
        restart_runtime!
        wait_for_runtime!
        FileUtils.rm_rf(backup)
      rescue StandardError => e
        rollback_runtime!(backup, previous_marker)
        raise ToolchainError, "new Docker runtime failed; previous version restored: #{e.message}"
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def rollback_runtime!(backup, previous_marker) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        remove_container(runtime_container)
        FileUtils.rm_rf(runtime_dir)
        FileUtils.mv(backup, runtime_dir) if File.directory?(backup)
        if previous_marker
          File.binwrite(runtime_marker, previous_marker)
        else
          FileUtils.rm_f(runtime_marker)
        end
        return unless File.directory?(runtime_dir)

        previous_fingerprint = JSON.parse(previous_marker).fetch('fingerprint') if previous_marker
        restart_runtime!(fingerprint: previous_fingerprint || 'unknown')
        wait_for_runtime!
      rescue StandardError => e
        raise ToolchainError, "Docker rollback failed: #{e.message}"
      end

      def write_runtime_marker
        temporary = "#{runtime_marker}.#{Process.pid}.tmp"
        payload = {
          'fingerprint' => runtime_fingerprint,
          'runtime_image' => @plan.runtime_image,
          'postgres_image' => POSTGRES_IMAGE
        }
        File.write(temporary, JSON.generate(payload))
        File.rename(temporary, runtime_marker)
      ensure
        FileUtils.rm_f(temporary.to_s)
      end

      def cleanup_owned_obsolete_resources!
        cleanup_owned_containers!
        cleanup_owned_networks!
        cleanup_owned_ephemeral_volumes!
        cleanup_owned_dangling_images!
      end

      def cleanup_owned_containers!
        listed_resources('container', 'ls', '-a').each do |name|
          next if [database_container, runtime_container].include?(name)
          next if container_running?(name)

          remove_container(name)
        end
      end

      def cleanup_owned_networks!
        listed_resources('network', 'ls').each do |name|
          next if name == network_name

          remove_owned_resource('network', name)
        end
      end

      def cleanup_owned_ephemeral_volumes!
        listed_resources('volume', 'ls', '--filter', 'label=mxrb.ephemeral=true').each do |name|
          remove_owned_resource('volume', name)
        end
      end

      def cleanup_owned_dangling_images!
        listed_resources('image', 'ls', '--filter', 'dangling=true').each do |identifier|
          assert_owned_resource!('image', identifier)
          run!('docker', 'image', 'rm', identifier)
        end
      end

      def listed_resources(kind, action, *extra)
        format = case kind
                 when 'container' then '{{.Names}}'
                 when 'image' then '{{.ID}}'
                 else '{{.Name}}'
                 end
        output = run!(
          'docker', kind, action, '--filter', "label=#{ownership_label}", *extra,
          '--format', format
        )
        output.lines.map(&:strip).select { resource_identifier?(kind, _1) }.uniq
      end

      def resource_identifier?(kind, value)
        return value.start_with?("mxrb-#{@project_id}") unless kind == 'image'

        value.match?(/\A(?:sha256:)?[0-9a-f]{12,64}\z/i)
      end

      def stop_container(name)
        return unless container_running?(name)

        assert_owned_container!(name)
        run!('docker', 'stop', name)
      end

      def remove_container(name)
        return unless container_exists?(name)

        assert_owned_container!(name)
        run!('docker', 'rm', '-f', name)
      end

      def container_exists?(name)
        successful?('docker', 'container', 'inspect', name)
      end

      def container_running?(name)
        output, = run_command('docker', 'container', 'inspect', '--format', '{{.State.Running}}', name)
        output.strip == 'true'
      end

      def assert_owned_container!(name)
        assert_owned_resource!('container', name, '.Config.Labels')
      end

      def assert_owned_resource!(kind, name, labels_path = '.Labels')
        output = run!(
          'docker', kind, 'inspect', '--format',
          "{{ index #{labels_path} \"mxrb.project\" }}", name
        )
        return if output.strip == @project_id

        raise ToolchainError, "refusing to modify unowned Docker #{kind} #{name}"
      end

      def remove_owned_resource(kind, name)
        return unless successful?('docker', kind, 'inspect', name)

        assert_owned_resource!(kind, name)
        run!('docker', kind, 'rm', name)
      end

      def successful?(*command)
        _output, status = run_command(*command)
        status.success?
      end

      def run!(*command)
        output, status = run_command(*command)
        raise ToolchainError, "#{command.first} failed:\n#{output}" unless status.success?

        output
      end

      def run_command(*command)
        result = @runner.call(*command)
        return [result[0].to_s + result[1].to_s, result[2]] if result.length == 3

        [result[0].to_s, result[1]]
      end

      def capture(*command)
        Open3.capture3(*command)
      end

      def info(running:, active_fingerprint: stored_runtime_fingerprint,
               disposition: running ? :status : :stopped)
        DatabaseInfo.new(
          @project_id, @state_dir, database_container, runtime_container,
          '127.0.0.1', @port, DATABASE, READER, running, model_fingerprint,
          "http://127.0.0.1:#{@runtime_port}/", active_fingerprint, disposition
        )
      end

      def model_fingerprint
        runtime_fingerprint
      end

      def runtime_fingerprint # rubocop:disable Metrics/AbcSize
        @runtime_fingerprint ||= begin
          digest = Digest::SHA256.new
          digest << "mxrb-docker-workspace-v2\0"
          digest << @plan.runtime_image.to_s << "\0" << POSTGRES_IMAGE << "\0"
          digest << @port.to_s << "\0" << @runtime_port.to_s << "\0"
          fingerprint_input_files.each do |relative, path|
            digest << relative << "\0" << Digest::SHA256.file(path).hexdigest << "\0"
          end
          digest.hexdigest
        end
      end

      def fingerprint_input_files # rubocop:disable Metrics/MethodLength
        root = File.dirname(@project_path)
        files = [[File.basename(@project_path), @project_path]]
        NATIVE_INPUT_DIRECTORIES.each do |directory|
          base = File.join(root, directory)
          next unless File.directory?(base)

          Dir.glob(File.join(base, '**', '*'), File::FNM_DOTMATCH).sort.each do |path|
            next unless File.file?(path)

            relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
            files << [relative, path]
          end
        end
        files
      end

      def bind_mount(source, target, readonly:)
        values = ['type=bind', "source=#{source}", "target=#{target}"]
        values << 'readonly' if readonly
        values.join(',')
      end

      def default_state_dir
        root = ENV['XDG_STATE_HOME'] || File.join(Dir.home, '.local', 'state')
        File.join(root, 'mxrb', 'databases', @project_id)
      end

      def credentials_path = File.join(@state_dir, 'credentials.json')
      def runtime_marker = File.join(@state_dir, 'runtime.json')
      def workspace_lock = File.join(@state_dir, 'workspace.lock')
      def runtime_dir = File.join(@state_dir, 'runtime')
      def build_dir = File.join(@state_dir, 'build')
      def network_name = "mxrb-#{@project_id}"
      def database_container = "mxrb-#{@project_id}-postgres"
      def runtime_container = "mxrb-#{@project_id}-runtime"
      def database_volume = "mxrb-#{@project_id}-data"
      def ownership_label = "mxrb.project=#{@project_id}"
    end
    # rubocop:enable Metrics/ClassLength
  end
end
