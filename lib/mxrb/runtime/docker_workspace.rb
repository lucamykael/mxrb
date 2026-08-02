# frozen_string_literal: true

module Mxrb
  module Runtime
    # Produces the argv-safe command for a natively compiled Runtime package.
    class DockerWorkspace
      attr_reader :project_path, :plan

      def initialize(project_path, plan, workspace_size: "8g")
        @project_path = File.expand_path(project_path)
        @plan = plan
        @workspace_size = workspace_size.to_s
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
    end
  end
end
