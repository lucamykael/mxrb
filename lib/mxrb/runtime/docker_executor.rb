# frozen_string_literal: true

module Mxrb
  module Runtime
    # Executes official Mendix build and runtime processes in containers. Ruby
    # instrumentation still happens through the same disposable-copy pipeline.
    class DockerExecutor < Executor
      def initialize(...)
        super
        @docker_context = File.expand_path(
          "../../../docker/functional", __dir__
        )
      end

      private

      def validate_environment!
        raise ToolchainError, "Mendix toolchain #{@plan.toolchain_path} is unavailable" unless @plan.available?
        _, status = capture("docker", "version", "--format", "{{.Server.Version}}")
        raise ToolchainError, "Docker daemon is unavailable" unless status.success?

        ensure_builder_image
      end

      def ensure_builder_image
        _, status = capture("docker", "image", "inspect", @plan.builder_image)
        return if status.success?

        output, status = capture(
          "docker", "build",
          "--build-arg", "JAVA_VERSION=#{@plan.java_version}",
          "-f", File.join(@docker_context, "Dockerfile.builder"),
          "-t", @plan.builder_image,
          @docker_context
        )
        raise ToolchainError, "could not build #{@plan.builder_image}:\n#{output}" unless status.success?
      end

      # mx check is performed in the builder immediately before mxbuild.
      def check(_project, _root) = "performed in Docker builder"

      def build(project, root)
        output, status = capture(
          "docker", "run", "--rm",
          "--mount", bind_mount(File.dirname(project), "/input", readonly: true),
          "--mount", bind_mount(@plan.toolchain_path, "/opt/mendix", readonly: true),
          "--mount", bind_mount(root, "/output", readonly: false),
          "--tmpfs", "/workspace:exec,size=8g",
          @plan.builder_image,
          File.basename(project)
        )
        raise FunctionalTestError, "Docker mxbuild failed:\n#{output}" unless status.success?

        @last_build_output = output
        File.join(root, "runtime.zip")
      end

      def start_runtime(package, root)
        runtime = File.join(root, "runtime")
        FileUtils.mkdir_p(runtime)
        output, status = capture("unzip", "-q", package, "-d", runtime)
        raise FunctionalTestError, "could not unpack runtime:\n#{output}" unless status.success?

        command = [
          "docker", "run", "--rm", "--stop-timeout", "10",
          "--user", "#{Process.uid}:#{Process.gid}",
          "--mount", bind_mount(runtime, "/mendix", readonly: false),
          "-e", "M2EE_ADMIN_PASS=mxrb-functional-test",
          "-e", "HOME=/tmp",
          "-w", "/mendix",
          @plan.runtime_image,
          "./bin/start", "etc/Default"
        ]
        collect_runtime({}, command, root)
      end

      def bind_mount(source, target, readonly:)
        values = ["type=bind", "source=#{source}", "target=#{target}"]
        values << "readonly" if readonly
        values.join(",")
      end
    end
  end
end
