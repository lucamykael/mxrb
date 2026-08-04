# frozen_string_literal: true

module Mxrb
  # Read-only registry and audit for Mendix Marketplace protocol connectors
  # (IoT, industrial, and messaging). MXRB never implements or runs these
  # protocols; it only inspects the marketplace modules a project already
  # imported and reports their public metadata.
  module Protocols
    # An immutable registry entry. Every entry must come from a real fixture, an
    # official package, or verifiable official metadata. No identifier may be
    # inferred from a name.
    #
    # `marketplace_id` is the public Mendix Marketplace component id. The
    # per-project `AppStoreGuid` embedded in an .mpr is only known once a real
    # project imports the connector, so `appstore_guids` stays empty until a
    # verified fixture provides it; GUID-based detection then fails closed.
    Entry = Data.define(
      :protocol, :name, :publisher, :category, :marketplace_id,
      :content_type, :appstore_guids, :source_url, :evidence_date
    ) do
      def matches_guid?(guid)
        key = guid.to_s
        !key.empty? && appstore_guids.include?(key)
      end
    end

    # Verified from official Mendix Marketplace pages. Public component ids are
    # useful for planning; module recognition remains GUID-only and fail-closed.
    REGISTRY = [
      Entry.new(
        protocol: :mqtt, name: 'MQTT', publisher: 'Mendix', category: 'Messaging',
        marketplace_id: '119508', content_type: 'Service', appstore_guids: [].freeze,
        source_url: 'https://marketplace.mendix.com/link/component/119508',
        evidence_date: '2026-08-04'
      ),
      Entry.new(
        protocol: :opc_ua, name: 'OPC-UA Connector', publisher: 'Mendix', category: 'Industrial',
        marketplace_id: '230843', content_type: 'Module', appstore_guids: [].freeze,
        source_url: 'https://marketplace.mendix.com/link/component/230843',
        evidence_date: '2026-08-04'
      ),
      Entry.new(
        protocol: :opc_ua, name: 'OPC UA Client Connector', publisher: 'Mendix', category: 'Industrial',
        marketplace_id: '117391', content_type: 'Service', appstore_guids: [].freeze,
        source_url: 'https://marketplace.mendix.com/link/component/117391',
        evidence_date: '2026-08-04'
      ),
      Entry.new(
        protocol: :kafka, name: 'Kafka', publisher: 'Mendix', category: 'Messaging',
        marketplace_id: '105878', content_type: 'Module', appstore_guids: [].freeze,
        source_url: 'https://marketplace.mendix.com/link/component/105878',
        evidence_date: '2026-08-04'
      ),
      Entry.new(
        protocol: :websocket, name: 'WebsocketClient', publisher: 'Mendix', category: 'Communication',
        marketplace_id: '235426', content_type: 'Module', appstore_guids: [].freeze,
        source_url: 'https://marketplace.mendix.com/link/component/235426',
        evidence_date: '2026-08-04'
      ),
      Entry.new(
        protocol: :amqp, name: 'eMagiz Mendix Connector (Legacy)', publisher: 'eMagiz',
        category: 'Communication', marketplace_id: '118800', content_type: 'Service',
        appstore_guids: [].freeze,
        source_url: 'https://marketplace.mendix.com/link/component/118800',
        evidence_date: '2026-08-04'
      )
    ].freeze

    # Read-only result of auditing a project's imported marketplace modules.
    Audit = Data.define(:connectors, :unknown_marketplace_modules)

    module_function

    def all = REGISTRY

    def find_by_protocol(protocol)
      key = normalize_protocol(protocol)
      REGISTRY.select { _1.protocol == key }
    end

    def identify(guid, registry: REGISTRY)
      key = guid.to_s
      return nil if key.empty?

      registry.find { _1.matches_guid?(key) }
    end

    def known_guid?(guid, registry: REGISTRY) = !identify(guid, registry: registry).nil?

    # Walks the project's imported marketplace modules and classifies each one as
    # a recognized connector or an unrecognized marketplace module. Never mutates
    # the project and never installs anything.
    def audit(project, registry: REGISTRY)
      recognized = []
      unknown = []
      project.modules.select(&:from_app_store).each do |mod|
        entry = identify(mod.app_store_guid, registry: registry)
        entry ? recognized << connector_for(mod, entry) : unknown << mod.name.to_s
      end
      Audit.new(connectors: recognized.freeze, unknown_marketplace_modules: unknown.sort.freeze)
    end

    def connector_for(mod, entry)
      readable = mod.export_level.to_s != 'Hidden'
      Model::Connector.new(
        module_name: mod.name, protocol: entry.protocol,
        appstore_guid: mod.app_store_guid, appstore_version: mod.app_store_version.to_s,
        entities: readable ? surface_names(mod.entities) : [],
        microflows: readable ? surface_names(mod.microflows) : [],
        protected: !readable,
        metadata: { name: entry.name, marketplace_id: entry.marketplace_id, source_url: entry.source_url }
      )
    end

    def surface_names(items) = items.map(&:name).compact.sort

    def normalize_protocol(protocol)
      protocol.to_s.strip.downcase.tr('- ', '__').to_sym
    end
  end
end

require_relative 'protocols/plan'
