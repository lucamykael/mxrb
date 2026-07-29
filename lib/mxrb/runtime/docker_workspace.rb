# frozen_string_literal: true

module Mxrb
  module Runtime
    # Produces argv-safe Docker commands. The source project is always mounted
    # read-only; mutations, deployment and the test database live in /workspace.
    class DockerWorkspace
      attr_reader :project_path, :plan

      def initialize(project_path, plan, workspace_size: "8g")
        @project_path = File.expand_path(project_path)
        @plan = plan
        @workspace_size = workspace_size.to_s
      end

      def builder_command(test_definition, package_volume: "mxrb-functional-package")
        File.expand_path(test_definition)
        [
          "docker", "run", "--rm",
          "--mount", bind_mount(File.dirname(@project_path), "/input", readonly: true),
          "--mount", bind_mount(@plan.toolchain_path, "/opt/mendix", readonly: true),
          "--mount", "type=volume,source=#{cache_name},target=/cache",
          "--mount", "type=volume,source=#{package_volume},target=/output",
          "--tmpfs", "/workspace:exec,size=#{@workspace_size}",
          @plan.builder_image,
          File.basename(@project_path)
        ]
      end

      def runtime_command(package_volume:, http_port: 8080, admin_port: 8090)
        [
          "docker", "run", "--rm",
          "--mount", "type=volume,source=#{package_volume},target=/mendix",
          "--tmpfs", "/mendix/data:exec,size=2g",
          "-p", "#{Integer(http_port)}:8080",
          "-p", "#{Integer(admin_port)}:8090",
          "-e", "M2EE_ADMIN_PASS=mxrb-functional-test",
          @plan.runtime_image,
          "./bin/start", "etc/Default"
        ]
      end

      private

      def bind_mount(source, target, readonly:)
        options = ["type=bind", "source=#{source}", "target=#{target}"]
        options << "readonly" if readonly
        options.join(",")
      end

      def cache_name
        "mxrb-mendix-#{@plan.mendix_version.tr('.', '-')}-cache"
      end
    end
  end
end
