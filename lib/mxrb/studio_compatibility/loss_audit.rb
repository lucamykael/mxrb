# frozen_string_literal: true

require_relative '../studio_compatibility'

module Mxrb
  class StudioCompatibility
    LossFinding = Data.define(:unit_id, :path, :property, :reason, :classification, :value_type)

    # Read-only audit of the explicit removals in the exact Mendix 9.6 strategy.
    # An empty result does not establish target compatibility: type changes,
    # coercions and unsupported metamodel features are outside this audit.
    # All present fields are reported, including nil, false and empty values;
    # this audit makes no claim that their removal is semantically equivalent.
    class LossAudit
      TARGET_VERSION = '9.6.1.29396'
      PROPERTY_REASON = 'The target strategy removes this property; semantic equivalence is not established.'
      SETTING_REASON = 'The target strategy removes this entire settings part; no equivalent is established.'
      STRUCTURAL_PROPERTIES = %w[
        Settings Entities Attributes Indexes Values Widgets Items Object ObjectType
        Properties Parameters Arguments LayoutCall MicroflowSettings
      ].freeze

      attr_reader :target_version

      def initialize(target_version:)
        unless target_version.to_s == TARGET_VERSION
          raise ArgumentError, 'loss audit supports only the exact Mendix 9.6.1.29396 target'
        end

        @target_version = TARGET_VERSION
        freeze
      end

      # unit_id must be the caller's technical unit identifier, not a document
      # name. Diagnostic strings never contain document values or inspected BSON.
      # Paths retain array markers' physical indexes, matching the source BSON.
      def audit(document, unit_id:)
        raise ArgumentError, 'loss audit requires a document Hash' unless document.is_a?(Hash)
        raise ArgumentError, 'loss audit requires a String unit identifier' unless unit_id.is_a?(String)

        findings = []
        visit(document, '$', unit_id.dup.freeze, findings, {})
        findings.freeze
      end

      private

      def visit(value, path, unit_id, findings, ancestors)
        return unless value.is_a?(Hash) || value.is_a?(Array)

        identity = value.object_id
        raise ArgumentError, 'loss audit requires an acyclic BSON document' if ancestors.key?(identity)

        ancestors[identity] = true
        begin
          if value.is_a?(Hash)
            visit_document(value, path, unit_id, findings, ancestors)
          else
            value.each_with_index do |child, index|
              visit(child, "#{path}[#{index}]", unit_id, findings, ancestors)
            end
          end
        ensure
          ancestors.delete(identity)
        end
      end

      def visit_document(document, path, unit_id, findings, ancestors)
        type = document['$Type']
        removed_properties = Mendix96129396Strategy::DELETIONS.fetch(type, [])
        removed_properties.each do |property|
          next unless document.key?(property)

          findings << finding(unit_id, "#{path}.#{property}", property,
                              :removed_property, document[property])
        end

        document.each_with_index do |(property, child), index|
          next if removed_properties.include?(property)

          child_path = property_path(path, property, index)
          if type == 'Settings$ProjectSettings' && property == 'Settings' && child.is_a?(Array)
            visit_settings(child, child_path, unit_id, findings, ancestors)
          else
            visit(child, child_path, unit_id, findings, ancestors)
          end
        end
      end

      def visit_settings(settings, path, unit_id, findings, ancestors)
        # Removed parts are reported once and not traversed: the strategy removes
        # them before visiting children, so nested removals would double-count.
        settings.each_with_index do |part, index|
          child_path = "#{path}[#{index}]"
          type = part.is_a?(Hash) ? part['$Type'] : nil
          if Mendix96129396Strategy::UNSUPPORTED_SETTING_PARTS.include?(type)
            findings << finding(unit_id, child_path, type, :removed_setting_part, part)
          else
            visit(part, child_path, unit_id, findings, ancestors)
          end
        end
      end

      def property_path(path, property, index)
        # Unknown dictionary keys can themselves contain private data. Only
        # allowlisted structural labels are echoed; other keys use their index.
        if STRUCTURAL_PROPERTIES.include?(property)
          "#{path}.#{property}"
        else
          "#{path}[field:#{index}]"
        end
      end

      def finding(unit_id, path, property, classification, value)
        reason = classification == :removed_property ? PROPERTY_REASON : SETTING_REASON
        LossFinding.new(
          unit_id:, path: path.freeze, property: property.dup.freeze,
          reason:, classification:, value_type: value_type(value)
        )
      end

      def value_type(value)
        case value
        when nil then :null
        when true, false then :boolean
        when String then :string
        when Integer then :integer
        when Float then :float
        when Hash then :object
        when Array then :collection
        else :other
        end
      end
    end
  end
end
