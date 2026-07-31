# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # Version-specific deployment contract. Compiler stages dispatch through
    # this object instead of scattering major-version checks through the code.
    class Adapter
      REQUIRED_FILES = %w[
        model/model.mdp
        model/metadata.json
        model/bundles/project.jar
        web/index.html
      ].freeze
      ROOTS = %w[model web native sass tmp].freeze

      attr_reader :version, :major

      def self.for(version)
        major = version.to_s.split('.').first.to_i
        klass = { 9 => V9, 10 => V10, 11 => V11 }[major]
        unless klass
          raise UnsupportedVersion,
                "native compilation supports Mendix 9.x through 11.x; got #{version}"
        end

        klass.new(version)
      end

      def initialize(version)
        @version = version.to_s
        @major = @version.split('.').first.to_i
      end

      def validate_deployment!(root)
        validate_required_files!(root)
        metadata = read_metadata(root)
        runtime_version = metadata.fetch('RuntimeVersion').to_s
        return metadata if compatible_runtime?(runtime_version)

        raise CompilationError,
              "deployment targets Mendix #{runtime_version}, but MPR targets #{version}"
      rescue JSON::ParserError, KeyError => e
        raise CompilationError, "invalid model/metadata.json: #{e.message}"
      end

      def validate_freshness!(mpr_path, root)
        compiled_model = File.join(root, 'model', 'model.mdp')
        return if File.mtime(compiled_model) >= File.mtime(mpr_path)

        raise CompilationError,
              "deployment is stale: #{compiled_model} is older than #{File.expand_path(mpr_path)}"
      end

      def validate_required_files!(root)
        missing = REQUIRED_FILES.reject { File.file?(File.join(root, _1)) }
        return if missing.empty?

        raise CompilationError, "deployment is not materialized; missing #{missing.join(', ')}"
      end

      def read_metadata(root)
        JSON.parse(File.read(File.join(root, 'model', 'metadata.json')))
      end

      def compatible_runtime?(runtime_version)
        target = version.split('.').first(3)
        actual = runtime_version.split('.').first(3)
        target == actual
      end

      class V9 < Adapter; end
      class V10 < Adapter; end
      class V11 < Adapter; end
    end
  end
end
