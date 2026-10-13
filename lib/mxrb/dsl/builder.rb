# frozen_string_literal: true

require 'digest'
require 'json'
require 'base64'
require_relative '../native_fragment_store'
require_relative 'integration_documents'
require_relative 'code_actions'
require_relative 'workflows'
require_relative 'presentation_documents'
require_relative 'asset_documents'
require_relative 'artifact_documents'
require_relative 'widget_design'
require_relative 'project_documents'
require_relative 'flow_page_builder'
require_relative 'flow_text_builder'
require_relative 'flow_rest_builder'
require_relative 'widget_event_arguments'
require_relative '../forms/input_presentation'

module Mxrb
  module Dsl
    UNSET = Object.new.freeze

    # The values of an attribute-based visibility or editability condition, in
    # Studio Pro order: a pair of the attribute value ("(empty)" for no value)
    # and whether it matches. Model documents pass through unchanged.
    def self.attribute_conditions(conditions)
      Array(conditions).map do |condition|
        next condition if condition.is_a?(Hash)

        value, matches = condition
        raise ArgumentError, "attribute condition requires [value, true|false], got #{condition.inspect}" unless
          condition.is_a?(Array) && condition.size == 2 && [true, false].include?(matches)

        { 'AttributeValue' => value.to_s, 'EditableVisible' => matches }
      end
    end

    # Entry point for the project-definition DSL.
    # Used by Mxrb.define { ... }
    module ConnectorDeclarations
      def connector(protocol, version: nil, marketplace_id: nil)
        connector_requests << Protocols.request(protocol, version:, marketplace_id:)
      end

      def connector_plans(adapter: nil)
        connector_requests.map { connector_plan(_1, adapter) }
      end

      def apply_connector_plans!(adapter:)
        requests = pending_connector_requests
        plans = requests.map { connector_plan(_1, adapter) }
        blocked = plans.reject(&:safe?)
        unless blocked.empty?
          reasons = blocked.flat_map(&:blocked_reasons).uniq.join('; ')
          raise MarketplaceError, "connector plans are blocked: #{reasons}"
        end

        plans.zip(requests).each do |plan, request|
          plan.apply!
          applied_connector_request_ids << request.object_id
        end
        plans.freeze
      end

      private

      def connector_plan(request, adapter)
        Protocols.plan(
          request.protocol, mendix_version: @mendix_version, version: request.version,
                            marketplace_id: request.marketplace_id, adapter:
        )
      end

      def validate_connector_requests!
        return if pending_connector_requests.empty?

        raise MarketplaceError,
              'connector declarations are pending; call apply_connector_plans! ' \
              'with the official Marketplace adapter before build!'
      end

      def connector_requests = (@connector_requests ||= [])

      def pending_connector_requests = connector_requests.reject do
        applied_connector_request_ids.include?(_1.object_id)
      end

      def applied_connector_request_ids = (@applied_connector_request_ids ||= [])
    end

    class Builder # rubocop:disable Metrics/ClassLength
      include ConnectorDeclarations
      include ProjectDocuments
      include NativeFragmentEvaluation

      attr_reader :path

      def initialize(path)
        @path              = path
        @mendix_version    = '10.18.0'
        @modules           = []
        @security          = nil
        @navigation        = nil
        @design_system     = nil
        @native_units_path = nil
        @semantic_metadata = {}
        @preserve_native_pages = false
        @native_fragment_store = nil
        @native_unit_overrides = []
        @project_settings_model = nil
        @system_texts = nil
        @project_assets = nil
        @ruby_app_sources_path = nil
      end

      def mendix_version(v)
        @mendix_version = v
      end

      def module(name, &block)
        flows = @semantic_metadata.dig('modules', name.to_s, 'flows') || {}
        mod = ModuleBuilder.new(
          name, flow_metadata: flows, preserve_native_pages: @preserve_native_pages
        )
        mod.instance_eval(&block) if block
        @modules << mod
      end

      def security(&block)
        builder = SecurityBuilder.new
        builder.instance_eval(&block) if block
        @security = builder.to_h
      end

      def navigation(&block)
        builder = NavigationBuilder.new
        builder.instance_eval(&block) if block
        @navigation = builder.to_h
      end

      def design_system(&block)
        builder = DesignSystemBuilder.new
        builder.instance_eval(&block) if block
        @design_system = builder.to_h
      end

      def native_units(path)
        @native_units_path = path
      end

      def semantic_metadata(path)
        @semantic_metadata = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      end

      def preserve_native_pages(value = true)
        @preserve_native_pages = value == true
      end

      def project_assets(manifest, root:)
        @project_assets = {
          manifest: File.expand_path(manifest),
          root: File.expand_path(root)
        }
      end

      def ruby_app_sources(path)
        @ruby_app_sources_path = File.expand_path(path)
      end

      def native_unit(unit_id, container_id:, containment:, deep_structure:, module_name: nil)
        raise ArgumentError, 'deep_structure requires a Hash' unless deep_structure.is_a?(Hash)

        @native_unit_overrides << {
          unit_id: unit_id.to_s,
          container_id: container_id.to_s,
          containment: containment.to_s,
          module: module_name&.to_s,
          doc: deep_structure
        }
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype)
      end

      def build!
        validate_connector_requests!
        validate!
        Writer.new(@path, definition).write!
        self
      end

      def graph
        Architecture::Graph.new(definition)
      end

      def validate!
        validate_security!
        Architecture::Validator.new(graph).validate!
      end

      def validate_security!
        SecurityValidator.new(@modules, @security).validate!
      end

      def definition
        {
          version: @mendix_version, project_id: @project_id,
          modules: @modules.map(&:to_h),
          security: @security,
          navigation: @navigation,
          design_system: @design_system,
          connectors: connector_requests.map(&:to_h),
          project_assets: @project_assets,
          ruby_app_sources_path: @ruby_app_sources_path,
          native_units_path: @native_units_path,
          native_unit_overrides: @native_unit_overrides,
          project_settings_model: @project_settings_model,
          system_texts: @system_texts
        }
      end
    end
  end
end

require_relative 'widget_dsl'
require_relative 'widget_builders'
require_relative 'data_view_builder'
require_relative 'layout_builders'
require_relative 'security_builder'
require_relative 'navigation_builders'
require_relative 'document_builders'
require_relative 'module_builder'
require_relative 'entity_builder'
require_relative 'page_builder'
require_relative 'flow_body_dsl'
require_relative 'flow_builders'
