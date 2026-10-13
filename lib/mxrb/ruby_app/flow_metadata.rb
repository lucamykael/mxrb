# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Flow baselines belong to the exporting application's private sidecar.
    # Scope the lookup to source loading so application roots cannot leak
    # metadata into each other or into newly authored services.
    class FlowMetadata
      THREAD_KEY = :mxrb_ruby_app_flow_metadata

      def self.with(manifest)
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = new(manifest)
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      def self.for(unit_id, native_type)
        Thread.current[THREAD_KEY]&.fetch(unit_id, native_type)
      end

      def self.validate!(unit_id, native_type, builder)
        context = Thread.current[THREAD_KEY]
        return unless context&.registered?(unit_id, native_type)
        return unless builder.expected_body_fingerprint.to_s.empty?

        raise ValidationError, 'existing Ruby flow requires its semantic metadata baseline or a legacy body fingerprint'
      end

      def initialize(manifest)
        @entries = {}
        @registered = manifest.modules.flat_map do |mod|
          { 'services' => 'Microflows$Microflow', 'nanoflows' => 'Microflows$Nanoflow' }.flat_map do |key, native_type|
            Array(mod[key]).map { [_1.fetch('id').to_s, _1['kind'] == 'rule' ? 'Microflows$Rule' : native_type] }
          end
        end.to_set
        path = File.join(manifest.root, '.mxrb', 'semantic_metadata.json')
        unless File.file?(path)
          path = File.join(File.dirname(manifest.absolute_path('mendix_project')), '.mxrb', 'semantic_metadata.json')
        end
        return unless File.file?(path)

        modules = JSON.parse(File.read(path)).fetch('modules', {})
        modules.each_value do |mod|
          mod.fetch('flows', {}).each_value do |metadata|
            (metadata.is_a?(Array) ? metadata : [metadata]).each { index(_1) }
          end
        end
      rescue JSON::ParserError => e
        raise SerializationError, "invalid flow metadata sidecar #{path}: #{e.message}"
      end

      def fetch(unit_id, native_type) = @entries[[unit_id.to_s, native_type.to_s]]
      def registered?(unit_id, native_type) = @registered.include?([unit_id.to_s, native_type.to_s])

      private

      def index(metadata)
        key = [metadata.fetch('unit_id', '').to_s, metadata.fetch('native_type', '').to_s]
        return if key.any?(&:empty?)

        previous = @entries[key]
        raise ValidationError, 'conflicting flow metadata identities' if previous && previous != metadata

        @entries[key] = metadata
      end
    end
    # rubocop:enable Metrics
  end
end
