# frozen_string_literal: true

module Mxrb
  module Runtime
    # Executes natively compiled portable applications in a Runtime container.
    class DockerExecutor < Executor
      private

      def validate_environment!
        raise ToolchainError, "Mendix Runtime #{@plan.runtime_path} is unavailable" unless @plan.available?
        _, status = capture("docker", "version", "--format", "{{.Server.Version}}")
        raise ToolchainError, "Docker daemon is unavailable" unless status.success?
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
