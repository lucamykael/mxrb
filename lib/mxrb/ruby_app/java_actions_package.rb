# frozen_string_literal: true

require 'fileutils'

module Mxrb
  module RubyApp
    # Writes the opt-in sidecar for a project's own Java actions next to its
    # exported Ruby application: java-actions/ holds the image (the sidecar's
    # sources and Dockerfile), the project's javasource with the proxies Studio
    # Pro would generate, and its userlib jars; docker-compose.yml starts it.
    # The Ruby application uses it once MXRB_JAVA_ACTIONS_URL points at it.
    class JavaActionsPackage
      DIRECTORY = 'java-actions'
      SIDECAR = File.expand_path('../../../docker/java-actions', __dir__)
      COMPOSE = <<~YAML
        # The project's own Java actions, run for the Ruby application. Start it
        # with `docker compose up -d java-actions` and set, for the application,
        # MXRB_JAVA_ACTIONS_URL=tcp://127.0.0.1:7911 (and the same
        # MXRB_JAVA_ACTIONS_TOKEN on both sides to authenticate the calls).
        services:
          java-actions:
            build: java-actions
            environment:
              MXRB_JAVA_ACTIONS_TOKEN: ${MXRB_JAVA_ACTIONS_TOKEN:-}
            ports:
              - "127.0.0.1:${MXRB_JAVA_ACTIONS_PORT:-7911}:7911"
            restart: unless-stopped
      YAML

      Result = Data.define(:directory, :sources, :proxies, :libraries)

      def initialize(mpr_path, application)
        @mpr_path = File.expand_path(mpr_path)
        @project = File.dirname(@mpr_path)
        @application = File.expand_path(application)
      end

      def write!
        raise ArgumentError, "#{@application} is not a directory" unless File.directory?(@application)

        target = File.join(@application, DIRECTORY)
        write_image(target)
        sources = copy_sources(File.join(target, 'javasource'))
        proxies = generate_proxies(target)
        libraries = copy_libraries(File.join(target, 'userlib'))
        compose = File.join(@application, 'docker-compose.yml')
        File.write(compose, COMPOSE) unless File.exist?(compose)
        Result.new(directory: target, sources:, proxies:, libraries:)
      end

      private

      # The package is generated: it starts over from the sidecar's sources.
      def write_image(target)
        FileUtils.rm_rf(target)
        FileUtils.mkdir_p(target)
        FileUtils.cp(File.join(SIDECAR, 'Dockerfile'), target)
        FileUtils.cp_r(File.join(SIDECAR, 'src'), target)
      end

      # The proxies the sources use that the project does not version, as Studio
      # Pro generates them; the sidecar finds actions by name, so it needs no
      # registrar of them, which would leave every action out with one that fails.
      def generate_proxies(target)
        proxies = -> { Dir.glob(File.join(target, 'javasource', '**', 'proxies', '**', '*.java')).size }
        before = proxies.call
        Compiler::JavaProxyGenerator.new(@mpr_path, project_root: target).generate
        FileUtils.rm_f(File.join(target, 'javasource', 'system', 'UserActionsRegistrar.java'))
        proxies.call - before
      end

      # Java sources as UTF-8, which the sidecar compiles with; a source that is
      # not valid UTF-8 is read as ISO-8859-1, the other encoding projects use.
      def copy_sources(target)
        FileUtils.mkdir_p(target)
        sources = files(File.join(@project, 'javasource'), '.java')
        sources.each do |relative, path|
          destination = File.join(target, relative)
          FileUtils.mkdir_p(File.dirname(destination))
          File.write(destination, utf8(File.binread(path)))
        end
        sources.size
      end

      def utf8(contents)
        text = contents.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : contents.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
      end

      def copy_libraries(target)
        FileUtils.mkdir_p(target)
        libraries = files(File.join(@project, 'userlib'), '.jar')
        libraries.each do |relative, path|
          FileUtils.mkdir_p(File.dirname(File.join(target, relative)))
          FileUtils.cp(path, File.join(target, relative))
        end
        libraries.size
      end

      def files(root, extension)
        Dir.glob(File.join(root, '**', "*#{extension}")).select { File.file?(_1) }.sort.map do |path|
          [path.delete_prefix("#{root}/"), path]
        end
      end
    end
  end
end
