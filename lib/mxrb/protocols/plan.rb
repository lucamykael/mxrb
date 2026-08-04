# frozen_string_literal: true

module Mxrb
  # Preview/apply orchestration for verified protocol connector packages.
  module Protocols
    Request = Data.define(:protocol, :version, :marketplace_id)
    Adapter = Data.define(:installer, :api)

    # Preview/apply boundary for a real official Marketplace connector. Planning
    # never writes. Apply is available only when an authenticated Content API and
    # an official installer were explicitly supplied by the caller.
    class Plan
      attr_reader :request, :entry, :mendix_version, :package

      def initialize(request:, entry:, context:)
        @request = request
        @entry = entry
        @mendix_version = context.fetch(:mendix_version).to_s
        @adapter = context[:adapter]
        @package = context[:package]
        @applied = false
      end

      def changes
        [{
          action: :install, protocol: entry.protocol, name: entry.name,
          marketplace_id: entry.marketplace_id,
          version: package&.version || request.version || 'latest-compatible',
          mendix_version:, source_url: entry.source_url
        }.freeze].freeze
      end

      def blocked_reasons
        [].tap do |reasons|
          reasons << 'official Marketplace adapter was not provided' unless @adapter
          reasons << 'official Marketplace version was not resolved' unless package
        end.freeze
      end

      def safe? = blocked_reasons.empty?
      def applied? = @applied

      def apply!
        raise MarketplaceError, "connector plan is blocked: #{blocked_reasons.join('; ')}" unless safe?
        raise MarketplaceError, 'connector plan was already applied' if applied?

        result = @adapter.installer.pull_official(
          entry.marketplace_id, version: request.version, mendix_version:, api: @adapter.api
        )
        @applied = true
        result
      end
    end

    module_function

    def request(protocol, version: nil, marketplace_id: nil)
      Request.new(
        protocol: normalize_protocol(protocol), version: version&.to_s,
        marketplace_id: marketplace_id&.to_s
      )
    end

    def adapter(installer:, api:) = Adapter.new(installer:, api:)

    def plan(protocol, mendix_version:, version: nil, marketplace_id: nil, adapter: nil)
      connector_request = request(protocol, version:, marketplace_id:)
      entry = planning_entry(connector_request)
      package = adapter&.api&.resolve(
        entry.marketplace_id, version: connector_request.version, mendix_version:
      )
      Plan.new(
        request: connector_request, entry:,
        context: { mendix_version:, adapter:, package: }
      )
    end

    def planning_entry(request)
      candidates = find_by_protocol(request.protocol)
      candidates = candidates.select { _1.marketplace_id == request.marketplace_id } if request.marketplace_id
      raise MarketplaceError, "no verified Marketplace connector for #{request.protocol.inspect}" if candidates.empty?

      candidates.find { _1.content_type == 'Module' } || candidates.first
    end
  end
end
