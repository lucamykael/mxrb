# frozen_string_literal: true

require_relative 'node'

module Mxrb
  module Forms
    class IncompleteCoverageError < StandardError; end

    CoverageEntry = Data.define(:widget, :property, :phases, :evidence) do
      def covered?(phase) = phases.include?(phase.to_sym)
      def complete? = CoverageLedger::PHASES.all? { covered?(_1) }
    end

    CoverageReport = Data.define(:version, :entries) do
      def widget_count = entries.map { _1.widget.name }.uniq.size
      def property_count = entries.size
      def count(phase) = entries.count { _1.covered?(phase) }
      def missing(phase) = entries.reject { _1.covered?(phase) }.freeze
      def complete? = entries.all?(&:complete?)

      def assert_complete!
        return self if complete?

        summary = CoverageLedger::PHASES.map { "#{_1}=#{count(_1)}/#{property_count}" }.join(', ')
        raise IncompleteCoverageError, "Mendix #{version} Forms coverage is incomplete: #{summary}"
      end
    end

    # Property-by-property gate. A value reaches complete only after all six
    # independently evidenced phases pass; lossless binary preservation is not
    # a phase and therefore cannot inflate coverage.
    class CoverageLedger
      PHASES = %i[
        represented source_emitted storage_transcoded imported compiled round_tripped
        studio_validated
      ].freeze

      attr_reader :catalog

      def self.for_node(catalog = Catalog.for('11.12.1')) # rubocop:disable Metrics/MethodLength
        new(catalog).tap do |ledger|
          catalog.concrete_widgets.each do |widget|
            widget.all_properties.each do |property|
              next unless Node.representable?(property, catalog:)

              ledger.claim(
                widget.name, property.name, :represented,
                evidence: 'Mxrb::Forms::Node schema validation'
              )
            end
          end
        end
      end

      def self.for_source_emitter(catalog = Catalog.for('11.12.1'))
        for_node(catalog).tap do |ledger|
          catalog.concrete_widgets.each do |widget|
            widget.all_properties.each do |property|
              ledger.claim(
                widget.name, property.name, :source_emitted,
                evidence: 'Mxrb::Forms::SourceEmitter exhaustive property spec'
              )
            end
          end
        end
      end

      def self.for_mpr_codec(catalog = Catalog.for('11.12.1'))
        for_source_emitter(catalog).tap do |ledger|
          catalog.concrete_widgets.each do |widget|
            widget.all_properties.each do |property|
              ledger.claim(
                widget.name, property.name, :storage_transcoded,
                evidence: 'Mxrb::Forms::MprCodec exhaustive property spec'
              )
            end
          end
        end
      end

      def self.for_synthetic_round_trip(catalog = Catalog.for('11.12.1'))
        for_mpr_codec(catalog).tap do |ledger|
          catalog.concrete_widgets.each do |widget|
            widget.all_properties.each do |property|
              ledger.claim(
                widget.name, property.name, :round_tripped,
                evidence: '825-case core Forms synthetic round-trip spec'
              )
            end
          end
        end
      end

      def initialize(catalog = Catalog.for('11.12.1'))
        @catalog = catalog
        @claims = {}
      end

      def claim(widget, property, *phases, evidence:) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength
        widget = catalog.fetch_type(widget)
        raise ArgumentError, "#{widget.name} is not a concrete widget" unless widget.widget? && widget.concrete?

        property = widget.fetch_property(property)
        phases = phases.map(&:to_sym).uniq
        unknown = phases - PHASES
        raise ArgumentError, "unknown coverage phase(s): #{unknown.join(', ')}" unless unknown.empty?
        raise ArgumentError, 'coverage evidence cannot be empty' if evidence.to_s.strip.empty?

        key = [widget.name, property.name]
        previous = @claims[key]
        combined = ((previous&.phases || []) + phases).uniq.freeze
        descriptions = [previous&.evidence, evidence.to_s].compact.uniq.join('; ').freeze
        @claims[key] = CoverageEntry.new(widget, property, combined, descriptions)
        self
      end

      def report
        entries = catalog.concrete_widgets.flat_map do |widget|
          widget.all_properties.map do |property|
            @claims.fetch(
              [widget.name, property.name],
              CoverageEntry.new(widget, property, [].freeze, '')
            )
          end
        end.freeze
        CoverageReport.new(catalog.version, entries)
      end
    end
  end
end
