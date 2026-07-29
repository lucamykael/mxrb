# frozen_string_literal: true

module Mxrb
  module Runtime
    Plan = Data.define(
      :mendix_version, :java_version, :toolchain_path,
      :mx_path, :mxbuild_path, :jdk_package, :jre_package,
      :builder_image, :runtime_image
    ) do
      def available?
        File.executable?(mx_path) && File.executable?(mxbuild_path)
      end
    end

    class Toolchain
      def initialize(project_path, mendix_home: nil)
        @project_path = File.expand_path(project_path)
        @mendix_home = mendix_home && File.expand_path(mendix_home)
      end

      def plan
        version, java = project_metadata
        root = toolchain_root(version)
        Plan.new(
          version, java, root,
          File.join(root, "modeler", "mx"),
          File.join(root, "modeler", "mxbuild"),
          "zulu#{java}-ca-jdk-headless",
          "zulu#{java}-ca-jre-headless",
          "mxrb/mendix-builder:java#{java}",
          "eclipse-temurin:#{java}-jre"
        )
      end

      private

      def project_metadata
        Mxrb.open(@project_path) do |project|
          [project.mendix_version, configured_java(project) || fallback_java(project.mendix_version)]
        end
      end

      def configured_java(project)
        project.all_units.each do |raw|
          doc = project.parse_bson(raw)
          next unless doc["$Type"] == "Settings$ProjectSettings"

          settings = IO::BsonCodec.parse_array(doc["Settings"])[:items]
          model = settings.find { _1["$Type"] == "Settings$ModelSettings" }
          value = model && model["JavaMajorVersion"].to_s
          return value if value&.match?(/\A\d+\z/)
        end
        nil
      end

      def fallback_java(version)
        major, minor, patch = version.to_s.split(".").map(&:to_i)
        return "7" if major <= 5
        return "8" if major <= 7
        return "11" if major == 8
        return "11" if major == 9 && ([minor, patch] <=> [18, 16]).negative?
        return "17" if major == 9
        return "21" if major >= 11 || (major == 10 && minor >= 21)
        return "17" if major == 10 && (minor > 6 || (minor == 6 && patch >= 7))

        "11"
      end

      def toolchain_root(version)
        candidates = [
          @mendix_home && File.join(@mendix_home, version),
          File.join(Dir.home, ".local", "share", "mendix", version)
        ].compact
        candidates.find { File.directory?(_1) } || candidates.first
      end
    end
  end
end
