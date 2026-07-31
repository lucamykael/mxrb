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
            debugger.password = ""
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

      def default_configuration
        <<~CONF
          runtime.params { DatabaseType = HSQLDB, DatabaseName = default }
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
          add_source(archive, File.join(@runtime, 'pad', 'etc', name), "etc/#{name}")
        end
        PortableConfiguration.new(@metadata).files.each do |path, content|
          add_string(archive, path, content)
        end
      end

      def add_start_scripts(archive)
        Dir.glob(File.join(@runtime, 'pad', 'bin', '*.hbs')).sort.each do |source|
          name = File.basename(source, '.hbs')
          content = render_template(File.binread(source))
          add_string(archive, "bin/#{name}", content, mode: name == 'start' ? 0o755 : 0o644)
        end
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
      REQUIRED_RUNTIME_FILES = %w[
        launcher/runtimelauncher.jar
        pad/bin/start.hbs
        pad/etc/example.conf
        pad/etc/variables.conf
      ].freeze

      def initialize(mpr_path, deployment: nil, mendix_home: nil)
        @mpr_path = File.expand_path(mpr_path)
        @project_root = File.dirname(@mpr_path)
        @deployment = File.expand_path(deployment || File.join(@project_root, 'deployment'))
        @mendix_home = mendix_home && File.expand_path(mendix_home)
      end

      def pack(output:, force: false)
        output_path = File.expand_path(output)
        validate_output!(output_path, force:)
        version = Mxrb.open(@mpr_path, &:mendix_version)
        adapter = Adapter.for(version)
        metadata = adapter.validate_deployment!(@deployment)
        adapter.validate_freshness!(@mpr_path, @deployment)
        runtime = runtime_root(version)
        validate_runtime!(runtime)
        PortableArchiveWriter.new(@deployment, runtime, metadata).write(output_path)
        result(output_path, version, metadata)
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
