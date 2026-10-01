# frozen_string_literal: true

module Mxrb
  # Registry and audit for Mendix Marketplace protocol connectors (IoT,
  # industrial, and messaging). This registry inspects imported modules and
  # authenticated Marketplace lock data. Custom runtime clients such as
  # Mxrb::Modbus remain separate from official package certification.
  module Protocols
    # Modern official packages leave `AppStoreGuid` empty. Their durable
    # identity is the Content API id plus the imported module recorded in the
    # Marketplace lock. Exact package evidence remains machine-readable here;
    # GUID-based detection is retained for legacy projects and fails closed.
    require_relative 'protocols/entry'
    require_relative 'protocols/registry'

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

    def identify_content(content_id, registry: REGISTRY)
      key = content_id.to_s
      return nil if key.empty?

      registry.find { _1.marketplace_id == key }
    end

    def known_guid?(guid, registry: REGISTRY) = !identify(guid, registry: registry).nil?

    # Walks the project's imported marketplace modules and classifies each one as
    # a recognized connector or an unrecognized marketplace module. Never mutates
    # the project and never installs anything.
    def audit(project, registry: REGISTRY, lock: project_lock(project))
      recognized, unknown, matched = audit_locked(project, registry, lock)
      audit_legacy(project, registry, matched, recognized, unknown)
      Audit.new(
        connectors: recognized.freeze,
        unknown_marketplace_modules: unknown.uniq.sort.freeze
      )
    end

    def audit_locked(project, registry, lock)
      recognized = []
      unknown = []
      matched = {}
      locked_modules(project, lock).each do |mod, name, data|
        kind, value = classify_locked(mod, name, data, registry)
        kind == :recognized ? recognized << value : unknown << value
        matched[mod.id.to_s] = true
      end
      [recognized, unknown, matched]
    end

    def classify_locked(mod, name, data, registry)
      entry = identify_content(data['content_id'], registry:)
      entry = nil unless entry&.matches_lock?(name, data)
      return [:unknown, mod.name.to_s] unless entry

      [:recognized, connector_for(mod, entry, lock_data: data)]
    end

    def audit_legacy(project, registry, matched, recognized, unknown)
      project.modules.select(&:from_app_store).reject { matched[_1.id.to_s] }.each do |mod|
        entry = identify(mod.app_store_guid, registry:)
        entry ? recognized << connector_for(mod, entry) : unknown << mod.name.to_s
      end
    end

    def connector_for(mod, entry, lock_data: nil)
      readable = mod.export_level.to_s != 'Hidden'
      Model::Connector.new(
        module_name: mod.name, protocol: entry.protocol,
        appstore_guid: mod.app_store_guid, appstore_version: connector_version(mod, lock_data),
        entities: readable ? surface_names(mod.entities) : [],
        microflows: readable ? surface_names(mod.microflows) : [],
        protected: !readable,
        metadata: connector_metadata(entry, lock_data)
      )
    end

    def connector_version(mod, lock_data)
      version = mod.app_store_version.to_s
      version.empty? && lock_data ? lock_data['version'].to_s : version
    end

    def connector_metadata(entry, lock_data)
      metadata = {
        name: entry.name, marketplace_id: entry.marketplace_id, source_url: entry.source_url
      }
      return metadata unless lock_data

      metadata.merge(
        version_id: lock_data['version_id'], provenance: :official_marketplace_lock,
        certified_package: entry.certified_lock?(lock_data)
      )
    end

    def project_lock(project)
      OfficialMarketplace.lock(File.dirname(project.mpr.path))
    end

    def locked_modules(project, lock)
      lock.fetch('packages', {}).filter_map do |name, data|
        next unless data['kind'] == 'module' && data['content_id']

        mod = locked_module(project.modules, name, data['module_id'])
        [mod, name, data] if mod
      end
    end

    def locked_module(modules, name, module_id)
      modules.find { _1.id.to_s == module_id.to_s } || modules.find { _1.name.to_s == name.to_s }
    end

    def surface_names(items) = items.map(&:name).compact.sort

    def normalize_protocol(protocol)
      protocol.to_s.strip.downcase.tr('- ', '__').to_sym
    end
  end
end

require_relative 'protocols/plan'
