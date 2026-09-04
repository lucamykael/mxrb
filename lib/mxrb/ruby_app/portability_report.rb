# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Audits which Ruby-mode artifacts become editable Mendix documents and
    # which ones require MXRB's embedded Ruby/TypeScript runtime.
    class PortabilityReport
      Entry = Data.define(:id, :name, :kind, :path, :status, :reason) do
        def to_h = { id:, name:, kind:, path:, status:, reason: }
      end

      attr_reader :root, :entries

      def initialize(root, manifest: Manifest.load(root))
        @root = File.expand_path(root)
        @manifest = manifest
        @entries = build_entries.freeze
      end

      def native? = entries.none? { _1.status == 'runtime_only' }

      def summary
        entries.group_by(&:status).transform_values(&:size).tap do |counts|
          %w[native preserved_native runtime_only].each { counts[_1] ||= 0 }
        end
      end

      def to_h
        {
          root:, native: native?, summary:,
          contract: {
            native: 'materialized as an editable Mendix document',
            preserved_native: 'kept unchanged in the reversible Mendix sidecar',
            runtime_only: 'requires the MXRB Ruby/TypeScript runtime'
          },
          entries: entries.map(&:to_h)
        }
      end

      private

      def build_entries
        load_registry
        coverage_entries + frontend_application_entries
      ensure
        Registry.reset!
      end

      def load_registry
        Registry.reset!
        RubyApp.application_files(root).each { load _1, true }
      end

      def coverage_entries
        @manifest.coverage.map do |coverage|
          status, reason = portability_for(coverage)
          Entry.new(
            id: coverage.fetch('id', nil), name: coverage.fetch('name'), kind: coverage.fetch('kind'),
            path: coverage.fetch('ruby_path'), status:, reason:
          )
        end
      end

      def portability_for(coverage)
        kind = coverage.fetch('kind')
        return ['native', 'Ruby domain declarations synchronize into the Mendix domain model'] \
          if %w[model dto].include?(kind)

        implementation = registered_implementation(coverage)
        return ['native', "Ruby #{kind} declares a native Mendix projection"] \
          if implementation&.native_definition
        return ['native', 'Editable Ruby declaration rebuilds this Mendix document'] if bidirectional?(coverage)

        fallback_portability(coverage, kind)
      end

      def registered_implementation(coverage)
        unit_id = coverage['id'].to_s
        unit_id = nil if unit_id.empty?
        Registry.fetch(:service, coverage.fetch('name'), unit_id:) ||
          Registry.fetch(:page, coverage.fetch('name'), unit_id:)
      end

      def fallback_portability(coverage, kind)
        return ['preserved_native', 'Original Mendix document is retained byte-for-byte in the sidecar'] \
          if coverage.fetch('status') == 'preserved_native'

        ['runtime_only', "#{kind} has no Ruby native declaration and runs through MXRB"]
      end

      def bidirectional?(coverage)
        %w[executable_bidirectional mendix_dsl_bidirectional].include?(coverage.fetch('status'))
      end

      def frontend_application_entries
        roots = @manifest.data.dig('frontend', 'application_owned') || []
        files = roots.flat_map { Dir.glob(File.join(root, _1, '**', '*.{ts,tsx}')) }
        return [] if files.empty?

        [Entry.new(
          id: nil, name: 'React application sources', kind: 'typescript_frontend',
          path: roots.join(', '), status: 'runtime_only',
          reason: 'React routes and components are not native Mendix page documents'
        )]
      end
    end
  end
end
