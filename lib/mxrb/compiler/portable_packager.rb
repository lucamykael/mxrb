# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require 'zip'

module Mxrb
  module Compiler
    PortableResult = Data.define(:path, :mendix_version, :files, :sha256, :metadata)

    # Renders the Runtime configuration files from deployment metadata.
    class PortableConfiguration
      def initialize(metadata)
        @metadata = metadata
      end

      def files
        {
          'etc/Default' => default_includes,
          'etc/StudioPro.conf' => studio,
          'etc/configurations/Default.conf' => default_configuration,
          'etc/constants/defaults.conf' => constants(variables: false),
          'etc/constants/variables.conf' => constants(variables: true)
        }
      end

      private

      def default_includes
        <<~CONF
          include file("etc/StudioPro.conf")
          include file("etc/constants/defaults.conf")
          include file("etc/configurations/Default.conf")
          include file("etc/variables.conf")
          include file("etc/constants/variables.conf")
        CONF
      end

      def studio
        events = Array(@metadata['ScheduledEvents']).filter_map { _1['Name'] }.join(',')
        execution = events.empty? ? 'NONE' : 'SPECIFIED'
        studio_document(events, execution)
      end

      def studio_document(events, execution)
        <<~CONF
          runtime {
            params {
              DTAPMode = D
              ScheduledEventExecution = "#{execution}"
              MyScheduledEvents = "#{hocon(events)}"
              CACertificates = ""
              ClientCertificates = ""
              ClientCertificatePasswords = ""
              HashAlgorithm = "BCRYPT:12"
            }
            adminUser.password = ""
          #{debugger_configuration}
          }
          logging = [
            {
              name = MySubscriber
              type = console
              autoSubscribe = INFO
              levels {}
            }
          ]
        CONF
      end

      def debugger_configuration
        @metadata['RuntimeVersion'].to_s.to_i >= 11 ? '    debugger.password = ""' : ''
      end

      def default_configuration
        <<~CONF
          runtime.params {
            DatabaseType = HSQLDB
            DatabaseName = default
            DatabaseJdbcUrl = "jdbc:hsqldb:file:app/data/database/default"
          }
          admin { adminPassword = "", port = 8090, addresses = [ localhost ] }
          runtime {
            http { port = 8080, addresses = [ "*" ] }
            params { ApplicationRootUrl = "http://localhost:8080/" }
          }
        CONF
      end

      def constants(variables:)
        lines = Array(@metadata['Constants']).filter_map do |constant|
          name = constant['Name'].to_s
          next if name.empty?

          value = variables ? variable(name) : %("#{hocon(constant['DefaultValue'])}")
          %(  "#{hocon(name)}" = #{value})
        end
        "runtime.params.MicroflowConstants {\n#{lines.join("\n")}\n}\n"
      end

      def variable(name)
        environment = name.upcase.gsub(/[^A-Z0-9]+/, '_')
        "${?CONSTANTS_#{environment}}"
      end

      def hocon(value)
        value.to_s.gsub('\\', '\\\\').gsub('"', '\\"').gsub("\n", '\\n').gsub("\r", '\\r')
      end
    end

    # Portable assets used by Runtime distributions that do not ship PAD.
    module PortableFallbackAssets
      START = <<~'SH'
        #!/bin/sh
        set -eu

        ROOT_PATH=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
        if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
          JAVA="$JAVA_HOME/bin/java"
        else
          JAVA=$(command -v java || true)
        fi
        if [ -z "$JAVA" ] || [ ! -x "$JAVA" ]; then
          echo "Cannot find java; set JAVA_HOME or add java to PATH." >&2
          exit 1
        fi

        if [ -z "${M2EE_ADMIN_PASS:-}" ]; then
          M2EE_ADMIN_PASS=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
          export M2EE_ADMIN_PASS
        fi
        RUNTIME_ADMINUSER_PASSWORD="${RUNTIME_ADMINUSER_PASSWORD:-$M2EE_ADMIN_PASS}"
        export RUNTIME_ADMINUSER_PASSWORD

        export MX_INSTALL_PATH="$ROOT_PATH/lib"
        CONFIG="${CONFIG:-$ROOT_PATH/etc/Default}"
        if [ "$#" -eq 0 ]; then
          set -- "$CONFIG"
        fi
        cd "$ROOT_PATH"
        exec "$JAVA" ${JAVA_OPTS:-} \
          -Dfile.encoding=UTF-8 \
          -Djava.io.tmpdir="${TMPDIR:-/tmp}" \
          -Djava.library.path="$MX_INSTALL_PATH/runtime/lib/x64;$ROOT_PATH/app/model/lib/userlib" \
          -jar "$MX_INSTALL_PATH/runtime/launcher/runtimelauncher.jar" \
          "$ROOT_PATH/app/." "$@"
      SH
      VARIABLES = <<~CONF
        admin {
          port = ${?ADMIN_PORT}
          addresses = ${?ADMIN_ADDRESSES}
          adminPassword = ${?M2EE_ADMIN_PASS}
        }
        runtime.http {
          port = ${?RUNTIME_HTTP_PORT}
          addresses = ${?RUNTIME_HTTP_ADDRESSES}
        }
        runtime.params {
          DatabaseHost = ${?RUNTIME_PARAMS_DATABASEHOST}
          DatabaseJdbcUrl = ${?RUNTIME_PARAMS_DATABASEJDBCURL}
          DatabaseName = ${?RUNTIME_PARAMS_DATABASENAME}
          DatabaseUserName = ${?RUNTIME_PARAMS_DATABASEUSERNAME}
          DatabasePassword = ${?RUNTIME_PARAMS_DATABASEPASSWORD}
          DatabaseType = ${?RUNTIME_PARAMS_DATABASETYPE}
          DatabaseUseSsl = ${?RUNTIME_PARAMS_DATABASEUSESSL}
          ApplicationRootUrl = ${?RUNTIME_PARAMS_APPLICATIONROOTURL}
        }
        runtime.adminUser.password = ${?RUNTIME_ADMINUSER_PASSWORD}
      CONF
      EXAMPLE = <<~CONF
        # Copy this file and pass its path to bin/start to override etc/Default.
        runtime.params { DatabaseType = HSQLDB, DatabaseName = default }
        admin { port = 8090, addresses = [ localhost ] }
        runtime.http { port = 8080, addresses = [ "*" ] }
      CONF
    end

    # Deterministic ZIP writer shared by portable package orchestration.
    class PortableArchiveWriter
      FIXED_TIME = Packager::FIXED_TIME
      APP_ROOTS = (Adapter::ROOTS + ['run']).freeze

      def initialize(deployment, runtime, metadata)
        @deployment = deployment
        @runtime = runtime
        @metadata = metadata
      end

      def write(output)
        FileUtils.mkdir_p(File.dirname(output))
        Dir.mktmpdir('mxrb-portable-', File.dirname(output)) do |tmpdir|
          temporary = File.join(tmpdir, 'runtime.zip')
          Zip::File.open(temporary, create: true) do |archive|
            add_tree(archive, @runtime, 'lib/runtime')
            add_application(archive)
            add_generated_files(archive)
          end
          FileUtils.mv(temporary, output, force: true)
        end
      end

      private

      def add_application(archive)
        APP_ROOTS.each do |root_name|
          source = File.join(@deployment, root_name)
          add_tree(archive, source, "app/#{root_name}") if File.exist?(source)
        end
        %w[data data/database data/files data/tmp log].each do |path|
          add_directory(archive, "app/#{path}/", 0o755)
        end
      end

      def add_generated_files(archive)
        add_start_scripts(archive)
        %w[example.conf variables.conf].each do |name|
          add_runtime_configuration(archive, name)
        end
        PortableConfiguration.new(@metadata).files.each do |path, content|
          add_string(archive, path, content)
        end
      end

      def add_start_scripts(archive)
        templates = Dir.glob(File.join(@runtime, 'pad', 'bin', '*.hbs')).sort
        return add_fallback_start(archive) if templates.empty?

        templates.each do |source|
          name = File.basename(source, '.hbs')
          content = render_template(File.binread(source))
          add_string(archive, "bin/#{name}", content, mode: name == 'start' ? 0o755 : 0o644)
        end
      end

      def add_fallback_start(archive)
        add_string(archive, 'bin/start', PortableFallbackAssets::START, mode: 0o755)
      end

      def add_runtime_configuration(archive, name)
        source = File.join(@runtime, 'pad', 'etc', name)
        return add_source(archive, source, "etc/#{name}") if File.file?(source)

        fallback = if name == 'variables.conf'
                     PortableFallbackAssets::VARIABLES
                   else
                     PortableFallbackAssets::EXAMPLE
                   end
        add_string(archive, "etc/#{name}", fallback)
      end

      def render_template(content)
        rendered = content.start_with?("\xEF\xBB\xBF".b) ? content.byteslice(3..) : content
        rendered.force_encoding(Encoding::UTF_8)
                .gsub(/\{\{!--.*?--\}\}\s*/m, '')
                .gsub('{{DefaultConfig}}', 'Default')
      end

      def add_tree(archive, source_root, destination_root)
        add_directory(archive, "#{destination_root}/", File.stat(source_root).mode & 0o777)
        tree_paths(source_root).each do |source|
          destination = "#{destination_root}/#{source.delete_prefix("#{source_root}/").tr('\\', '/')}"
          if File.directory?(source)
            add_directory(archive, "#{destination}/", 0o755)
          else
            add_source(archive, source, destination)
          end
        end
      end

      def tree_paths(root)
        Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).sort
           .reject { %w[. ..].include?(File.basename(_1)) }
      end

      def add_source(archive, source, destination)
        archive.add(zip_entry(destination, File.stat(source).mode & 0o777), source)
      end

      def add_string(archive, destination, content, mode: 0o644)
        archive.get_output_stream(zip_entry(destination, mode)) { _1.write(content) }
        archive.find_entry(destination).unix_perms = mode
      end

      def add_directory(archive, destination, mode)
        archive.mkdir(destination)
        entry = archive.find_entry(destination)
        entry.time = FIXED_TIME
        entry.unix_perms = mode
      end

      def zip_entry(destination, mode)
        Zip::Entry.new('', destination).tap do |entry|
          entry.time = FIXED_TIME
          entry.unix_perms = mode
        end
      end
    end

    # Creates an executable portable application from materialized app files
    # and an installed Mendix Runtime distribution. It never invokes mxbuild.
    class PortablePackager
      REQUIRED_RUNTIME_FILES = %w[launcher/runtimelauncher.jar].freeze

      def initialize(mpr_path, deployment: nil, mendix_home: nil)
        @mpr_path = File.expand_path(mpr_path)
        @project_root = File.dirname(@mpr_path)
        @deployment = File.expand_path(deployment || File.join(@project_root, 'deployment'))
        @mendix_home = mendix_home && File.expand_path(mendix_home)
      end

      def pack(output:, force: false) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        Progress.with("Packing portable Runtime for #{File.basename(@mpr_path)}") do |progress|
          output_path = File.expand_path(output)
          validate_output!(output_path, force:)
          progress.update(detail: 'validating deployment')
          version = Mxrb.open(@mpr_path, &:mendix_version)
          adapter = Adapter.for(version)
          metadata = adapter.validate_deployment!(@deployment)
          adapter.validate_freshness!(@mpr_path, @deployment)
          runtime = runtime_root(version)
          validate_runtime!(runtime)
          progress.update(detail: 'writing Runtime archive')
          PortableArchiveWriter.new(@deployment, runtime, metadata).write(output_path)
          progress.update(detail: 'calculating checksum')
          result(output_path, version, metadata)
        end
      end

      private

      def validate_output!(output, force:)
        raise CompilationError, "#{output}: file already exists" if File.exist?(output) && !force
        return if File.directory?(@deployment)

        raise CompilationError, "#{@deployment}: deployment directory not found"
      end

      def runtime_root(version)
        root = @mendix_home || File.join(Dir.home, '.local', 'share', 'mendix', version)
        root = File.join(root, 'runtime') unless File.basename(root) == 'runtime'
        File.expand_path(root)
      end

      def validate_runtime!(runtime)
        missing = REQUIRED_RUNTIME_FILES.reject { File.file?(File.join(runtime, _1)) }
        return if missing.empty?

        raise CompilationError, "Mendix Runtime is incomplete at #{runtime}; missing #{missing.join(', ')}"
      end

      def result(output, version, metadata)
        count = Zip::File.open(output) { _1.count { |entry| !entry.directory? } }
        PortableResult.new(
          path: output, mendix_version: version, files: count,
          sha256: Digest::SHA256.file(output).hexdigest, metadata:
        )
      end
    end
  end
end
