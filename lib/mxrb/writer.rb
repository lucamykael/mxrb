# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "sqlite3"
require "time"

module Mxrb
  # Applies a DSL definition to a new or existing MPR. Names are used as the
  # stable key, making repeated `mxrb generate` runs idempotent.
  class Writer
    GLYPH_ICON_CODES = {
      'home' => 57_377, 'pets' => 57_349, 'heart' => 57_349,
      'calendar' => 57_609, 'calendar_today' => 57_609,
      'user' => 57_352, 'search' => 57_347, 'settings' => 57_369,
      'trash' => 57_376, 'file' => 57_378, 'time' => 57_379,
      'shopping_cart' => 57_622, 'tasks' => 57_655, 'checklist' => 57_655
    }.freeze

    LEGACY_NAVIGATION_PROFILES = {
      "Desktop" => "DesktopProfile",
      "Tablet" => "TabletProfile",
      "Phone" => "PhoneProfile",
      "OfflinePhone" => "OfflinePhoneProfile",
      "HybridPhone" => "HybridPhoneProfile6",
      "HybridTablet" => "HybridTabletProfile6"
    }.freeze

    RUBY_NATIVE_LIFECYCLE_EVENTS = %i[
      before_commit after_commit before_delete after_delete
    ].freeze

    def initialize(path, definition)
      @path = File.expand_path(path)
      @definition = definition
      @progress = Progress::NullTask.instance
    end

    def write!
      mpr = nil
      validate_native_output_filename!
      native_units = prepared_native_units
      asset_manifest = project_asset_manifest
      total = 4 + native_units.count { _1["containment"] != "Modules" } +
              @definition.fetch(:modules).size + Array(asset_manifest&.fetch("files", [])).size
      Progress.with("Generating #{File.basename(@path)}", total:) do |progress|
        @progress = progress
        create_project! unless File.exist?(@path)
        progress.advance(detail: "project container")
        mpr = IO::MprFile.open(@path)
        mpr.transaction do
          apply(mpr, native_units)
          write_native_compatibility(mpr, native_units)
          mpr.write_architecture_definition(@definition)
          mpr.write_ruby_app_sources(ruby_app_source_files) if @definition[:ruby_app_sources_path]
        end
        progress.advance(detail: "model transaction")
        materialize_project_assets(asset_manifest)
        materialize_design_system
        progress.advance(detail: "design system")
      end
      self
    ensure
      @progress = Progress::NullTask.instance
      mpr&.close
    end

    # Incrementally applies Ruby-first pages and flows to an existing module.
    # Unlike #write!, this deliberately does not rewrite the domain model,
    # security, settings, or unrelated native documents.
    def synchronize_ruby_documents!(mpr, module_name:, pages: [], microflows: [], nanoflows: [],
                                    navigation_items: [])
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      definition = {
        name: module_name.to_s, pages: Array(pages), microflows: Array(microflows),
        nanoflows: Array(nanoflows), menus: [], enumerations: [], constants: [],
        scheduled_events: []
      }
      mpr.transaction do
        write_documents(mpr, raw_module.fetch("UnitID"), definition)
        synchronize_ruby_navigation!(mpr, root_id, navigation_items)
      end
      self
    end

    # Applies the authoritative association declarations of Ruby Record classes
    # without rewriting entities or opaque domain-model metadata.
    def synchronize_ruby_associations!(mpr, module_name:, entities:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      module_id = raw_module.fetch("UnitID")
      raw_domain = mpr.units_by_containment("DomainModel").find { _1["ContainerID"] == module_id }
      raise ValidationError, "Mendix module #{module_name} has no domain model" unless raw_domain

      synchronize_ruby_domain_associations!(mpr, raw_domain, module_name.to_s, Array(entities))
      self
    end

    # Incrementally applies authoritative Ruby enumeration declarations while
    # retaining native fields, localization structures, and stable ids.
    def synchronize_ruby_enumerations!(mpr, module_name:, enumerations:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      declarations = Array(enumerations)
      validate_ruby_enumerations!(module_name, declarations)
      module_id = raw_module.fetch("UnitID")
      existing = collect_documents(mpr, module_id).filter_map do |raw|
        document = mpr.parse_contents(raw)
        [raw, document] if document["$Type"] == "Enumerations$Enumeration"
      end
      by_id = existing.to_h { |raw, doc| [IO::BsonCodec.extract_id(doc["$ID"]) || raw["UnitID"], [raw, doc]] }
      by_name = existing.to_h { |raw, doc| [doc["Name"].to_s, [raw, doc]] }

      mpr.transaction do
        declarations.each do |declaration|
          id = declaration[:id].to_s
          named = by_name[declaration.fetch(:name).to_s]
          validate_ruby_identity!(id, by_id, named, "enumeration #{module_name}.#{declaration.fetch(:name)}")
          pair = (!id.empty? && by_id[id]) || named
          raw, previous = pair
          document = ruby_enumeration_doc(declaration, previous:)
          if raw
            mpr.update_unit(raw.fetch("UnitID"), document)
          else
            unit_id = id.empty? ? nil : id
            mpr.insert_unit(
              container_uuid: module_id, containment_name: "Documents",
              contents_doc: document, unit_uuid: unit_id
            )
          end
        end
      end
      self
    end

    # Incrementally applies Ruby constant declarations without revealing or
    # replacing private defaults unless the declaration supplies a new value.
    def synchronize_ruby_constants!(mpr, module_name:, constants:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      declarations = Array(constants)
      validate_ruby_constants!(module_name, declarations)
      module_id = raw_module.fetch("UnitID")
      existing = collect_documents(mpr, module_id).filter_map do |raw|
        document = mpr.parse_contents(raw)
        [raw, document] if document["$Type"] == "Constants$Constant"
      end
      by_id = existing.to_h { |raw, doc| [IO::BsonCodec.extract_id(doc["$ID"]) || raw["UnitID"], [raw, doc]] }
      by_name = existing.to_h { |raw, doc| [doc["Name"].to_s, [raw, doc]] }
      legacy = existing.any? { |_raw, doc| doc.key?("DataType") && !doc.key?("Type") } ||
               mpr.mendix_version.to_s.split('.').first.to_i < 7

      mpr.transaction do
        declarations.each do |declaration|
          id = declaration[:id].to_s
          named = by_name[declaration.fetch(:name).to_s]
          validate_ruby_identity!(id, by_id, named, "constant #{module_name}.#{declaration.fetch(:name)}")
          pair = (!id.empty? && by_id[id]) || named
          raw, previous = pair
          document = ruby_constant_doc(declaration, previous:, legacy:)
          if raw
            mpr.update_unit(raw.fetch("UnitID"), document)
          else
            unit_id = id.empty? ? nil : id
            mpr.insert_unit(
              container_uuid: module_id, containment_name: "Documents",
              contents_doc: document, unit_uuid: unit_id
            )
          end
        end
      end
      self
    end

    # Applies authoritative entity access rules directly to the embedded
    # domain model while retaining rule/member IDs and unsupported metadata.
    def synchronize_ruby_entity_access!(mpr, module_name:, entities:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      module_id = raw_module.fetch("UnitID")
      raw_domain = mpr.units_by_containment("DomainModel").find { _1["ContainerID"] == module_id }
      raise ValidationError, "Mendix module #{module_name} has no domain model" unless raw_domain

      domain = mpr.parse_contents(raw_domain)
      entities_key = native_key(domain, "entities", "Entities")
      payload = IO::BsonCodec.parse_array(domain[entities_key])
      existing = payload.fetch(:items).to_h do |entity|
        [(entity["name"] || entity["Name"]).to_s, entity]
      end
      Array(entities).each do |declaration|
        rules = declaration[:access_rules]
        next if rules.nil?

        name = declaration.fetch(:name).to_s
        entity = existing[name]
        raise ValidationError, "entity #{module_name}.#{name} does not exist" unless entity

        rules_key = native_key(entity, "accessRules", "AccessRules")
        entity[rules_key] = ruby_access_rule_docs(
          Array(rules), entity[rules_key], module_name.to_s, name
        )
      end
      domain[entities_key] = IO::BsonCodec.build_array(
        payload.fetch(:items), marker: payload.fetch(:marker)
      )
      mpr.transaction { mpr.update_unit(raw_domain.fetch("UnitID"), domain) }
      self
    end

    # Applies authoritative indexes and system-member flags without replacing
    # the surrounding entity/generalization documents.
    def synchronize_ruby_entity_structures!(mpr, module_name:, entities:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      module_id = raw_module.fetch("UnitID")
      raw_domain = mpr.units_by_containment("DomainModel").find { _1["ContainerID"] == module_id }
      raise ValidationError, "Mendix module #{module_name} has no domain model" unless raw_domain

      domain = mpr.parse_contents(raw_domain)
      entities_key = native_key(domain, "entities", "Entities")
      payload = IO::BsonCodec.parse_array(domain[entities_key])
      existing = payload.fetch(:items).to_h do |entity|
        [(entity["name"] || entity["Name"]).to_s, entity]
      end
      declarations = Array(entities)
      declarations.each do |declaration|
        name = declaration.fetch(:name).to_s
        entity = existing[name]
        raise ValidationError, "entity #{module_name}.#{name} does not exist" unless entity

        synchronize_ruby_indexes!(entity, declaration[:indexes], module_name.to_s, name) \
          unless declaration[:indexes].nil?
        synchronize_ruby_system_members!(entity, declaration[:system_members]) \
          unless declaration[:system_members].nil?
        synchronize_ruby_generalization!(entity, declaration[:generalization]) \
          unless declaration[:generalization].nil?
        unless declaration[:oql_view].nil?
          synchronize_ruby_oql_view!(entity, declaration[:oql_view], module_name.to_s, name)
          synchronize_ruby_oql_member_values!(entity)
        end
      end
      domain[entities_key] = IO::BsonCodec.build_array(
        payload.fetch(:items), marker: payload.fetch(:marker)
      )
      mpr.transaction do
        mpr.update_unit(raw_domain.fetch("UnitID"), domain)
        synchronize_ruby_oql_documents!(mpr, module_id, module_name.to_s, declarations)
      end
      self
    end

    # Applies authoritative native validation rules and Mendix lifecycle
    # handlers while keeping unrelated entity metadata opaque.
    def synchronize_ruby_entity_behaviors!(mpr, module_name:, entities:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      module_id = raw_module.fetch("UnitID")
      raw_domain = mpr.units_by_containment("DomainModel").find { _1["ContainerID"] == module_id }
      raise ValidationError, "Mendix module #{module_name} has no domain model" unless raw_domain

      domain = mpr.parse_contents(raw_domain)
      entities_key = native_key(domain, "entities", "Entities")
      payload = IO::BsonCodec.parse_array(domain[entities_key])
      existing = payload.fetch(:items).to_h do |entity|
        [(entity["name"] || entity["Name"]).to_s, entity]
      end
      Array(entities).each do |declaration|
        name = declaration.fetch(:name).to_s
        entity = existing[name]
        raise ValidationError, "entity #{module_name}.#{name} does not exist" unless entity

        unless declaration[:lifecycle].nil?
          key = native_existing_key(entity, "eventHandlers", "EventHandlers") || "EventHandlers"
          entity[key] = ruby_lifecycle_docs(declaration[:lifecycle], entity[key], module_name, name)
        end
        next if declaration[:validation_rules].nil?

        key = native_existing_key(entity, "validationRules", "ValidationRules") || "ValidationRules"
        attributes_key = native_existing_key(entity, "attributes", "Attributes") || "Attributes"
        attribute_names = IO::BsonCodec.parse_array(entity[attributes_key]).fetch(:items).map do |attribute|
          (attribute["name"] || attribute["Name"]).to_s
        end
        entity[key] = ruby_validation_rule_docs(
          declaration[:validation_rules], entity[key], module_name, name, attribute_names
        )
      end
      domain[entities_key] = IO::BsonCodec.build_array(
        payload.fetch(:items), marker: payload.fetch(:marker)
      )
      mpr.transaction { mpr.update_unit(raw_domain.fetch("UnitID"), domain) }
      self
    end

    # Applies an authoritative module-role collection while preserving
    # unsupported role entries and native document metadata.
    def synchronize_ruby_module_security!(mpr, module_name:, security:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      module_id = raw_module.fetch("UnitID")
      raw = mpr.children_of(module_id).find { _1["ContainmentName"] == "ModuleSecurity" }
      if raw.nil? && security[:id].to_s.empty? && Array(security[:roles]).empty?
        return self
      end

      previous = raw ? mpr.parse_contents(raw) : {}
      document = ruby_module_security_doc(security, previous, module_name.to_s)
      mpr.transaction do
        if raw
          mpr.update_unit(raw.fetch("UnitID"), document)
        else
          mpr.insert_unit(
            container_uuid: module_id, containment_name: "ModuleSecurity",
            contents_doc: document, unit_uuid: document.fetch("$ID")
          )
        end
      end
      self
    end

    # Applies the editable project-security surface without exposing stored
    # passwords or replacing native access containers and unknown properties.
    def synchronize_ruby_project_security!(mpr, security:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw = mpr.children_of(root_id).find do |unit|
        unit["ContainmentName"] == "ProjectDocuments" &&
          mpr.parse_contents(unit)["$Type"] == "Security$ProjectSecurity"
      end
      previous = raw ? mpr.parse_contents(raw) : {}
      document = ruby_project_security_doc(security, previous)
      mpr.transaction do
        if raw
          mpr.update_unit(raw.fetch("UnitID"), document)
        else
          mpr.insert_unit(
            container_uuid: root_id, containment_name: "ProjectDocuments",
            contents_doc: document, unit_uuid: document.fetch("$ID")
          )
        end
      end
      self
    end

    # Applies the authoritative scheduled-event collection for one module.
    def synchronize_ruby_scheduled_events!(mpr, module_name:, events:)
      root_id = mpr.root_unit.fetch("UnitID")
      raw_module = find_named(mpr, "Modules", root_id, module_name.to_s)
      raise ValidationError, "Mendix module #{module_name} does not exist" unless raw_module

      declarations = Array(events)
      validate_ruby_scheduled_events!(module_name, declarations)
      module_id = raw_module.fetch("UnitID")
      existing = collect_documents(mpr, module_id).filter_map do |raw|
        document = mpr.parse_contents(raw)
        [raw, document] if document["$Type"] == "ScheduledEvents$ScheduledEvent"
      end
      by_id = existing.to_h do |raw, document|
        [IO::BsonCodec.extract_id(document["$ID"]) || raw["UnitID"], [raw, document]]
      end
      by_name = existing.to_h { |raw, document| [document["Name"].to_s, [raw, document]] }
      retained = []
      mpr.transaction do
        declarations.each do |declaration|
          id = declaration[:id].to_s
          named = by_name[declaration.fetch(:name).to_s]
          validate_ruby_identity!(
            id, by_id, named,
            "scheduled event #{module_name}.#{declaration.fetch(:name)}"
          )
          raw, previous = (!id.empty? && by_id[id]) || named
          document = ruby_scheduled_event_doc(declaration, previous, module_name.to_s)
          if raw
            retained << raw.fetch("UnitID")
            mpr.update_unit(raw.fetch("UnitID"), document)
          else
            retained << mpr.insert_unit(
              container_uuid: module_id, containment_name: "Documents",
              contents_doc: document, unit_uuid: document.fetch("$ID")
            )
          end
        end
        existing.each do |raw,|
          mpr.delete_unit(raw.fetch("UnitID")) unless retained.include?(raw.fetch("UnitID"))
        end
      end
      self
    end

    # Canonical editor-shape serializers shared by incremental semantic plans.
    def build_domain_entity_document(entity, module_name:, previous: nil, index: 0)
      entity_doc(entity, module_name, previous, index)
    end

    def build_domain_attribute_document(attribute, previous: nil)
      attribute_doc(attribute, previous)
    end

    private

    ACCESS_RIGHTS = %i[None ReadOnly ReadWrite].freeze
    ACCESS_MEMBER_KINDS = %i[attribute association].freeze

    def ruby_access_rule_docs(declarations, previous, module_name, entity_name)
      validate_ruby_access_rules!(declarations, module_name, entity_name)
      payload = IO::BsonCodec.parse_array(previous)
      supported, opaque = payload.fetch(:items).partition do |rule|
        rule.is_a?(Hash) && rule["$Type"] == "DomainModels$AccessRule"
      end
      by_id = supported.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_signature = supported.group_by { access_rule_signature(_1) }
      rules = declarations.map do |declaration|
        id = declaration[:id].to_s
        signature_match = Array(by_signature[access_rule_declaration_signature(declaration)]).then do |matches|
          matches.one? ? matches.first : nil
        end
        validate_ruby_nested_identity!(id, by_id, signature_match, "access rule")
        current = (!id.empty? && by_id[id]) || signature_match
        ruby_access_rule_doc(declaration, current, module_name, entity_name)
      end
      IO::BsonCodec.build_array(rules + opaque, marker: payload.fetch(:marker))
    end

    def synchronize_ruby_indexes!(entity, declarations, module_name, entity_name)
      attributes_key = native_key(entity, "attributes", "Attributes")
      attributes = IO::BsonCodec.parse_array(entity[attributes_key])[:items]
      attribute_ids = attributes.to_h do |attribute|
        [(attribute["name"] || attribute["Name"]).to_s,
         IO::BsonCodec.extract_id(attribute["$ID"])]
      end
      indexes_key = native_key(entity, "indexes", "Indexes")
      entity[indexes_key] = ruby_index_docs(
        Array(declarations), entity[indexes_key], attribute_ids, module_name, entity_name
      )
    end

    def ruby_index_docs(declarations, previous, attribute_ids, module_name, entity_name)
      validate_ruby_indexes!(declarations, attribute_ids, module_name, entity_name)
      payload = IO::BsonCodec.parse_array(previous)
      supported, opaque = payload.fetch(:items).partition do |index|
        index.is_a?(Hash) && index["$Type"] == "DomainModels$EntityIndex"
      end
      names_by_id = attribute_ids.to_h { |name, id| [id, name] }
      by_id = supported.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_signature = supported.group_by { ruby_index_signature(_1, names_by_id) }
      indexes = declarations.map do |declaration|
        id = declaration[:id].to_s
        matches = Array(by_signature[ruby_index_declaration_signature(declaration)])
        semantic_match = matches.one? ? matches.first : nil
        validate_ruby_nested_identity!(id, by_id, semantic_match, "index")
        current = (!id.empty? && by_id[id]) || semantic_match
        ruby_index_doc(declaration, current, attribute_ids)
      end
      IO::BsonCodec.build_array(indexes + opaque, marker: payload.fetch(:marker))
    end

    def validate_ruby_indexes!(declarations, attribute_ids, module_name, entity_name)
      ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
      signatures = declarations.map { ruby_index_declaration_signature(_1) }
      if ids.uniq.size != ids.size || signatures.uniq.size != signatures.size
        raise ValidationError, "duplicate indexes for #{module_name}.#{entity_name}"
      end
      declarations.each do |index|
        validate_ruby_uuid!(index[:id], "index for #{module_name}.#{entity_name}")
        validate_ruby_uuid!(index[:guid], "index GUID for #{module_name}.#{entity_name}")
        members = Array(index[:members])
        raise ValidationError, "empty index for #{module_name}.#{entity_name}" if members.empty?

        member_ids = members.map { _1[:id].to_s }.reject(&:empty?)
        raise ValidationError, "duplicate index members for #{module_name}.#{entity_name}" \
          unless member_ids.uniq.size == member_ids.size
        members.each do |member|
          validate_ruby_uuid!(member[:id], "index member for #{module_name}.#{entity_name}")
          name = member.fetch(:name).to_s
          raise ValidationError, "unknown indexed attribute #{module_name}.#{entity_name}.#{name}" \
            unless attribute_ids.key?(name)
        end
      end
    end

    def ruby_index_doc(declaration, current, attribute_ids)
      previous = current || {}
      id = declaration[:id].to_s
      id = IO::BsonCodec.extract_id(previous["$ID"]) || SecureRandom.uuid if id.empty?
      guid = declaration[:guid].to_s
      guid = IO::BsonCodec.extract_id(previous["GUID"]) || id if guid.empty?
      members_payload = IO::BsonCodec.parse_array(previous["Attributes"])
      previous_members = members_payload.fetch(:items)
      by_id = previous_members.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_name = previous_members.to_h do |member|
        pointer = IO::BsonCodec.extract_id(member["AttributePointer"])
        [attribute_ids.key(pointer), member]
      end
      members = Array(declaration[:members]).map do |member|
        member_id = member[:id].to_s
        prior = (!member_id.empty? && by_id[member_id]) || by_name[member.fetch(:name).to_s]
        ruby_index_member_doc(member, prior, attribute_ids)
      end
      previous.merge(
        "$ID" => id, "$Type" => previous["$Type"] || "DomainModels$EntityIndex",
        "GUID" => binary_uuid(guid),
        "Attributes" => IO::BsonCodec.build_array(members, marker: members_payload.fetch(:marker)),
        "IncludeInOffline" => declaration.fetch(:include_offline, false) == true
      )
    end

    def ruby_index_member_doc(declaration, current, attribute_ids)
      previous = current || {}
      id = declaration[:id].to_s
      id = IO::BsonCodec.extract_id(previous["$ID"]) || SecureRandom.uuid if id.empty?
      previous.merge(
        "$ID" => id, "$Type" => previous["$Type"] || "DomainModels$IndexedAttribute",
        "Type" => declaration.fetch(:type, :Normal).to_s,
        "AttributePointer" => binary_uuid(attribute_ids.fetch(declaration.fetch(:name).to_s)),
        "AssociationPointer" => previous.fetch(
          "AssociationPointer", binary_uuid("00000000-0000-0000-0000-000000000000")
        ),
        "Ascending" => declaration.fetch(:ascending, true) == true
      )
    end

    def ruby_index_signature(index, names_by_id)
      members = IO::BsonCodec.parse_array(index["Attributes"])[:items]
      members.map { names_by_id[IO::BsonCodec.extract_id(_1["AttributePointer"])] }
    end

    def ruby_index_declaration_signature(index)
      Array(index[:members]).map { _1.fetch(:name).to_s }
    end

    def synchronize_ruby_system_members!(entity, declaration)
      key = native_existing_key(
        entity, "generalization", "Generalization", "maybeGeneralization", "MaybeGeneralization"
      ) || "MaybeGeneralization"
      generalization = entity[key]
      unless generalization.is_a?(Hash) && generalization["$Type"].to_s.end_with?("NoGeneralization")
        raise ValidationError, "system members require an entity without generalization"
      end
      fields = {
        owner: %w[hasOwner HasOwnerAttr], created_date: %w[hasCreatedDate HasCreatedDateAttr],
        changed_date: %w[hasChangedDate HasChangedDateAttr],
        changed_by: %w[hasChangedBy HasChangedByAttr]
      }
      fields.each do |name, variants|
        field = native_existing_key(generalization, *variants) || variants.last
        generalization[field] = declaration.fetch(name, false) == true
      end
    end

    def synchronize_ruby_generalization!(entity, target)
      declaration = target.respond_to?(:to_h) ? target.to_h.transform_keys(&:to_sym) : { target: }
      target = declaration.fetch(:target).to_s
      raise ValidationError, 'generalization target cannot be empty' if target.empty?
      validate_ruby_uuid!(declaration[:id], "generalization for #{target}")

      key = native_existing_key(
        entity, "generalization", "Generalization", "maybeGeneralization", "MaybeGeneralization"
      ) || "MaybeGeneralization"
      previous = entity[key].is_a?(Hash) ? entity[key] : {}
      reference_key = native_existing_key(previous, "generalization", "Generalization") || "Generalization"
      type = previous["$Type"].to_s
      declared_id = declaration[:id].to_s
      document = previous.merge(
        "$ID" => declared_id.empty? ? (previous["$ID"] || SecureRandom.uuid) : declared_id,
        "$Type" => type.end_with?("Generalization") && !type.end_with?("NoGeneralization") ?
          type : "DomainModels$Generalization",
        reference_key => target
      )
      if target.start_with?("System.") && type.end_with?("NoGeneralization")
        {
          "Persistable" => true, "HasCreatedDateAttr" => true,
          "HasChangedDateAttr" => true, "HasOwnerAttr" => true,
          "HasChangedByAttr" => true
        }.each do |name, value|
          field = native_existing_key(document, name.sub(/Attr\z/, ''), name) || name
          document[field] = value
        end
      end
      entity[key] = document
    end

    def synchronize_ruby_oql_view!(entity, declaration, module_name, entity_name)
      validate_ruby_uuid!(declaration[:source_id], "OQL source for #{module_name}.#{entity_name}")
      validate_ruby_uuid!(declaration[:document_id], "OQL document for #{module_name}.#{entity_name}")
      source = declaration[:source].to_s
      query = declaration[:query]
      if source.empty? && query.to_s.empty?
        raise ValidationError, "OQL view #{module_name}.#{entity_name} requires source or query"
      end

      unless source.empty?
        key = native_existing_key(entity, "source", "Source") || "Source"
        previous = entity[key].is_a?(Hash) ? entity[key] : {}
        declared_id = declaration[:source_id].to_s
        previous_id = IO::BsonCodec.extract_id(previous["$ID"])
        if !declared_id.empty? && previous_id && declared_id != previous_id
          raise ValidationError, "OQL source id does not match #{module_name}.#{entity_name}"
        end
        source_key = native_existing_key(previous, "sourceDocument", "SourceDocument") ||
                     "SourceDocument"
        entity[key] = previous.merge(
          "$ID" => declared_id.empty? ? (previous_id || SecureRandom.uuid) : declared_id,
          "$Type" => "DomainModels$OqlViewEntitySource", source_key => source
        )
      end
      return if query.nil? || !source.empty?

      query_key = native_existing_key(entity, "oqlQuery", "OqlQuery", "OQLQuery") || "OqlQuery"
      entity[query_key] = query.to_s
    end

    def synchronize_ruby_oql_member_values!(entity)
      attributes_key = native_existing_key(entity, "attributes", "Attributes") || "Attributes"
      payload = IO::BsonCodec.parse_array(entity[attributes_key])
      payload.fetch(:items).each do |attribute|
        name = (attribute["name"] || attribute["Name"]).to_s
        next if name.empty?

        value_key = native_existing_key(attribute, "value", "Value") || "Value"
        previous = attribute[value_key].is_a?(Hash) ? attribute[value_key] : {}
        reference_key = native_existing_key(previous, "reference", "Reference") || "Reference"
        value = previous.merge(
          "$ID" => previous["$ID"] || SecureRandom.uuid,
          "$Type" => "DomainModels$OqlViewValue",
          reference_key => name
        )
        value.delete("DefaultValue")
        value.delete("defaultValue")
        attribute[value_key] = value
      end
      entity[attributes_key] = IO::BsonCodec.build_array(
        payload.fetch(:items), marker: payload.fetch(:marker)
      )
    end

    def synchronize_ruby_oql_documents!(mpr, module_id, module_name, entities)
      declarations = entities.filter_map do |entity|
        view = entity[:oql_view]
        next if view.nil? || view[:query].nil? || view[:source].to_s.empty?

        [entity.fetch(:name).to_s, view]
      end
      return if declarations.empty?

      existing = collect_documents(mpr, module_id).filter_map do |raw|
        document = mpr.parse_contents(raw)
        [raw, document] if document["$Type"] == "DomainModels$ViewEntitySourceDocument"
      end
      by_id = existing.to_h do |raw, document|
        [IO::BsonCodec.extract_id(document["$ID"]) || raw["UnitID"], [raw, document]]
      end
      by_name = existing.to_h { |raw, document| [document["Name"].to_s, [raw, document]] }
      declarations.each do |entity_name, view|
        name = view.fetch(:source).to_s.split('.').last
        id = view[:document_id].to_s
        named = by_name[name]
        validate_ruby_identity!(id, by_id, named, "OQL document #{module_name}.#{name}")
        raw, previous = (!id.empty? && by_id[id]) || named
        document = (previous || {}).merge(
          "$ID" => id.empty? ? (previous&.dig("$ID") || SecureRandom.uuid) : id,
          "$Type" => "DomainModels$ViewEntitySourceDocument",
          "Name" => name, "Oql" => view.fetch(:query).to_s
        )
        if raw
          mpr.update_unit(raw.fetch("UnitID"), document)
        else
          mpr.insert_unit(
            container_uuid: module_id, containment_name: "Documents",
            contents_doc: document, unit_uuid: id.empty? ? nil : id
          )
        end
      rescue KeyError
        raise ValidationError, "OQL view #{module_name}.#{entity_name} has an invalid declaration"
      end
    end

    def ruby_lifecycle_docs(declarations, previous, module_name, entity_name)
      payload = IO::BsonCodec.parse_array(previous)
      supported, opaque = payload.fetch(:items).partition do |handler|
        handler.is_a?(Hash) && handler["$Type"] == "DomainModels$EventHandler"
      end
      by_id = supported.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_event = supported.group_by { lifecycle_signature(_1) }
      declarations = Array(declarations)
      ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
      events = declarations.map { _1.fetch(:event).to_sym }
      if ids.uniq.size != ids.size || events.uniq.size != events.size
        raise ValidationError, "duplicate lifecycle handlers for #{module_name}.#{entity_name}"
      end

      handlers = declarations.map do |declaration|
        event = declaration.fetch(:event).to_sym
        unless RUBY_NATIVE_LIFECYCLE_EVENTS.include?(event)
          raise ValidationError, "unsupported native lifecycle event #{event}"
        end
        handler = declaration.fetch(:handler).to_s
        raise ValidationError, "lifecycle handler for #{module_name}.#{entity_name} is empty" \
          if handler.empty?

        id = declaration[:id].to_s
        validate_ruby_uuid!(id, "lifecycle handler for #{module_name}.#{entity_name}")
        matches = Array(by_event[event])
        semantic_match = matches.one? ? matches.first : nil
        validate_ruby_nested_identity!(id, by_id, semantic_match, "lifecycle handler #{event}")
        current = (!id.empty? && by_id[id]) || semantic_match
        ruby_lifecycle_doc(declaration, current, "#{module_name}.#{entity_name}")
      end
      IO::BsonCodec.build_array(handlers + opaque, marker: payload.fetch(:marker))
    end

    def ruby_module_security_doc(declaration, previous, module_name)
      current = previous || {}
      id = ruby_existing_or_stable_id(
        declaration[:id], current["$ID"], "module security #{module_name}",
        'module-security', module_name
      )
      payload = IO::BsonCodec.parse_array(current["ModuleRoles"])
      supported, opaque = payload.fetch(:items).partition do |role|
        role.is_a?(Hash) && role["$Type"] == "Security$ModuleRole"
      end
      by_id = supported.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_name = supported.group_by { _1["Name"].to_s }
      declarations = Array(declaration[:roles])
      validate_ruby_security_declarations!(declarations, "module roles in #{module_name}")
      roles = declarations.map do |role|
        role_id = role[:id].to_s
        matches = Array(by_name[role.fetch(:name).to_s])
        semantic_match = matches.one? ? matches.first : nil
        validate_ruby_nested_identity!(role_id, by_id, semantic_match, "module role #{role.fetch(:name)}")
        prior = (!role_id.empty? && by_id[role_id]) || semantic_match || {}
        prior.merge(
          "$ID" => ruby_existing_or_stable_id(
            role_id, prior["$ID"], "module role #{role.fetch(:name)}",
            'module-role', module_name, role.fetch(:name)
          ),
          "$Type" => "Security$ModuleRole",
          "Name" => role.fetch(:name).to_s,
          "Description" => role.fetch(:description, '').to_s
        )
      end
      current.merge(
        "$ID" => id, "$Type" => "Security$ModuleSecurity",
        "ModuleRoles" => IO::BsonCodec.build_array(roles + opaque, marker: payload.fetch(:marker))
      )
    end

    def ruby_project_security_doc(declaration, previous)
      current = previous.empty? ? project_security_doc({}) : previous
      id = ruby_existing_or_stable_id(
        declaration[:id], current["$ID"], "project security", 'project-security'
      )
      document = current.merge("$ID" => id, "$Type" => "Security$ProjectSecurity")
      {
        security_level: "SecurityLevel",
        admin_user_role: "AdminUserRole",
        demo_users_enabled: "EnableDemoUsers",
        guest_access_enabled: "EnableGuestAccess",
        guest_user_role: "GuestUserRole",
        sign_in_microflow: "SignInMicroflow"
      }.each do |definition_key, native_key|
        next unless declaration.key?(definition_key)

        value = declaration[definition_key]
        document[native_key] = if %i[demo_users_enabled guest_access_enabled].include?(definition_key)
                                 value == true
                               else
                                 value.to_s
                               end
      end
      document["UserRoles"] = ruby_project_user_roles(
        declaration.fetch(:user_roles, []), current["UserRoles"]
      )
      document["DemoUsers"] = ruby_project_demo_users(
        declaration.fetch(:demo_users, []), current["DemoUsers"]
      )
      if declaration.key?(:password_policy)
        if declaration[:password_policy]
          document["PasswordPolicySettings"] = ruby_password_policy_doc(
            declaration.fetch(:password_policy), current["PasswordPolicySettings"], id
          )
        else
          document.delete("PasswordPolicySettings")
        end
      end
      admin_role = document["AdminUserRole"].to_s
      role_names = IO::BsonCodec.parse_array(document["UserRoles"]).fetch(:items).filter_map do |role|
        role["Name"].to_s if role.is_a?(Hash) && role["$Type"] == "Security$UserRole"
      end
      if !admin_role.empty? && !role_names.include?(admin_role)
        raise ValidationError, "project admin user role #{admin_role} is not declared"
      end
      document
    end

    def ruby_project_user_roles(declarations, previous)
      payload = IO::BsonCodec.parse_array(previous)
      supported, opaque = payload.fetch(:items).partition do |role|
        role.is_a?(Hash) && role["$Type"] == "Security$UserRole"
      end
      by_id = supported.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_name = supported.group_by { _1["Name"].to_s }
      declarations = Array(declarations)
      validate_ruby_security_declarations!(declarations, "project user roles")
      roles = declarations.map do |role|
        declared_module_roles = Array(role[:module_roles]).map(&:to_s)
        unless declared_module_roles.any? { _1.start_with?('System.') }
          raise ValidationError,
                "project user role #{role.fetch(:name)} requires at least one System module role"
        end

        role_id = role[:id].to_s
        matches = Array(by_name[role.fetch(:name).to_s])
        semantic_match = matches.one? ? matches.first : nil
        validate_ruby_nested_identity!(role_id, by_id, semantic_match, "project role #{role.fetch(:name)}")
        prior = (!role_id.empty? && by_id[role_id]) || semantic_match || {}
        id = ruby_existing_or_stable_id(
          role_id, prior["$ID"], "project role #{role.fetch(:name)}",
          'project-role', role.fetch(:name)
        )
        guid = ruby_project_role_guid(role, prior, id)
        manageable = IO::BsonCodec.parse_array(prior["ManageableRoles"])
        module_roles = IO::BsonCodec.parse_array(prior["ModuleRoles"])
        prior.merge(
          "$ID" => id, "$Type" => "Security$UserRole",
          "Name" => role.fetch(:name).to_s,
          "Description" => role.fetch(:description, '').to_s,
          "CheckSecurity" => role.fetch(:check_security, true) == true,
          "GUID" => BSON::Binary.new(IO::BsonCodec.uuid_to_blob(guid)),
          "ManageableRoles" => IO::BsonCodec.build_array(
            Array(role[:manageable_roles]).map(&:to_s), marker: manageable.fetch(:marker)
          ),
          "ManageAllRoles" => role.fetch(:manage_all_roles, false) == true,
          "ManageUsersWithoutRoles" => role.fetch(:manage_users_without_roles, false) == true,
          "ModuleRoles" => IO::BsonCodec.build_array(
            declared_module_roles, marker: module_roles.fetch(:marker)
          )
        )
      end
      IO::BsonCodec.build_array(roles + opaque, marker: payload.fetch(:marker))
    end

    def ruby_project_role_guid(declaration, previous, role_id)
      declared = declaration[:guid].to_s
      validate_ruby_uuid!(declared, "project role GUID #{declaration.fetch(:name)}")
      prior = IO::BsonCodec.extract_id(previous["GUID"])
      if !declared.empty? && prior && declared != prior
        raise ValidationError,
              "native identity mismatch for project role GUID #{declaration.fetch(:name)}: " \
              "expected #{prior}, received #{declared}"
      end
      declared.empty? ? (prior || ruby_stable_uuid('project-role-guid', role_id)) : declared
    end

    def ruby_project_demo_users(declarations, previous)
      payload = IO::BsonCodec.parse_array(previous)
      supported, opaque = payload.fetch(:items).partition do |user|
        user.is_a?(Hash) && user["$Type"] == "Security$DemoUserImpl"
      end
      by_id = supported.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_name = supported.group_by { _1["UserName"].to_s }
      declarations = Array(declarations)
      validate_ruby_security_declarations!(declarations, "demo users")
      users = declarations.map do |user|
        user_id = user[:id].to_s
        matches = Array(by_name[user.fetch(:name).to_s])
        semantic_match = matches.one? ? matches.first : nil
        validate_ruby_nested_identity!(user_id, by_id, semantic_match, "demo user #{user.fetch(:name)}")
        prior = (!user_id.empty? && by_id[user_id]) || semantic_match || {}
        password = user[:password]
        if password.nil? && prior.empty?
          raise ValidationError, "new demo user #{user.fetch(:name)} requires an explicit password"
        end
        prior.merge(
          "$ID" => ruby_existing_or_stable_id(
            user_id, prior["$ID"], "demo user #{user.fetch(:name)}",
            'demo-user', user.fetch(:name)
          ),
          "$Type" => "Security$DemoUserImpl",
          "UserName" => user.fetch(:name).to_s,
          "Password" => password.nil? ? prior["Password"].to_s : password.to_s,
          "Entity" => user.fetch(:entity).to_s,
          "UserRoles" => IO::BsonCodec.build_array(
            Array(user[:roles]).map(&:to_s),
            marker: IO::BsonCodec.parse_array(prior["UserRoles"]).fetch(:marker)
          )
        )
      end
      IO::BsonCodec.build_array(users + opaque, marker: payload.fetch(:marker))
    end

    def ruby_password_policy_doc(declaration, previous, security_id)
      current = previous.is_a?(Hash) ? previous : {}
      id = ruby_existing_or_stable_id(
        declaration[:id], current["$ID"], "password policy",
        'password-policy', security_id
      )
      {
        "$ID" => id, "$Type" => "Security$PasswordPolicySettings"
      }.merge(
        current.reject { |key, _value| %w[$ID $Type].include?(key) }
      ).merge(declaration.fetch(:properties, {}).to_h.transform_keys(&:to_s))
    end

    def validate_ruby_security_declarations!(declarations, label)
      names = declarations.map { _1.fetch(:name).to_s }
      ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
      duplicates = names.tally.select { |_name, count| count > 1 }.keys +
                   ids.tally.select { |_id, count| count > 1 }.keys
      raise ValidationError, "duplicate #{label}: #{duplicates.join(', ')}" unless duplicates.empty?

      declarations.each do |declaration|
        raise ValidationError, "empty name in #{label}" if declaration.fetch(:name).to_s.empty?

        validate_ruby_uuid!(declaration[:id], "#{label} #{declaration.fetch(:name)}")
      end
    end

    def validate_ruby_scheduled_events!(module_name, declarations)
      validate_ruby_security_declarations!(declarations, "scheduled events in #{module_name}")
      declarations.each do |declaration|
        handler = declaration[:microflow].to_s
        raise ValidationError, "scheduled event #{module_name}.#{declaration.fetch(:name)} has no microflow" \
          if handler.empty?

        schedule = declaration[:schedule]
        raise ValidationError, "scheduled event #{module_name}.#{declaration.fetch(:name)} has no schedule" \
          unless schedule.is_a?(Hash)

        type = schedule[:type].to_s
        unless type.start_with?('ScheduledEvents$') && type.end_with?('Schedule')
          raise ValidationError, "unsupported scheduled event schedule #{type.inspect}"
        end
        validate_ruby_uuid!(schedule[:id], "schedule for #{module_name}.#{declaration.fetch(:name)}")
        Integer(declaration.fetch(:interval, 1))
      rescue ArgumentError, TypeError
        raise ValidationError, "invalid interval for scheduled event #{module_name}.#{declaration.fetch(:name)}"
      end
    end

    def ruby_scheduled_event_doc(declaration, previous, module_name)
      current = previous || {}
      id = ruby_existing_or_stable_id(
        declaration[:id], current["$ID"],
        "scheduled event #{module_name}.#{declaration.fetch(:name)}",
        'scheduled-event', module_name, declaration.fetch(:name)
      )
      schedule = declaration.fetch(:schedule)
      prior_schedule = current["Schedule"].is_a?(Hash) ? current["Schedule"] : {}
      schedule_id = ruby_existing_or_stable_id(
        schedule[:id], prior_schedule["$ID"],
        "schedule for #{module_name}.#{declaration.fetch(:name)}",
        'scheduled-event-schedule', id
      )
      start_at = declaration[:start_at]
      start_at = current["StartDateTime"] || Time.utc(2000, 1, 1) if start_at.to_s.empty?
      start_at = Time.parse(start_at.to_s).utc unless start_at.is_a?(Time)
      schedule_doc = {
        "$ID" => schedule_id, "$Type" => schedule.fetch(:type).to_s
      }.merge(
        prior_schedule.reject { |key, _value| %w[$ID $Type].include?(key) }
      ).merge(schedule.fetch(:properties, {}).to_h.transform_keys(&:to_s))
      current.merge(
        "$ID" => id, "$Type" => "ScheduledEvents$ScheduledEvent",
        "Name" => declaration.fetch(:name).to_s,
        "Documentation" => declaration.fetch(:documentation, '').to_s,
        "ExportLevel" => declaration.fetch(:export_level, 'Hidden').to_s,
        "Microflow" => declaration.fetch(:microflow).to_s,
        "StartDateTime" => start_at,
        "TimeZone" => declaration.fetch(:time_zone, 'UTC').to_s,
        "Schedule" => schedule_doc,
        "OnOverlap" => declaration.fetch(:on_overlap, 'SkipNext').to_s,
        "Enabled" => declaration.fetch(:enabled, true) == true,
        "IntervalType" => declaration.fetch(:interval_type, '').to_s,
        "Interval" => Integer(declaration.fetch(:interval, 1))
      )
    rescue ArgumentError
      raise ValidationError,
            "invalid start time for scheduled event #{module_name}.#{declaration.fetch(:name)}"
    end

    def ruby_existing_or_stable_id(declared, previous, label, *stable_parts)
      id = declared.to_s
      validate_ruby_uuid!(id, label)
      previous_id = IO::BsonCodec.extract_id(previous)
      if !id.empty? && previous_id && id != previous_id
        raise ValidationError,
              "native identity mismatch for #{label}: expected #{previous_id}, received #{id}"
      end
      id.empty? ? (previous_id || ruby_stable_uuid(*stable_parts)) : id
    end

    def lifecycle_signature(handler)
      "#{handler['Moment'].to_s.downcase}_#{handler['Event'].to_s.downcase}".to_sym
    end

    def ruby_lifecycle_doc(declaration, current, entity_name)
      previous = current || {}
      id = declaration[:id].to_s
      if id.empty?
        id = IO::BsonCodec.extract_id(previous["$ID"]) ||
             ruby_stable_uuid('lifecycle', entity_name, declaration.fetch(:event))
      end
      moment, event = declaration.fetch(:event).to_s.split('_', 2)
      previous.merge(
        "$ID" => id, "$Type" => "DomainModels$EventHandler",
        "Event" => event.capitalize, "Moment" => moment.capitalize,
        "Microflow" => declaration.fetch(:handler).to_s,
        "PassEventObject" => declaration.fetch(:pass_event_object, true) == true,
        "RaiseErrorOnFalse" => declaration.fetch(:raise_error_on_false, moment == 'before') == true
      )
    end

    def ruby_validation_rule_docs(declarations, previous, module_name, entity_name, attributes)
      payload = IO::BsonCodec.parse_array(previous)
      supported, opaque = payload.fetch(:items).partition do |rule|
        rule.is_a?(Hash) && rule["$Type"] == "DomainModels$ValidationRule"
      end
      by_id = supported.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_signature = supported.group_by { validation_rule_signature(_1) }
      declarations = Array(declarations)
      ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
      signatures = declarations.map { validation_declaration_signature(_1) }
      if ids.uniq.size != ids.size || signatures.uniq.size != signatures.size
        raise ValidationError, "duplicate validation rules for #{module_name}.#{entity_name}"
      end

      rules = declarations.map do |declaration|
        attribute = declaration.fetch(:attribute).to_s
        unless attributes.include?(attribute)
          raise ValidationError, "unknown validation attribute #{module_name}.#{entity_name}.#{attribute}"
        end

        id = declaration[:id].to_s
        validate_ruby_uuid!(id, "validation rule for #{module_name}.#{entity_name}.#{attribute}")
        matches = Array(by_signature[validation_declaration_signature(declaration)])
        semantic_match = matches.one? ? matches.first : nil
        validate_ruby_nested_identity!(id, by_id, semantic_match, "validation rule #{attribute}")
        current = (!id.empty? && by_id[id]) || semantic_match
        ruby_validation_rule_doc(declaration, current, module_name, entity_name)
      end
      IO::BsonCodec.build_array(rules + opaque, marker: payload.fetch(:marker))
    end

    def validation_rule_signature(rule)
      [rule["Attribute"].to_s.split('.').last, rule.dig("RuleInfo", "$Type").to_s]
    end

    def validation_declaration_signature(declaration)
      [declaration.fetch(:attribute).to_s, validation_rule_type(declaration.fetch(:kind))]
    end

    def validation_rule_type(kind)
      value = kind.to_s
      return "DomainModels$RequiredRuleInfo" if value.casecmp('required').zero?
      return "DomainModels$UniqueRuleInfo" if value.casecmp('unique').zero?
      return value if value.start_with?('DomainModels$') && value.end_with?('RuleInfo')

      raise ValidationError, "unsupported validation rule kind #{kind.inspect}"
    end

    def ruby_validation_rule_doc(declaration, current, module_name, entity_name)
      previous = current || {}
      id = ruby_nested_document_id(
        declaration[:id], previous["$ID"], "validation rule #{declaration.fetch(:attribute)}",
        fallback: ruby_stable_uuid(
          'validation-rule', module_name, entity_name, declaration.fetch(:attribute),
          validation_rule_type(declaration.fetch(:kind))
        )
      )
      {
        "$ID" => id, "$Type" => "DomainModels$ValidationRule",
        "Attribute" => "#{module_name}.#{entity_name}.#{declaration.fetch(:attribute)}",
        "Message" => ruby_validation_message_doc(declaration, previous["Message"], id),
        "RuleInfo" => ruby_validation_info_doc(declaration, previous["RuleInfo"], id)
      }
    end

    def ruby_validation_message_doc(declaration, current, rule_id)
      previous = current.is_a?(Hash) ? current : {}
      id = ruby_nested_document_id(
        declaration[:message_id], previous["$ID"], "validation rule message",
        fallback: ruby_stable_uuid('validation-message', rule_id)
      )
      payload = IO::BsonCodec.parse_array(previous["Items"])
      prior_items = payload.fetch(:items)
      by_id = prior_items.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_language = prior_items.group_by { _1["LanguageCode"].to_s }
      translations = Array(declaration[:translations]).map.with_index do |translation, index|
        translation_id = translation[:id].to_s
        validate_ruby_uuid!(translation_id, "validation translation")
        matches = Array(by_language[translation.fetch(:language_code).to_s])
        semantic_match = matches.one? ? matches.first : nil
        validate_ruby_nested_identity!(translation_id, by_id, semantic_match, "validation translation")
        {
          "$ID" => translation_id.empty? ?
            ruby_stable_uuid(
              'validation-translation', rule_id, translation.fetch(:language_code), index
            ) : translation_id,
          "$Type" => "Texts$Translation",
          "LanguageCode" => translation.fetch(:language_code).to_s,
          "Text" => translation.fetch(:text).to_s
        }
      end
      {
        "$ID" => id, "$Type" => "Texts$Text",
        "Items" => IO::BsonCodec.build_array(translations, marker: payload.fetch(:marker))
      }
    end

    def ruby_validation_info_doc(declaration, current, rule_id)
      previous = current.is_a?(Hash) ? current : {}
      id = ruby_nested_document_id(
        declaration[:rule_info_id], previous["$ID"], "validation rule info",
        fallback: ruby_stable_uuid('validation-info', rule_id)
      )
      declaration.fetch(:rule_info, {}).to_h.transform_keys(&:to_s).merge(
        "$ID" => id, "$Type" => validation_rule_type(declaration.fetch(:kind))
      )
    end

    def ruby_nested_document_id(declared, previous, label, fallback: nil)
      id = declared.to_s
      validate_ruby_uuid!(id, label)
      previous_id = IO::BsonCodec.extract_id(previous)
      if !id.empty? && previous_id && id != previous_id
        raise ValidationError,
              "native identity mismatch for #{label}: expected #{previous_id}, received #{id}"
      end
      id.empty? ? (fallback || previous_id || SecureRandom.uuid) : id
    end

    def ruby_stable_uuid(*parts)
      hex = Digest::SHA256.hexdigest(parts.map(&:to_s).join("\0"))[0, 32]
      hex[12] = '5'
      hex[16] = (8 + (hex[16].to_i(16) % 4)).to_s(16)
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
    end

    def validate_ruby_access_rules!(declarations, module_name, entity_name)
      ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
      duplicates = ids.tally.select { |_id, count| count > 1 }.keys
      unless duplicates.empty?
        raise ValidationError,
              "duplicate access rule ids for #{module_name}.#{entity_name}: #{duplicates.join(', ')}"
      end

      declarations.each do |rule|
        validate_ruby_uuid!(rule[:id], "access rule for #{module_name}.#{entity_name}")
        raise ValidationError, "access rule for #{module_name}.#{entity_name} has no roles" \
          if Array(rule[:roles]).empty?
        validate_access_right!(rule.fetch(:default_rights, :None), "default access")
        members = Array(rule[:members])
        member_ids = members.map { _1[:id].to_s }.reject(&:empty?)
        duplicate_member_ids = member_ids.tally.select { |_id, count| count > 1 }.keys
        references = members.map { access_member_declaration_signature(_1, module_name, entity_name) }
        duplicate_references = references.tally.select { |_key, count| count > 1 }.keys
        unless duplicate_member_ids.empty? && duplicate_references.empty?
          raise ValidationError,
                "duplicate access members for #{module_name}.#{entity_name}"
        end
        members.each do |member|
          validate_ruby_uuid!(member[:id], "access member for #{module_name}.#{entity_name}")
          validate_access_right!(member.fetch(:rights), "member access")
          kind = member.fetch(:kind, :attribute).to_sym
          next if ACCESS_MEMBER_KINDS.include?(kind)

          raise ValidationError, "unsupported access member kind #{kind.inspect}"
        end
      end
    end

    def validate_access_right!(value, label)
      right = value.to_sym
      return if ACCESS_RIGHTS.include?(right)

      raise ValidationError, "unsupported #{label} right #{right.inspect}"
    end

    def validate_ruby_nested_identity!(id, by_id, semantic_match, label)
      return if id.empty? || by_id.key?(id) || semantic_match.nil?

      previous_id = IO::BsonCodec.extract_id(semantic_match["$ID"])
      raise ValidationError,
            "native identity mismatch for #{label}: expected #{previous_id}, received #{id}"
    end

    def ruby_access_rule_doc(declaration, current, module_name, entity_name)
      previous = current || {}
      id = declaration[:id].to_s
      id = IO::BsonCodec.extract_id(previous["$ID"]) || SecureRandom.uuid if id.empty?
      roles_key = native_key(previous, "AllowedModuleRoles", "ModuleRoles")
      roles_payload = IO::BsonCodec.parse_array(previous[roles_key])
      previous_members = previous["MemberAccesses"]
      previous.merge(
        "$ID" => id,
        "$Type" => previous["$Type"] || "DomainModels$AccessRule",
        "Documentation" => declaration.fetch(:documentation, '').to_s,
        roles_key => IO::BsonCodec.build_array(
          Array(declaration.fetch(:roles)).map(&:to_s), marker: roles_payload.fetch(:marker)
        ),
        "AllowCreate" => declaration.fetch(:create, false) == true,
        "AllowDelete" => declaration.fetch(:delete, false) == true,
        "DefaultMemberAccessRights" => declaration.fetch(:default_rights, :None).to_s,
        "MemberAccesses" => ruby_access_member_docs(
          Array(declaration[:members]), previous_members, module_name, entity_name
        ),
        "XPathConstraint" => declaration.fetch(:xpath, '').to_s
      ).tap do |doc|
        caption = declaration[:xpath_caption]
        doc["XPathConstraintCaption"] = caption.to_s unless caption.nil?
      end
    end

    def ruby_access_member_docs(declarations, previous, module_name, entity_name)
      payload = IO::BsonCodec.parse_array(previous)
      supported, opaque = payload.fetch(:items).partition do |member|
        member.is_a?(Hash) && member["$Type"] == "DomainModels$MemberAccess"
      end
      by_id = supported.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
      by_reference = supported.to_h { [access_member_signature(_1), _1] }
      members = declarations.map do |declaration|
        id = declaration[:id].to_s
        signature = access_member_declaration_signature(declaration, module_name, entity_name)
        semantic_match = by_reference[signature]
        validate_ruby_nested_identity!(id, by_id, semantic_match, "access member #{signature.last}")
        current = (!id.empty? && by_id[id]) || semantic_match
        ruby_access_member_doc(declaration, current, module_name, entity_name)
      end
      IO::BsonCodec.build_array(members + opaque, marker: payload.fetch(:marker))
    end

    def ruby_access_member_doc(declaration, current, module_name, entity_name)
      previous = current || {}
      id = declaration[:id].to_s
      id = IO::BsonCodec.extract_id(previous["$ID"]) || SecureRandom.uuid if id.empty?
      kind, reference = access_member_declaration_signature(declaration, module_name, entity_name)
      previous.merge(
        "$ID" => id,
        "$Type" => previous["$Type"] || "DomainModels$MemberAccess",
        "Association" => kind == :association ? reference : "",
        "Attribute" => kind == :attribute ? reference : "",
        "AccessRights" => declaration.fetch(:rights).to_s
      )
    end

    def access_rule_signature(rule)
      roles = IO::BsonCodec.parse_array(rule["AllowedModuleRoles"] || rule["ModuleRoles"])[:items]
      [roles.map(&:to_s).sort, rule["XPathConstraint"].to_s]
    end

    def access_rule_declaration_signature(rule)
      [Array(rule[:roles]).map(&:to_s).sort, rule.fetch(:xpath, '').to_s]
    end

    def access_member_signature(member)
      association = member["Association"].to_s
      association.empty? ? [:attribute, member["Attribute"].to_s] : [:association, association]
    end

    def access_member_declaration_signature(member, module_name, entity_name)
      kind = member.fetch(:kind, :attribute).to_sym
      reference = member[:reference].to_s
      if reference.empty?
        name = member.fetch(:name).to_s
        reference = kind == :association ? "#{module_name}.#{name}" : "#{module_name}.#{entity_name}.#{name}"
      end
      [kind, reference]
    end

    def validate_ruby_constants!(module_name, declarations)
      duplicate_names = declarations.group_by { _1.fetch(:name).to_s }.select { |_key, values| values.size > 1 }.keys
      ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
      duplicate_ids = ids.tally.select { |_key, count| count > 1 }.keys
      unless duplicate_names.empty? && duplicate_ids.empty?
        details = []
        details << "names #{duplicate_names.join(', ')}" unless duplicate_names.empty?
        details << "ids #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?
        raise ValidationError, "duplicate Ruby constants in #{module_name}: #{details.join('; ')}"
      end

      declarations.each do |declaration|
        validate_ruby_uuid!(declaration[:id], "constant #{module_name}.#{declaration.fetch(:name)}")
        type = declaration.fetch(:type, :string).to_sym
        next if CONSTANT_TYPE_MAP.key?(type)

        raise ValidationError,
              "unsupported Ruby constant type #{type.inspect} for " \
              "#{module_name}.#{declaration.fetch(:name)}"
      end
    end

    def ruby_constant_doc(declaration, previous: nil, legacy: false)
      current = previous || {}
      id = declaration[:id].to_s
      id = IO::BsonCodec.extract_id(current["$ID"]) || SecureRandom.uuid if id.empty?
      type = declaration.fetch(:type, :string).to_sym
      default_value = ruby_constant_default(declaration, current)
      document = current.merge(
        "$ID" => id,
        "$Type" => current["$Type"] || "Constants$Constant",
        "Name" => declaration.fetch(:name).to_s,
        "Documentation" => declaration.fetch(:documentation, '').to_s,
        "Excluded" => declaration.fetch(:excluded, false) == true,
        "DefaultValue" => default_value
      )
      if legacy && !current.key?("Type")
        document["DataType"] = CONSTANT_TYPE_MAP.fetch(type).delete_prefix("DataTypes$").delete_suffix("Type")
      else
        previous_type = current["Type"].is_a?(Hash) ? current["Type"] : {}
        document["Type"] = previous_type.merge(
          "$ID" => IO::BsonCodec.extract_id(previous_type["$ID"]) || SecureRandom.uuid,
          "$Type" => CONSTANT_TYPE_MAP.fetch(type)
        )
        document["ExportLevel"] = declaration.fetch(:export_level, 'Hidden').to_s
        document["ExposedToClient"] = declaration.fetch(:exposed_to_client, false) == true
        document.delete("DataType") unless current.key?("DataType")
      end
      document
    end

    def ruby_constant_default(declaration, current)
      supplied = declaration.fetch(:default_supplied, false) == true
      requested_exposure = declaration.fetch(:exposed_to_client, false) == true
      previous_private = !current.empty? && current["ExposedToClient"] != true
      previous_value = current.fetch("DefaultValue", '').to_s
      if requested_exposure && previous_private && !supplied && !previous_value.empty?
        raise ValidationError,
              "cannot expose constant #{declaration.fetch(:name)} without an explicit safe default"
      end
      return declaration[:default_value].to_s if supplied
      return previous_value unless current.empty?

      ''
    end

    def validate_ruby_enumerations!(module_name, declarations)
      duplicate_names = declarations.group_by { _1.fetch(:name).to_s }.select { |_key, values| values.size > 1 }.keys
      ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
      duplicate_ids = ids.tally.select { |_key, count| count > 1 }.keys
      unless duplicate_names.empty? && duplicate_ids.empty?
        details = []
        details << "names #{duplicate_names.join(', ')}" unless duplicate_names.empty?
        details << "ids #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?
        raise ValidationError, "duplicate Ruby enumerations in #{module_name}: #{details.join('; ')}"
      end

      declarations.each do |declaration|
        validate_ruby_uuid!(declaration[:id], "enumeration #{module_name}.#{declaration.fetch(:name)}")
        values = Array(declaration[:values])
        duplicate_values = values.group_by { _1.fetch(:name).to_s }
                                 .select { |_key, entries| entries.size > 1 }.keys
        value_ids = values.map { _1[:id].to_s }.reject(&:empty?)
        duplicate_value_ids = value_ids.tally.select { |_key, count| count > 1 }.keys
        unless duplicate_values.empty? && duplicate_value_ids.empty?
          raise ValidationError,
                "duplicate values in #{module_name}.#{declaration.fetch(:name)}: " \
                "#{(duplicate_values + duplicate_value_ids).join(', ')}"
        end
        values.each do |value|
          validate_ruby_uuid!(value[:id], "enumeration value #{value.fetch(:name)}")
        end
      end
    end

    def validate_ruby_uuid!(value, label)
      id = value.to_s
      return if id.empty? || id.match?(IO::BsonCodec::UUID_PATTERN)

      raise ValidationError, "invalid native id for #{label}: #{id.inspect}"
    end

    def validate_ruby_identity!(id, by_id, named, label)
      return if id.empty? || by_id.key?(id) || named.nil?

      previous_id = IO::BsonCodec.extract_id(named.last["$ID"]) || named.first["UnitID"]
      raise ValidationError,
            "native identity mismatch for #{label}: expected #{previous_id}, received #{id}"
    end

    def ruby_enumeration_doc(declaration, previous: nil)
      current = previous || {}
      id = declaration[:id].to_s
      id = IO::BsonCodec.extract_id(current["$ID"]) || SecureRandom.uuid if id.empty?
      values_payload = IO::BsonCodec.parse_array(current["Values"])
      previous_values = values_payload.fetch(:items)
      by_id = previous_values.to_h do |value|
        [IO::BsonCodec.extract_id(value["$ID"]), value]
      end
      by_name = previous_values.to_h { [_1["Name"].to_s, _1] }
      values = Array(declaration[:values]).map do |value|
        value_id = value[:id].to_s
        named = by_name[value.fetch(:name).to_s]
        if !value_id.empty? && !by_id.key?(value_id) && named
          previous_id = IO::BsonCodec.extract_id(named["$ID"])
          raise ValidationError,
                "native identity mismatch for enumeration value #{value.fetch(:name)}: " \
                "expected #{previous_id}, received #{value_id}"
        end
        prior = (!value_id.empty? && by_id[value_id]) || named
        ruby_enumeration_value_doc(value, previous: prior)
      end

      current.merge(
        "$ID" => id,
        "$Type" => current["$Type"] || "Enumerations$Enumeration",
        "Name" => declaration.fetch(:name).to_s,
        "Documentation" => declaration.fetch(:documentation, '').to_s,
        "Excluded" => current.fetch("Excluded", false),
        "ExportLevel" => current.fetch("ExportLevel", "Hidden"),
        "Values" => IO::BsonCodec.build_array(values, marker: values_payload.fetch(:marker))
      )
    end

    def ruby_enumeration_value_doc(declaration, previous: nil)
      current = previous || {}
      id = declaration[:id].to_s
      id = IO::BsonCodec.extract_id(current["$ID"]) || SecureRandom.uuid if id.empty?
      current.merge(
        "$ID" => id,
        "$Type" => current["$Type"] || "Enumerations$EnumerationValue",
        "Name" => declaration.fetch(:name).to_s,
        "Caption" => ruby_enumeration_caption_doc(declaration, current["Caption"]),
        "Image" => current.fetch("Image", ""),
        "ExportLevel" => current.fetch("ExportLevel", "Hidden")
      )
    end

    def ruby_enumeration_caption_doc(declaration, previous)
      current = previous.is_a?(Hash) ? previous : {}
      items_payload = IO::BsonCodec.parse_array(current["Items"])
      previous_items = items_payload.fetch(:items)
      translations = previous_items.select { _1.is_a?(Hash) && !_1["LanguageCode"].to_s.empty? }
                                   .to_h { [_1["LanguageCode"].to_s, _1] }
      opaque_items = previous_items.reject { _1.is_a?(Hash) && !_1["LanguageCode"].to_s.empty? }
      captions = declaration.fetch(:captions, {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
      localized = captions.map do |language, text|
        prior = translations[language] || {}
        prior.merge(
          "$ID" => IO::BsonCodec.extract_id(prior["$ID"]) || SecureRandom.uuid,
          "$Type" => prior["$Type"] || "Texts$Translation",
          "LanguageCode" => language, "Text" => text
        )
      end
      current.merge(
        "$ID" => IO::BsonCodec.extract_id(current["$ID"]) || SecureRandom.uuid,
        "$Type" => current["$Type"] || "Texts$Text",
        "Items" => IO::BsonCodec.build_array(localized + opaque_items, marker: items_payload.fetch(:marker))
      )
    end

    def synchronize_ruby_domain_associations!(mpr, raw_domain, module_name, entities)
      doc = mpr.parse_contents(raw_domain)
      entities_key = native_key(doc, "entities", "Entities")
      associations_key = native_key(doc, "associations", "Associations")
      cross_key = native_key(doc, "crossAssociations", "CrossAssociations")
      entity_ids = array_items(doc[entities_key]).to_h do |entity|
        [entity["name"] || entity["Name"], IO::BsonCodec.extract_id(entity["$ID"])]
      end
      owned_ids = entities.filter_map { entity_ids[_1.fetch(:name)] }
      missing = entities.map { _1.fetch(:name) } - entity_ids.keys
      raise ValidationError, "entities missing from #{module_name}: #{missing.join(', ')}" unless missing.empty?

      local = array_items(doc[associations_key])
      cross = array_items(doc[cross_key])
      previous = (local + cross).to_h { [association_native_name(_1), _1] }
      local.reject! { owned_ids.include?(association_parent_id(_1)) }
      cross.reject! { owned_ids.include?(association_parent_id(_1)) }
      declared_names = []

      entities.each do |entity|
        from_id = entity_ids.fetch(entity.fetch(:name))
        Array(entity[:associations]).each do |association|
          name = association.fetch(:name)
          raise ValidationError, "duplicate Ruby association #{module_name}.#{name}" \
            if declared_names.include?(name)

          declared_names << name
          target_module, target_name = association_target(association.fetch(:target), module_name)
          prior = previous[name]
          association = association.merge(id: association[:id].to_s)
          prior = (prior || {}).merge('$ID' => association[:id]) unless association[:id].empty?
          if target_module == module_name
            to_id = entity_ids[target_name]
            raise ValidationError, "unknown association target #{association.fetch(:target).inspect}" unless to_id

            local << association_doc(
              association, from_id:, to_id:, previous: prior, oql_view: !entity[:oql_view].nil?
            )
          else
            cross << cross_association_doc(
              association, from_id:, target: "#{target_module}.#{target_name}", previous: prior,
              oql_view: !entity[:oql_view].nil?
            )
          end
        end
      end

      doc[associations_key] = IO::BsonCodec.build_array(local)
      doc[cross_key] = IO::BsonCodec.build_array(cross)
      mpr.transaction { mpr.update_unit(raw_domain.fetch("UnitID"), doc) }
    end

    def association_native_name(association)
      association["Name"] || association["name"]
    end

    def association_parent_id(association)
      IO::BsonCodec.extract_id(
        association["ParentPointer"] || association["ParentID"] || association["parentId"]
      )
    end

    def ruby_app_source_files
      path = @definition.fetch(:ruby_app_sources_path)
      manifest = JSON.parse(File.read(path))
      manifest.fetch("files").map do |file|
        relative = safe_asset_path(file.fetch("path"))
        contents = Base64.strict_decode64(file.fetch("contents"))
        checksum = Digest::SHA256.hexdigest(contents)
        raise SerializationError, "Ruby source checksum mismatch: #{relative}" \
          unless checksum == file.fetch("sha256")

        { path: relative, contents:, sha256: checksum, mode: file.fetch("mode", 0o644) }
      end
    rescue JSON::ParserError, KeyError, ArgumentError => e
      raise SerializationError, "invalid Ruby source manifest: #{e.message}"
    end

    def materialize_design_system
      design_system = @definition[:design_system]
      return unless design_system

      Model::DesignMaterializer.new(File.dirname(@path), design_system).materialize!
    end

    def project_asset_manifest
      assets = @definition[:project_assets]
      return unless assets

      JSON.parse(File.read(assets.fetch(:manifest)))
    end

    def materialize_project_assets(manifest)
      assets = @definition[:project_assets]
      return unless assets && manifest

      source_root = File.realpath(assets.fetch(:root))
      target_root = File.dirname(@path)
      manifest.fetch("files").each do |entry|
        temporary = nil
        relative = safe_asset_path(entry.fetch("path"))
        source = File.join(source_root, relative)
        target = File.join(target_root, relative)
        raise SerializationError, "project asset is missing: #{relative}" unless File.file?(source)
        raise SerializationError, "project asset checksum mismatch: #{relative}" unless
          Digest::SHA256.file(source).hexdigest == entry.fetch("sha256")
        next if File.expand_path(source) == File.expand_path(target)

        FileUtils.mkdir_p(File.dirname(target))
        temporary = "#{target}.mxrb-#{Process.pid}"
        FileUtils.cp(source, temporary)
        FileUtils.mv(temporary, target)
      ensure
        FileUtils.rm_f(temporary) if temporary
        @progress.advance(detail: "asset #{relative}") if defined?(relative) && relative
      end
    end

    def safe_asset_path(value)
      path = Pathname.new(value.to_s)
      clean = path.cleanpath.to_s
      if path.absolute? || clean == ".." || clean.start_with?("../")
        raise SerializationError, "unsafe project asset path: #{value}"
      end

      clean
    end

    def create_project!
      FileUtils.mkdir_p(File.dirname(@path))
      v2 = native_format_version == "v2"
      db = SQLite3::Database.new(@path)
      if v2
        db.execute(<<~SQL)
          CREATE TABLE _MetaData (
            _FormatVersion INTEGER, _ProductVersion TEXT,
            _BuildVersion TEXT, _SchemaHash TEXT
          )
        SQL
        db.execute(<<~SQL)
          CREATE TABLE Unit (
            UnitID BLOB PRIMARY KEY NOT NULL, ContainerID BLOB,
            ContainmentName TEXT, TreeConflict LONG,
            ContentsHash TEXT, ContentsConflicts TEXT
          )
        SQL
        db.execute(
          "INSERT INTO _MetaData VALUES (2, ?, ?, '')",
          [@definition.fetch(:version), @definition.fetch(:version)]
        )
      else
        db.execute("CREATE TABLE _MetaData (_ProductVersion TEXT, _BuildVersion TEXT, _SchemaHash TEXT)")
        db.execute(<<~SQL)
          CREATE TABLE Unit (
            UnitID BLOB PRIMARY KEY NOT NULL, ContainerID BLOB,
            ContainmentName TEXT, TreeConflict LONG,
            ContentsHash TEXT, ContentsConflicts TEXT, Contents BLOB
          )
        SQL
        db.execute(
          "INSERT INTO _MetaData VALUES (?, ?, '')",
          [@definition.fetch(:version), @definition.fetch(:version)]
        )
      end
      root_id = SecureRandom.uuid
      doc = {
        "$ID" => root_id,
        "$Type" => "Projects$Project",
        "IsSystemProject" => false
      }
      bytes = IO::BsonCodec.serialize(doc)
      blob = IO::BsonCodec.uuid_to_blob(root_id)
      contents_dir = File.join(File.dirname(@path), "mprcontents")
      FileUtils.mkdir_p(contents_dir) if v2
      if v2
        db.execute(
          "INSERT INTO Unit VALUES (?, ?, '', 0, ?, '')",
          [blob, blob, IO::BsonCodec.contents_hash(bytes)]
        )
      else
        db.execute(
          "INSERT INTO Unit VALUES (?, ?, '', 0, ?, '', ?)",
          [blob, blob, IO::BsonCodec.contents_hash(bytes), bytes]
        )
      end
      IO::MxunitCodec.write_atomic(IO::MxunitCodec.path_for(contents_dir, root_id), bytes) if v2
    ensure
      db&.close
    end

    def native_format_version
      native_manifest&.fetch("format_version", nil)
    end

    def native_manifest
      return @native_manifest if defined?(@native_manifest)

      path = @definition[:native_units_path]
      @native_manifest = if path.to_s.empty? || !File.file?(path)
                           nil
                         else
                           JSON.parse(File.read(path))
                         end
    end

    def validate_native_output_filename!
      manifest = native_manifest
      return unless manifest&.fetch("format_version", nil) == "v2"

      expected = manifest.fetch("source_filename", "").to_s
      return if expected.empty? || File.basename(@path) == expected

      raise ValidationError,
            "Mendix v2 mprcontents belong to #{expected}; " \
            "refusing incompatible output filename #{File.basename(@path)}"
    end

    def apply(mpr, native_units)
      root = mpr.root_unit
      root_id = root.fetch("UnitID")
      root_doc = mpr.parse_contents(root)
      root_doc = {
        "$ID" => root_doc["$ID"] || root_id,
        "$Type" => "Projects$Project",
        "IsSystemProject" => false
      }
      mpr.update_unit(root_id, root_doc)
      apply_native_project_units(mpr, root_id, native_units)
      apply_default_project_units(mpr, root_id)
      ensure_project_documents(mpr, root_id)
      @definition.fetch(:modules).each_with_index do |mod, index|
        raw_module = find_named(mpr, "Modules", root_id, mod.fetch(:name))
        existing_module = raw_module ? mpr.parse_contents(raw_module) : native_module_doc(native_units, mod.fetch(:name))
        module_doc = module_doc(mod.fetch(:name), index, previous: existing_module)
        module_id = raw_module&.fetch("UnitID") || mpr.insert_unit(
          container_uuid: root_id,
          containment_name: "Modules",
          contents_doc: module_doc
        )

        mpr.update_unit(module_id, module_doc) if raw_module
        apply_native_module_units(mpr, module_id, mod.fetch(:name), native_units)
        write_native_documents(mpr, module_id, mod)
        write_module_security(mpr, module_id, mod) if mod.key?(:module_roles)
        write_domain_model(mpr, module_id, mod)
        write_documents(mpr, module_id, mod)
        @progress.advance(detail: "module #{mod.fetch(:name)}")
      end
      write_project_security(mpr, root_id, @definition[:security]) if @definition[:security]
      write_project_navigation(mpr, root_id, @definition[:navigation]) if @definition[:navigation]
      @progress.advance(detail: "project security and navigation")
    end

    def prepared_native_units
      apply_native_unit_overrides(
        load_native_units(@definition[:native_units_path]),
        @definition.fetch(:native_unit_overrides, [])
      )
    end

    def load_native_units(path)
      return [] if path.to_s.empty? || !File.file?(path)

      JSON.parse(File.read(path)).fetch("units", []).map do |unit|
        unit.merge("doc" => IO::BsonCodec.parse(Base64.strict_decode64(unit.fetch("contents"))))
      end
    end

    def apply_native_unit_overrides(native_units, overrides)
      by_id = native_units.to_h { [_1["unit_id"], _1] }
      overrides.each do |override|
        attributes = override.transform_keys(&:to_s)
        unit_id = attributes.fetch("unit_id")
        current = by_id[unit_id]
        replacement = (current || {}).merge(attributes)
        replacement["name"] =
          replacement.fetch("doc")["Name"] || replacement.fetch("doc")["name"] || ""
        replacement["type"] = replacement.fetch("doc")["$Type"]
        if current
          current.replace(replacement)
        else
          native_units << replacement
          by_id[unit_id] = replacement
        end
      end
      native_units
    end

    def apply_native_project_units(mpr, root_id, native_units)
      units = native_units.select { _1["module"].nil? && _1["containment"] != "Modules" }
      apply_native_unit_tree(mpr, root_id, units)
    end

    def ensure_project_documents(mpr, root_id)
      documents = [
        ['ProjectDocuments', modern_navigation_doc({}, profiles: [])],
        ['ProjectDocuments', project_security_doc({})]
      ]
      existing_types = mpr.children_of(root_id).map { mpr.parse_contents(_1)['$Type'] }
      documents.each do |containment, doc|
        next if existing_types.include?(doc.fetch('$Type'))

        mpr.insert_unit(container_uuid: root_id, containment_name: containment, contents_doc: doc)
      end
      security_unit = mpr.children_of(root_id).find do |unit|
        mpr.parse_contents(unit)['$Type'] == 'Security$ProjectSecurity'
      end
      return unless security_unit &&
                    array_items(mpr.parse_contents(security_unit)['UserRoles']).empty?

      write_project_security(mpr, root_id, {})
    end

    def apply_default_project_units(mpr, root_id)
      path = File.join(__dir__, 'templates', 'project', "#{@definition.fetch(:version)}.json")
      return unless File.file?(path)

      existing = mpr.children_of(root_id).map { mpr.parse_contents(_1)['$Type'] }
      units = load_native_units(path).reject { existing.include?(_1.fetch('type')) }
      units.each do |unit|
        case unit.fetch('type')
        when 'Settings$ProjectSettings'
          sanitize_project_settings!(unit.fetch('doc'))
        when 'Navigation$NavigationDocument'
          sanitize_project_navigation!(unit.fetch('doc'))
        end
      end
      apply_native_unit_tree(mpr, root_id, units)
    end

    def sanitize_project_navigation!(document)
      profiles = array_items(document['Profiles'])
      profiles += LEGACY_NAVIGATION_PROFILES.values.filter_map { document[_1] }
      profiles.each do |profile|
        # Icons stored in a donor project refer to image collections that are
        # not part of a structural project template. The Ruby navigation DSL
        # may set a new icon explicitly after the clean seed is installed.
        profile['AppIcon'] = '' if profile.key?('AppIcon')
      end
      document
    end

    def sanitize_project_settings!(document)
      array_items(document['Settings']).each do |setting|
        case setting['$Type']
        when 'Forms$WebUIProjectSettingsPart'
          setting['EnableNewStringBehavior'] = true
          setting['UseOptimizedClient'] = 'Yes' if @definition.fetch(:version).to_i == 10
          setting['ThemeModuleName'] = '' if setting.key?('ThemeModuleName')
        when 'Settings$ModelSettings'
          # A project template is structural seed data, not an application
          # baseline. Lifecycle callbacks from the donor project must never
          # leak into a standalone Ruby-first project.
          %w[AfterStartupMicroflow BeforeShutdownMicroflow HealthCheckMicroflow].each do |key|
            setting[key] = '' if setting.key?(key)
          end
        when 'Settings$LanguageSettings'
          default = setting['DefaultLanguageCode'].to_s
          array_items(setting['Languages']).each do |language|
            next if language['Code'].to_s == default

            language['CheckCompleteness'] = false
          end
        end
      end
      document
    end

    def native_module_doc(native_units, module_name)
      native_units.find do |unit|
        unit["containment"] == "Modules" &&
          (unit.dig("doc", "Name") || unit["name"]) == module_name
      end&.fetch("doc", nil)
    end

    def apply_native_module_units(mpr, module_id, module_name, native_units)
      units = native_units.select { _1["module"] == module_name }
      apply_native_unit_tree(mpr, module_id, units)
    end

    def write_native_documents(mpr, module_id, mod)
      retained = []
      mod.fetch(:native_documents, []).each do |document|
        doc = document.fetch(:doc)
        doc = legacy_layout_doc(doc) if doc['$Type'] == 'Forms$Layout' && legacy_layout?
        existing = mpr.unit(document[:unit_id]) if document[:unit_id]
        if existing
          current = mpr.parse_contents(existing)
          preserved = current.merge(doc).merge(
            '$ID' => current['$ID'] || existing.fetch('UnitID'),
            '$Type' => doc['$Type'] || doc[:'$Type'] || document.fetch(:type)
          )
          mpr.update_unit(existing.fetch('UnitID'), preserved)
          retained << existing.fetch('UnitID')
          next
        end

        requested_container = document[:container_id]
        target_container = requested_container && mpr.unit(requested_container) ? requested_container : module_id
        retained << upsert_native_unit(
          mpr, target_container,
          'containment' => document.fetch(:containment), 'doc' => doc
        )
      end

      managed = mod.fetch(:managed_native_document_types, []).map(&:to_s)
      return if managed.empty?

      declared = mod.fetch(:native_documents, []).to_h do |document|
        [[document.fetch(:type).to_s, document.fetch(:name).to_s], true]
      end
      collect_documents(mpr, module_id).each do |raw|
        document = mpr.parse_contents(raw)
        next unless managed.include?(document['$Type'].to_s)
        next if retained.include?(raw.fetch('UnitID'))
        next if declared[[document['$Type'].to_s, document['Name'].to_s]]

        mpr.delete_unit(raw.fetch('UnitID'))
      end
    end

    def legacy_layout?
      @definition.fetch(:version).to_i < 9
    end

    def legacy_layout_doc(source)
      placeholder = {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Placeholder',
        'Class' => '', 'Name' => 'Main', 'Style' => '', 'TabIndex' => 0
      }
      common = {
        '$ID' => source['$ID'] || SecureRandom.uuid, '$Type' => 'Forms$Layout',
        'CanvasHeight' => source.fetch('CanvasHeight', 600),
        'CanvasWidth' => source.fetch('CanvasWidth', 800),
        'Class' => source.dig('Appearance', 'Class').to_s,
        'Documentation' => source.fetch('Documentation', ''), 'Excluded' => false,
        'FormCall' => nil, 'LayoutType' => 'Responsive', 'Name' => source.fetch('Name'),
        'Style' => source.dig('Appearance', 'Style').to_s
      }
      return common.merge('Widgets' => IO::BsonCodec.build_array([placeholder], marker: 2)) \
        unless oldest_layout_contract?

      common.merge(
        'AcceptPlaceholderName' => '', 'CancelPlaceholderName' => '',
        'MainPlaceholderName' => 'Main', 'UseMainPlaceholderForPopups' => false,
        'Widget' => placeholder
      )
    end

    def oldest_layout_contract?
      major, minor = @definition.fetch(:version).split('.').map(&:to_i)
      major < 7 || (major == 7 && minor < 17)
    end

    def apply_native_unit_tree(mpr, target_root_id, units)
      if units.any? { _1["unit_id"].to_s.empty? || _1["container_id"].to_s.empty? }
        units.each do |unit|
          upsert_native_unit(mpr, target_root_id, unit)
          @progress.advance(detail: "native unit #{unit['name']}")
        end
        return
      end

      source_ids = units.map { _1.fetch("unit_id") }.to_h { [_1, true] }
      external_parents = units.map { _1.fetch("container_id") }.reject { source_ids.key?(_1) }.uniq
      mapped_containers = external_parents.to_h { [_1, target_root_id] }
      pending = units.dup

      until pending.empty?
        ready, blocked = pending.partition { mapped_containers.key?(_1.fetch("container_id")) }
        raise SerializationError, "native unit tree contains an unresolved container cycle" if ready.empty?

        ready.each do |unit|
          target_container = mapped_containers.fetch(unit.fetch("container_id"))
          actual_id = upsert_native_unit(mpr, target_container, unit)
          mapped_containers[unit.fetch("unit_id")] = actual_id
          @progress.advance(detail: "native unit #{unit['name']}")
        end
        pending = blocked
      end
    end

    def upsert_native_unit(mpr, container_id, unit)
      doc = unit.fetch("doc")
      name = doc["Name"] || doc["name"]
      requested_id = unit["unit_id"].to_s
      requested_id = nil if requested_id.empty?
      stable = mpr.unit(requested_id) if requested_id
      existing = stable if stable && mpr.parse_contents(stable)["$Type"] == doc["$Type"]
      candidates = mpr.children_of(container_id)
      existing ||= if name.to_s.empty?
                     candidates.find { mpr.parse_contents(_1)["$Type"] == doc["$Type"] }
                   else
                     candidates.find do |raw|
                       existing_doc = mpr.parse_contents(raw)
                       (existing_doc["Name"] || existing_doc["name"]) == name &&
                         existing_doc["$Type"] == doc["$Type"]
                     end
                   end
      if existing
        current = mpr.parse_contents(existing)
        preserved = {
          "$ID" => current["$ID"] || existing.fetch("UnitID"),
          "$Type" => doc["$Type"]
        }.merge(current).merge(doc)
        preserved["$ID"] = current["$ID"] || existing.fetch("UnitID") unless existing.equal?(stable)
        mpr.update_unit(existing.fetch("UnitID"), preserved)
        existing.fetch("UnitID")
      else
        containment = unit.fetch("containment")
        inserted_id = stable ? SecureRandom.uuid : requested_id
        inserted_doc = stable ? doc.merge("$ID" => inserted_id) : doc
        mpr.insert_unit(
          container_uuid: container_id,
          containment_name: containment,
          contents_doc: inserted_doc,
          unit_uuid: inserted_id
        )
      end
    end

    def write_native_compatibility(mpr, native_units)
      mismatches = native_units.filter_map do |unit|
        unit_id = unit["unit_id"].to_s
        doc = unit.fetch("doc")
        content_id = IO::BsonCodec.extract_id(doc["$ID"]).to_s
        next if unit_id.empty? || content_id.empty? || unit_id == content_id

        raw = mpr.unit(unit_id)
        next unless raw

        written = mpr.parse_contents(raw)
        written_id = IO::BsonCodec.extract_id(written["$ID"]).to_s
        next unless written_id == content_id && written["$Type"] == doc["$Type"]

        { unit_id: unit_id, content_id: content_id, type: doc["$Type"] }
      end
      mpr.write_legacy_unit_identity_mismatches(mismatches)
    end

    def write_project_security(mpr, root_id, security)
      raw = mpr.children_of(root_id).find do |unit|
        unit["ContainmentName"] == "ProjectDocuments" &&
          mpr.parse_contents(unit)["$Type"] == "Security$ProjectSecurity"
      end
      doc = project_security_doc(security)
      if raw
        existing = mpr.parse_contents(raw)
        # The native manifest remains authoritative for security properties
        # that are not modeled by the Ruby DSL yet. Only replace the editable
        # role collection and explicitly declared security level.
        editable = {
          "UserRoles" => doc.fetch("UserRoles"),
          "AdminUserRole" => doc.fetch("AdminUserRole")
        }
        if existing.key?("UserRoles") && array_items(existing["UserRoles"]).empty?
          # Project templates may contain demo users for modules and roles that
          # are intentionally not copied into a new Ruby-first project. Once
          # the empty role set is bootstrapped, those references must be
          # removed as one atomic security repair.
          editable["DemoUsers"] = doc.fetch("DemoUsers")
          editable["EnableDemoUsers"] = doc.fetch("EnableDemoUsers")
          editable["SecurityLevel"] = doc.fetch("SecurityLevel")
        end
        if security[:security_level]
          editable["SecurityLevel"] = doc.fetch("SecurityLevel")
        end
        {
          demo_users_enabled: "EnableDemoUsers",
          demo_users: "DemoUsers",
          guest_access_enabled: "EnableGuestAccess",
          guest_user_role: "GuestUserRole",
          sign_in_microflow: "SignInMicroflow",
          password_policy: "PasswordPolicySettings"
        }.each do |definition_key, native_key|
          editable[native_key] = doc.fetch(native_key) unless security[definition_key].nil?
        end
        doc = existing.merge(editable)
        doc["$ID"] = existing["$ID"] || raw.fetch("UnitID")
        mpr.update_unit(raw.fetch("UnitID"), doc)
      else
        mpr.insert_unit(container_uuid: root_id, containment_name: "ProjectDocuments", contents_doc: doc)
      end
    end

    def write_project_navigation(mpr, root_id, navigation)
      raw = mpr.children_of(root_id).find do |unit|
        mpr.parse_contents(unit)["$Type"] == "Navigation$NavigationDocument"
      end
      existing = raw ? mpr.parse_contents(raw) : {}
      doc = if legacy_navigation?(existing)
              legacy_navigation_doc(existing, navigation)
            else
              modern_navigation_doc(existing, navigation)
            end
      if raw
        mpr.update_unit(raw.fetch("UnitID"), doc)
      else
        mpr.insert_unit(
          container_uuid: root_id, containment_name: "ProjectDocuments", contents_doc: doc
        )
      end
    end

    def legacy_navigation?(document)
      !document.key?("Profiles") &&
        LEGACY_NAVIGATION_PROFILES.values.any? { document[_1].is_a?(Hash) }
    end

    def legacy_navigation_doc(existing, navigation)
      navigation.fetch(:profiles, []).each_with_object(existing.dup) do |profile, document|
        name = profile.fetch(:name).to_s
        name = 'Desktop' if name == 'Responsive'
        key = LEGACY_NAVIGATION_PROFILES.fetch(name)
        document[key] = legacy_navigation_profile_doc(profile, previous: existing[key])
      end
    end

    def legacy_navigation_profile_doc(profile, previous:)
      previous ||= {}
      role_homes = profile.fetch(:role_homes, {}).map do |role, page|
        { role: role.to_s, page: page.to_s }
      end + profile.fetch(:role_home_details, [])
      title = profile.fetch(:app_title, {})
      title = title.values.first.to_s if title.is_a?(Hash)
      editable = {
        'HomePage' => navigation_home_doc(profile[:home_page], profile[:home_microflow]),
        'HomeItems' => IO::BsonCodec.build_array(role_homes.map { navigation_role_home_doc(_1) }, marker: 2),
        'Menu' => navigation_menu_doc(profile.fetch(:items, [])),
        'Enabled' => true,
        'ApplicationTitle' => title.to_s.empty? ? previous.fetch('ApplicationTitle', 'Mendix') : title.to_s
      }
      editable['Kind'] = profile[:kind].to_s unless profile[:kind].to_s.empty?
      previous.merge(editable)
    end

    def modern_navigation_doc(existing, navigation)
      existing_profiles = array_items(existing["Profiles"]).to_h { [_1["Name"].to_s, _1] }
      profiles = navigation.fetch(:profiles, []).map do |profile|
        navigation_profile_doc(profile, previous: existing_profiles[profile.fetch(:name).to_s])
      end
      existing.merge(
        "$ID" => existing["$ID"] || SecureRandom.uuid,
        "$Type" => "Navigation$NavigationDocument",
        "Profiles" => IO::BsonCodec.build_array(profiles, marker: 2)
      )
    end

    def navigation_profile_doc(profile, previous: nil)
      previous ||= {}
      role_homes = profile.fetch(:role_homes, {}).map do |role, page|
        { role: role.to_s, page: page.to_s }
      end + profile.fetch(:role_home_details, [])
      editable = {
        "Name" => profile.fetch(:name).to_s,
        "HomePage" => navigation_home_doc(profile[:home_page], profile[:home_microflow]),
        "HomeItems" => IO::BsonCodec.build_array(role_homes.map { navigation_role_home_doc(_1) }),
        "Menu" => navigation_menu_doc(profile.fetch(:items, [])),
        "OfflineEntityConfigs" => IO::BsonCodec.build_array([], marker: 3),
        "ProgressiveWebAppSettings" => nil,
        "NotFoundHomepage" => nil,
        "ThrowPartialSyncError" => true
      }
      if !profile[:kind].to_s.empty?
        editable["Kind"] = profile[:kind]
      elsif profile[:offline]
        editable["Kind"] = "Offline"
      elsif previous.empty?
        editable["Kind"] = "Responsive"
      end
      editable["AppIcon"] = profile[:app_icon] unless profile[:app_icon].nil?
      unless profile.fetch(:app_title, {}).empty?
        editable["AppTitle"] = translated_text_doc(profile.fetch(:app_title))
      end
      if profile[:sign_in_page]
        editable["LoginPageSettings"] = {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$FormSettings",
          "Form" => profile.fetch(:sign_in_page),
          "ParameterMappings" => IO::BsonCodec.build_array([], marker: 2),
          "TitleOverride" => nil
        }
      elsif previous.empty?
        editable["LoginPageSettings"] = {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$FormSettings",
          "Form" => "",
          "ParameterMappings" => IO::BsonCodec.build_array([], marker: 2),
          "TitleOverride" => nil
        }
      end
      {
        "$ID" => previous["$ID"] || SecureRandom.uuid,
        "$Type" => previous["$Type"] || "Navigation$NavigationProfile"
      }.merge(previous).merge(editable)
    end

    def navigation_home_doc(page, microflow)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Navigation$HomePage",
        "Microflow" => microflow.to_s,
        "Page" => page.to_s
      }
    end

    def navigation_role_home_doc(home)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Navigation$RoleBasedHomePage",
        "UserRole" => home.fetch(:role).to_s,
        "Page" => home[:page].to_s,
        "Microflow" => home[:microflow].to_s
      }
    end

    def navigation_menu_doc(items)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Menus$MenuItemCollection",
        "Items" => IO::BsonCodec.build_array(items.map { navigation_menu_item_doc(_1) })
      }
    end

    def navigation_menu_item_doc(item)
      action = if item[:page]
                 form_action_doc(item.fetch(:page))
               elsif item[:microflow]
                 navigation_microflow_action_doc(item.fetch(:microflow))
               else
                 { "$ID" => SecureRandom.uuid, "$Type" => "Forms$NoAction" }
               end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Menus$MenuItem",
        "Caption" => translated_text_doc(item.fetch(:caption)),
        "Action" => action,
        "Icon" => glyph_icon_doc(item[:icon]),
        "Items" => IO::BsonCodec.build_array(
          item.fetch(:items, []).map { navigation_menu_item_doc(_1) }
        )
      }
    end

    def glyph_icon_doc(icon)
      return unless icon

      code = icon.is_a?(Integer) ? icon : GLYPH_ICON_CODES[icon.to_s.downcase]
      raise ArgumentError, "unsupported navigation icon #{icon.inspect}" unless code

      { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$GlyphIcon', 'Code' => code }
    end

    def navigation_microflow_action_doc(microflow)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$MicroflowAction",
        "MicroflowSettings" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$MicroflowSettings",
          "Microflow" => microflow
        }
      }
    end

    def translated_text_doc(translations)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Texts$Text",
        "Items" => IO::BsonCodec.build_array(translations.map do |locale, value|
          {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Texts$Translation",
            "LanguageCode" => locale.to_s,
            "Text" => value.to_s
          }
        end)
      }
    end

    def write_module_security(mpr, module_id, mod)
      raw = mpr.children_of(module_id).find { _1["ContainmentName"] == "ModuleSecurity" }
      return if raw.nil? && mod.fetch(:module_roles, []).empty? && @definition.fetch(:version).to_i >= 10

      doc = module_security_doc(
        mod.fetch(:module_roles, []), legacy: @definition.fetch(:version).to_i < 10
      )
      if raw
        existing = mpr.parse_contents(raw)
        existing_roles = IO::BsonCodec.parse_array(existing["ModuleRoles"])
        generated_roles = IO::BsonCodec.parse_array(doc["ModuleRoles"])
        doc["ModuleRoles"] = IO::BsonCodec.build_array(
          generated_roles.fetch(:items), marker: existing_roles.fetch(:marker)
        )
        doc = existing.merge(doc)
        doc["$ID"] = existing["$ID"] || raw.fetch("UnitID")
        mpr.update_unit(raw.fetch("UnitID"), doc)
      else
        mpr.insert_unit(container_uuid: module_id, containment_name: "ModuleSecurity", contents_doc: doc)
      end
    end

    def write_domain_model(mpr, module_id, mod)
      raw = mpr.units_by_containment("DomainModel").find { _1["ContainerID"] == module_id }
      existing = raw ? mpr.parse_contents(raw) : {}
      entities_key = native_key(existing, "entities", "Entities")
      associations_key = native_key(existing, "associations", "Associations")
      cross_associations_key = native_key(existing, "crossAssociations", "CrossAssociations")
      annotations_key = native_key(existing, "annotations", "Annotations")
      existing_entities = array_items(existing[entities_key]).to_h do |entity|
        [entity["name"] || entity["Name"], entity]
      end

      access_associations = association_access_by_entity(mod)
      entities = mod.fetch(:entities).map.with_index do |entity, index|
        entity_doc(
          entity, mod.fetch(:name), existing_entities[entity.fetch(:name)], index,
          access_associations: access_associations.fetch(entity.fetch(:name), [])
        )
      end
      entity_ids = entities.to_h do |entity|
        [entity['name'] || entity.fetch('Name'), entity.fetch('$ID')]
      end
      @all_entity_ids ||= {}
      entity_ids.each { |name, id| @all_entity_ids["#{mod.fetch(:name)}.#{name}"] = id }
      existing_associations = array_items(existing[associations_key]).to_h do |association|
        [association["Name"], association]
      end
      existing_cross_associations = array_items(existing[cross_associations_key]).to_h do |association|
        [association["Name"], association]
      end
      associations = existing_associations.values
      cross_associations = existing_cross_associations.values
      mod.fetch(:entities).flat_map do |entity|
        entity.fetch(:associations, []).map do |association|
          target_module, target_name = association_target(association.fetch(:target), mod.fetch(:name))
          if target_module == mod.fetch(:name)
            generated = association_doc(
              association,
              from_id: entity_ids.fetch(entity.fetch(:name)),
              to_id: entity_ids.fetch(target_name) {
                raise ArgumentError, "unknown association target #{association.fetch(:target).inspect}"
              },
              previous: existing_associations[association.fetch(:name)],
              oql_view: !entity[:oql_view].nil?
            )
            associations = associations.reject { _1["Name"] == generated["Name"] } + [generated]
            cross_associations = cross_associations.reject { _1["Name"] == generated["Name"] }
          else
            generated = cross_association_doc(
              association,
              from_id: entity_ids.fetch(entity.fetch(:name)),
              target: "#{target_module}.#{target_name}",
              previous: existing_cross_associations[association.fetch(:name)],
              oql_view: !entity[:oql_view].nil?
            )
            cross_associations = cross_associations.reject { _1["Name"] == generated["Name"] } + [generated]
            associations = associations.reject { _1["Name"] == generated["Name"] }
          end
        end
      end

      doc = existing.merge(
        "$ID" => raw&.fetch("UnitID", nil) || SecureRandom.uuid,
        "$Type" => "DomainModels$DomainModel",
        "Documentation" => existing.fetch("Documentation", "")
      )
      doc[entities_key] = IO::BsonCodec.build_array(entities)
      doc[associations_key] = IO::BsonCodec.build_array(associations)
      doc[cross_associations_key] = IO::BsonCodec.build_array(cross_associations)
      doc[annotations_key] ||= IO::BsonCodec.build_array([])

      if raw
        mpr.update_unit(raw.fetch("UnitID"), doc)
      else
        mpr.insert_unit(container_uuid: module_id, containment_name: "DomainModel", contents_doc: doc)
      end
    end

    def association_target(target, default_module)
      value = target.to_s
      value.include?('.') ? value.split('.', 2) : [default_module, value]
    end

    def association_access_by_entity(mod)
      module_name = mod.fetch(:name)
      mod.fetch(:entities).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |entity, result|
        entity.fetch(:associations, []).each do |association|
          result[entity.fetch(:name)] << association.fetch(:name)
          next unless association.fetch(:owner, :Default).to_sym == :Both &&
                      association.fetch(:type).to_sym == :Reference

          target_module, target_name = association.fetch(:target).split('.', 2)
          result[target_name] << association.fetch(:name) if target_module == module_name
        end
      end
    end

    def write_documents(mpr, module_id, mod)
      existing = documents_by_name(mpr, module_id)

      mod.fetch(:pages).each do |page|
        upsert_document(
          mpr, module_id, existing[page.fetch(:name)], page_doc(page, mod.fetch(:name))
        )
      end
      mod.fetch(:microflows).each do |flow|
        upsert_document(
          mpr, module_id, existing[flow.fetch(:name)],
          microflow_doc(flow, mod.fetch(:name))
        )
      end
      mod.fetch(:nanoflows, []).each do |flow|
        upsert_document(mpr, module_id, existing[flow.fetch(:name)], nanoflow_doc(flow))
      end
      mod.fetch(:menus, []).each do |menu|
        upsert_document(mpr, module_id, existing[menu.fetch(:name)], menu_doc(menu))
      end
      mod.fetch(:enumerations, []).each do |enum|
        upsert_document(mpr, module_id, existing[enum.fetch(:name)], enumeration_doc(enum))
      end
      mod.fetch(:constants, []).each do |constant|
        upsert_document(mpr, module_id, existing[constant.fetch(:name)], constant_doc(constant))
      end
      mod.fetch(:scheduled_events, []).each do |event|
        upsert_document(mpr, module_id, existing[event.fetch(:name)], scheduled_event_doc(event))
      end
    end

    def upsert_document(mpr, module_id, candidates, doc)
      requested_unit_id = doc.delete("__mxrb_unit_id").to_s
      raw = Array(candidates).find do |candidate|
        mpr.parse_contents(candidate)["$Type"] == doc["$Type"]
      end
      if raw
        existing = mpr.parse_contents(raw)
        doc = merge_existing_document(existing, doc)
        strip_internal_keys(doc)
        doc["$ID"] = existing["$ID"] || raw.fetch("UnitID")
        doc["$Type"] = existing["$Type"] || doc["$Type"]
        mpr.update_unit(raw.fetch("UnitID"), doc)
      else
        strip_internal_keys(doc)
        unit_id = requested_unit_id.empty? ? nil : requested_unit_id
        doc["$ID"] = unit_id if unit_id
        mpr.insert_unit(
          container_uuid: module_id, containment_name: "Documents",
          contents_doc: doc, unit_uuid: unit_id
        )
      end
    end

    def synchronize_ruby_navigation!(mpr, root_id, declarations)
      Array(declarations).each do |declaration|
        synchronize_ruby_navigation_item!(mpr, root_id, declaration)
      end
    end

    def synchronize_ruby_navigation_item!(mpr, root_id, declaration)
      raw = mpr.children_of(root_id).find do |unit|
        mpr.parse_contents(unit)["$Type"] == "Navigation$NavigationDocument"
      end
      raise ValidationError, "Mendix navigation document does not exist" unless raw

      document = mpr.parse_contents(raw)
      profile = ruby_navigation_profile(document, declaration.fetch(:profile).to_s)
      raise ValidationError, "Mendix navigation profile #{declaration.fetch(:profile)} does not exist" unless profile

      menu = profile["Menu"] || profile["MenuItemCollection"]
      raise ValidationError, "navigation profile #{declaration.fetch(:profile)} has no menu" unless menu

      parsed = IO::BsonCodec.parse_array(menu["Items"])
      items = parsed.fetch(:items)
      generated = navigation_menu_item_doc(
        caption: normalize_navigation_caption(declaration.fetch(:caption)),
        page: declaration.fetch(:page), icon: declaration[:icon], items: []
      )
      index = items.index { ruby_navigation_page(_1) == declaration.fetch(:page).to_s }
      if index
        generated["$ID"] = items[index]["$ID"] if items[index]["$ID"]
        items[index] = items[index].merge(generated)
      else
        items << generated
      end
      menu["Items"] = IO::BsonCodec.build_array(items, marker: parsed.fetch(:marker))
      if declaration[:home]
        profile["HomePage"] = navigation_home_doc(declaration.fetch(:page), nil)
      end
      mpr.update_unit(raw.fetch("UnitID"), document)
    end

    def ruby_navigation_profile(document, name)
      modern = array_items(document["Profiles"]).find { _1["Name"].to_s == name }
      return modern if modern

      key = LEGACY_NAVIGATION_PROFILES[name] || LEGACY_NAVIGATION_PROFILES.fetch("Desktop")
      document[key] if name == "Desktop" || LEGACY_NAVIGATION_PROFILES[name]
    end

    def ruby_navigation_page(item)
      item.dig("Action", "FormSettings", "Form").to_s
    end

    def normalize_navigation_caption(value)
      return value.to_h.transform_keys(&:to_s).transform_values(&:to_s) if value.respond_to?(:to_h)

      { "en_US" => value.to_s }
    end

    def merge_existing_document(existing, generated)
      hydrate_pluggable_widgets!(generated, existing)
      merged = existing.merge(generated)
      case existing["$Type"]
      when "Microflows$Microflow", "Microflows$Nanoflow"
        preserve_keys(merged, existing, %w[
          MicroflowParameterCollection MicroflowReturnType UseListParameterByReference
        ])
        if generated["__mxrb_preserve_native_body"]
          preserve_keys(
            merged, existing, %w[ObjectCollection Flows ReturnVariableName]
          )
          %w[
            MicroflowParameterCollection MicroflowReturnType
            UseListParameterByReference ReturnVariableName
          ].each do |key|
            merged.delete(key) unless existing.key?(key)
          end
        elsif generated["__mxrb_body_declared"]
          preserve_flow_auxiliary_objects(merged, existing)
        else
          preserve_keys(merged, existing, %w[ObjectCollection Flows ReturnVariableName])
        end
        preserve_flow_metadata(merged, existing, generated)
        preserve_allowed_roles(merged, existing, generated)
      when /^Pages\$/
        preserve_keys(merged, existing, %w[Widgets Parameters]) unless generated["__mxrb_deep_structure_declared"]
        preserve_allowed_roles(merged, existing, generated)
      when "Forms$Page"
        unless generated["__mxrb_deep_structure_declared"]
          preserve_keys(merged, existing, %w[
            AllowedRoles Appearance Autofocus CanvasHeight CanvasWidth
            Excluded MarkAsUsed Parameters PopupCloseAction Variables
          ])
        end
        preserve_allowed_roles(merged, existing, generated)
      else
        merged
      end
    end

    def strip_internal_keys(doc)
      doc.delete("__mxrb_allowed_roles_declared")
      doc.delete("__mxrb_body_declared")
      doc.delete("__mxrb_preserve_native_body")
      doc.delete("__mxrb_deep_structure_declared")
      doc.delete("__mxrb_allow_concurrent_execution_declared")
      doc.delete("__mxrb_apply_entity_access_declared")
      doc.delete("__mxrb_mark_as_used_declared")
      doc.delete("__mxrb_excluded_declared")
      strip_nested_internal_keys(doc)
      doc
    end

    def strip_nested_internal_keys(value)
      case value
      when Hash
        value.delete_if { |key, _| key.to_s.start_with?("__mxrb_") }
        value.each_value { strip_nested_internal_keys(_1) }
      when Array
        value.each { strip_nested_internal_keys(_1) }
      end
    end

    def hydrate_pluggable_widgets!(generated, existing)
      existing_widgets = custom_widgets(existing).to_h { [_1["Name"], _1] }
      custom_widgets(generated).each do |widget|
        options = widget.delete("__mxrb_widget_options")
        next if options && complete_widget_definition?(widget)

        baseline = existing_widgets[widget["Name"]]
        next unless options && compatible_widget_baseline?(widget, baseline)

        widget["Type"] = baseline["Type"]
        widget["Object"] = baseline["Object"]
        configure_data_grid2!(widget, options) if widget.dig("Type", "WidgetId") == data_grid2_descriptor[:id]
        configure_combo_box!(widget, options) if widget.dig("Type", "WidgetId") == combo_box_descriptor[:id]
        configure_pluggable_widget!(widget, options) if options[:__kind].to_sym == :pluggable_widget
      end
    end

    def configure_pluggable_widget!(widget, options)
      properties = custom_widget_properties(widget)
      options.fetch(:properties, {}).each do |key, configured|
        property = properties[key.to_s]
        configure_custom_widget_value!(property, configured) if property
      end
    end

    def configure_custom_widget_value!(property, configured)
      value = property.fetch('Value')
      unless configured.is_a?(Hash)
        value['PrimitiveValue'] = configured.to_s unless configured.nil?
        return value
      end
      return value.merge!(stringify_keys(configured)) unless semantic_widget_value?(configured)

      configured = configured.to_h { |key, item| [key.to_sym, item] }
      value['PrimitiveValue'] = configured[:primitive].to_s if configured.key?(:primitive)
      value['Expression'] = configured[:expression].to_s if configured.key?(:expression)
      value['Selection'] = configured[:selection].to_s if configured.key?(:selection)
      value['TextTemplate'] = client_template_doc(configured[:text]) if configured.key?(:text)
      value['AttributeRef'] = attribute_ref_doc(configured[:attribute]) if configured.key?(:attribute)
      value['EntityRef'] = indirect_entity_ref_doc(configured[:association]) if configured.key?(:association)
      configure_widget_data_source!(value, configured[:data_source]) if configured.key?(:data_source)
      configure_widget_children!(value, configured[:widgets]) if configured.key?(:widgets)
      configure_widget_objects!(property, value, configured[:objects]) if configured.key?(:objects)
      value
    end

    def semantic_widget_value?(value)
      value.is_a?(Hash) && (value.keys.map(&:to_sym) & %i[
        primitive expression selection text attribute association data_source widgets objects
      ]).any?
    end

    def configure_widget_data_source!(value, configured)
      options = configured.is_a?(Hash) ? configured : { entity: configured }
      value['DataSource'] = custom_xpath_source_doc(
        options.fetch(:entity), xpath: options.fetch(:xpath, '')
      )
    end

    def configure_widget_children!(value, widgets)
      children = (widgets.is_a?(Array) ? widgets : [widgets]).compact.map { widget_doc(_1) }
      value['Widgets'] = IO::BsonCodec.build_array(children, marker: 2)
    end

    def configure_widget_objects!(property, value, configurations)
      object_type = property.dig('ValueType', 'ObjectType')
      objects = Array(configurations).map do |configuration|
        object = custom_widget_object_doc(object_type)
        nested = widget_object_properties(object_type, object)
        configuration.each do |key, configured|
          configure_custom_widget_value!(nested.fetch(key.to_s), configured)
        end
        object
      end
      value['Objects'] = IO::BsonCodec.build_array(objects, marker: 2)
    end

    def stringify_keys(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, stringify_keys(item)] }
      when Array then value.map { stringify_keys(_1) }
      else value
      end
    end

    def custom_widgets(value, found = [])
      case value
      when Hash
        found << value if value["$Type"] == "CustomWidgets$CustomWidget"
        value.each_value { custom_widgets(_1, found) }
      when Array
        value.each { custom_widgets(_1, found) }
      end
      found
    end

    def compatible_widget_baseline?(generated, baseline)
      return false unless baseline.is_a?(Hash)
      return false unless generated.dig("Type", "WidgetId") == baseline.dig("Type", "WidgetId")

      array_items(baseline.dig("Type", "ObjectType", "PropertyTypes")).any?
    end

    def complete_widget_definition?(widget)
      array_items(widget.dig('Type', 'ObjectType', 'PropertyTypes')).any?
    end

    def configure_data_grid2!(widget, options)
      properties = custom_widget_properties(widget)
      %w[loadMoreButtonCaption singleSelectionColumnLabel clearSelectionButtonLabel].each do |key|
        properties.dig(key, 'Value')['TextTemplate'] = nil if properties[key]
      end
      if properties['filterSectionTitle']
        properties.dig('filterSectionTitle', 'Value')['TextTemplate'] = empty_client_template_doc
      end
      if options[:entity] && properties["datasource"]
        properties["datasource"]["Value"]["DataSource"] = custom_xpath_source_doc(options[:entity])
      end
      if options[:selection] && properties['itemSelection']
        selection = {
          none: 'None', single: 'Single', multi: 'Multi', multiple: 'Multi'
        }.fetch(options[:selection].to_s.downcase.to_sym) do
          raise ValidationError, 'data grid selection must be none, single, or multi'
        end
        properties.dig('itemSelection', 'Value')['Selection'] = selection
      end
      if properties['filtersPlaceholder'] && options[:filters]
        configured_filters = options[:filters].is_a?(Array) ? options[:filters] : [options[:filters]]
        filters = configured_filters.map { widget_doc(_1) }
        properties.dig('filtersPlaceholder', 'Value')['Widgets'] =
          IO::BsonCodec.build_array(filters, marker: 2)
      end
      return unless properties["columns"] && options[:columns]

      column_type = properties["columns"].dig("ValueType", "ObjectType")
      columns = Array(options[:columns]).map do |column|
        data_grid2_column_doc(column_type, column, entity: options[:entity])
      end
      properties["columns"]["Value"]["Objects"] = IO::BsonCodec.build_array(columns, marker: 2)
    end

    def configure_combo_box!(widget, options)
      properties = custom_widget_properties(widget)
      set_widget_primitive(properties, "source", "context")
      widget["LabelTemplate"] = client_template_doc(options[:caption])
      if options[:__kind].to_sym == :drop_down
        set_widget_primitive(properties, "optionsSourceType", "enumeration")
        if properties["attributeEnumeration"]
          properties.dig("attributeEnumeration", "Value")["AttributeRef"] =
            attribute_ref_doc(options[:attribute])
        end
      else
        set_widget_primitive(properties, "optionsSourceType", "association")
        if properties["attributeAssociation"] && options[:attribute]
          properties.dig("attributeAssociation", "Value")["EntityRef"] =
            indirect_entity_ref_doc(options[:attribute])
        end
        if properties["optionsSourceAssociationDataSource"] && options[:attribute]
          properties.dig("optionsSourceAssociationDataSource", "Value")["DataSource"] =
            custom_xpath_source_doc(association_destination(options[:attribute]))
        end
        if properties["optionsSourceAssociationCaptionAttribute"] && options[:display_attribute]
          properties.dig("optionsSourceAssociationCaptionAttribute", "Value")["AttributeRef"] =
            attribute_ref_doc(options[:display_attribute])
        end
      end
    end

    def set_widget_primitive(properties, key, value)
      properties.dig(key, "Value")["PrimitiveValue"] = value if properties[key]
    end

    def indirect_entity_ref_doc(association)
      destination = association_destination(association)
      {
        "$ID" => SecureRandom.uuid, "$Type" => "DomainModels$IndirectEntityRef",
        "Steps" => IO::BsonCodec.build_array([{
          "$ID" => SecureRandom.uuid, "$Type" => "DomainModels$EntityRefStep",
          "Association" => association.to_s, "DestinationEntity" => destination
        }], marker: 2)
      }
    end

    def association_destination(name)
      @definition.fetch(:modules, []).each do |mod|
        mod.fetch(:entities, []).each do |entity|
          association = entity.fetch(:associations, []).find do |candidate|
            candidate[:name].to_s == name.to_s ||
              "#{mod[:name]}.#{candidate[:name]}" == name.to_s
          end
          return association[:target].to_s if association
        end
      end
      ""
    end

    def custom_widget_properties(widget)
      widget_object_properties(widget.dig('Type', 'ObjectType'), widget['Object'])
    end

    def widget_object_properties(object_type, object)
      types = array_items(object_type&.fetch('PropertyTypes', nil)).to_h do |type|
        [IO::BsonCodec.extract_id(type["$ID"]), type]
      end
      array_items(object&.fetch('Properties', nil)).to_h do |property|
        type = types[IO::BsonCodec.extract_id(property["TypePointer"])]
        [type && type["PropertyKey"], property.merge("ValueType" => type && type["ValueType"])]
      end.compact
    end

    def custom_xpath_source_doc(entity, xpath: '')
      {
        "$ID" => SecureRandom.uuid, "$Type" => "CustomWidgets$CustomWidgetXPathSource",
        "EntityRef" => {
          "$ID" => SecureRandom.uuid, "$Type" => "DomainModels$DirectEntityRef",
          "Entity" => entity.to_s
        },
        "ForceFullObjects" => false,
        "SortBar" => {
          "$ID" => SecureRandom.uuid, "$Type" => "Forms$GridSortBar",
          "SortItems" => IO::BsonCodec.build_array([], marker: 2)
        },
        "SourceVariable" => nil, "XPathConstraint" => xpath.to_s
      }
    end

    def data_grid2_column_doc(object_type, column, entity: nil)
      attribute = column[:attribute]
      attribute = "#{entity}.#{attribute}" if entity && attribute && !attribute.include?('.')
      filters = column[:filter].is_a?(Array) ? column[:filter] : [column[:filter]].compact
      overrides = {
        "showContentAs" => { "PrimitiveValue" => "attribute" },
        "attribute" => { "AttributeRef" => attribute_ref_doc(attribute) },
        "header" => { "TextTemplate" => client_template_doc(column[:caption] || column[:name]) },
        "tooltip" => { "TextTemplate" => empty_client_template_doc },
        "filter" => {
          "Widgets" => IO::BsonCodec.build_array(
            filters.map { widget_doc(_1) }, marker: 2
          )
        }
      }
      custom_widget_object_doc(object_type, overrides)
    end

    def custom_widget_object_doc(object_type, overrides = {})
      properties = array_items(object_type["PropertyTypes"]).map do |property_type|
        value = custom_widget_value_doc(property_type.fetch("ValueType"))
        value.merge!(overrides.fetch(property_type["PropertyKey"], {}))
        {
          "$ID" => SecureRandom.uuid, "$Type" => "CustomWidgets$WidgetProperty",
          "TypePointer" => property_type.fetch("$ID"), "Value" => value
        }
      end
      {
        "$ID" => SecureRandom.uuid, "$Type" => "CustomWidgets$WidgetObject",
        "Properties" => IO::BsonCodec.build_array(properties, marker: 2),
        "TypePointer" => object_type.fetch("$ID")
      }
    end

    def custom_widget_value_doc(value_type)
      doc = {
        "$ID" => SecureRandom.uuid, "$Type" => "CustomWidgets$WidgetValue",
        "Action" => no_action_doc(disabled: true), "AttributeRef" => nil, "DataSource" => nil,
        "EntityRef" => nil, "Expression" => "", "Form" => "", "Icon" => nil,
        "Image" => "", "Microflow" => "", "Nanoflow" => "",
        "Objects" => IO::BsonCodec.build_array([], marker: 2),
        "PrimitiveValue" => "", "Selection" => "None",
        "SourceVariable" => nil, "TextTemplate" => nil, "TranslatableValue" => nil,
        "TypePointer" => value_type.fetch("$ID"),
        "Widgets" => IO::BsonCodec.build_array([], marker: 2), "XPathConstraint" => ""
      }
      default = value_type["DefaultValue"].to_s
      case value_type["Type"]
      when "Expression"   then doc["Expression"] = default
      when "TextTemplate"
        doc["TextTemplate"] = client_template_doc(default) if value_type['Required'] || !default.empty?
      else doc["PrimitiveValue"] = default
      end
      doc
    end

    def preserve_flow_metadata(merged, existing, generated)
      {
        "AllowConcurrentExecution" => "__mxrb_allow_concurrent_execution_declared",
        "ApplyEntityAccess" => "__mxrb_apply_entity_access_declared",
        "MarkAsUsed" => "__mxrb_mark_as_used_declared",
        "Excluded" => "__mxrb_excluded_declared"
      }.each do |field, declaration|
        next if generated[declaration]

        if existing.key?(field)
          merged[field] = existing[field]
        else
          merged.delete(field)
        end
      end
      merged
    end

    def preserve_allowed_roles(merged, existing, generated)
      return merged if generated["__mxrb_allowed_roles_declared"]

      merged["AllowedModuleRoles"] = existing["AllowedModuleRoles"] if existing.key?("AllowedModuleRoles")
      merged
    end

    def preserve_keys(target, source, keys)
      keys.each do |key|
        target[key] = source[key] if source.key?(key)
      end
      target
    end

    def preserve_flow_auxiliary_objects(target, source)
      original_collection = source["ObjectCollection"] || {}
      generated_collection = target["ObjectCollection"] || {}
      original_objects = array_items(original_collection["Objects"])
      generated_objects = array_items(generated_collection["Objects"])
      original_flows = array_items(
        source["Flows"] || original_collection["Flows"]
      )
      generated_flows = array_items(
        target["Flows"] || generated_collection["Flows"]
      )

      original_objects.each_with_index do |object, index|
        next unless %w[
          Microflows$Annotation
          Microflows$MicroflowParameter
        ].include?(object["$Type"])
        if object["$Type"] == 'Microflows$MicroflowParameter' &&
           generated_objects.any? do |generated|
             generated["$Type"] == object["$Type"] && generated["Name"] == object["Name"]
           end
          next
        end

        generated_objects.insert([index, generated_objects.size].min, object)
      end

      original_editable = ordered_flow_objects(
        all_flow_objects(original_objects), original_flows
      ).reject { flow_auxiliary_object?(_1) }
      generated_editable = ordered_flow_objects(
        all_flow_objects(generated_objects), generated_flows
      ).reject { flow_auxiliary_object?(_1) }
      id_mapping = {}
      original_cursor = 0
      generated_editable.each do |generated_object|
        match_index = (original_cursor...original_editable.size).find do |index|
          flow_object_signature(original_editable[index]) ==
            flow_object_signature(generated_object)
        end
        next unless match_index

        original_object = original_editable[match_index]
        original_cursor = match_index + 1
        generated_id = generated_object["$ID"]
        id_mapping[generated_id] = original_object["$ID"]
        preserve_flow_object_metadata(generated_object, original_object)
      end

      generated_flows.each do |flow|
        flow["OriginPointer"] = id_mapping.fetch(flow["OriginPointer"], flow["OriginPointer"])
        flow["DestinationPointer"] = id_mapping.fetch(
          flow["DestinationPointer"], flow["DestinationPointer"]
        )
      end
      original_edges = original_flows.to_h { [flow_edge_signature(_1), _1] }
      generated_flows.map! do |flow|
        original_edges.fetch(flow_edge_signature(flow), flow)
      end
      generated_flows.concat(
        original_flows.select { _1["$Type"] == "Microflows$AnnotationFlow" }
      )
      validate_flow_endpoints!(generated_objects, generated_flows)

      generated_collection["Objects"] = IO::BsonCodec.build_array(generated_objects)
      target["ObjectCollection"] = generated_collection
      target["Flows"] = IO::BsonCodec.build_array(generated_flows)
      target
    end

    def preserve_flow_object_metadata(generated, original)
      original_id = original["$ID"]
      presentation_keys = %w[
        RelativeMiddlePoint Size Caption AutoGenerateCaption BackgroundColor
        Documentation Disabled ErrorHandlingType
      ]
      if generated["Action"].is_a?(Hash) && original["Action"].is_a?(Hash) &&
         generated["Action"]["$Type"] == original["Action"]["$Type"]
        generated["Action"] = deep_merge_flow_metadata(
          original["Action"], generated["Action"]
        )
        if original["Action"].key?("ErrorHandlingType")
          generated["Action"]["ErrorHandlingType"] = original["Action"]["ErrorHandlingType"]
        else
          generated["Action"].delete("ErrorHandlingType")
        end
      end
      presentation_keys.each do |key|
        if original.key?(key)
          generated[key] = original[key]
        else
          generated.delete(key)
        end
      end
      generated["$ID"] = original_id
    end

    def deep_merge_flow_metadata(original, generated)
      original.merge(generated) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge_flow_metadata(old_value, new_value)
        elsif old_value.is_a?(Array) && new_value.is_a?(Array) &&
              old_value.size == new_value.size
          old_value.zip(new_value).map do |old_item, new_item|
            if old_item.is_a?(Hash) && new_item.is_a?(Hash)
              deep_merge_flow_metadata(old_item, new_item)
            else
              new_item
            end
          end
        elsif new_value.nil?
          old_value
        else
          new_value
        end
      end
    end

    def all_flow_objects(objects)
      objects.flat_map do |object|
        nested = array_items(object.dig("ObjectCollection", "Objects"))
        [object] + all_flow_objects(nested)
      end
    end

    def ordered_flow_objects(objects, flows)
      flows = flows.reject { _1["$Type"] == "Microflows$AnnotationFlow" }
      by_id = objects.to_h { [_1["$ID"], _1] }
      incoming = flows.group_by { _1["DestinationPointer"] }
      outgoing = flows.group_by { _1["OriginPointer"] }
      roots = objects.select { _1["$Type"] == "Microflows$StartEvent" }
      roots += objects.reject { incoming.key?(_1["$ID"]) || roots.include?(_1) }
      result = []
      queue = roots
      until queue.empty?
        object = queue.shift
        next unless object && !result.include?(object)

        result << object
        Array(outgoing[object["$ID"]]).each do |flow|
          queue << by_id[flow["DestinationPointer"]]
        end
      end
      result + (objects - result)
    end

    def validate_flow_endpoints!(objects, flows)
      object_ids = all_flow_objects(objects).map { _1["$ID"] }
      dangling = flows.find do |flow|
        !object_ids.include?(flow["OriginPointer"]) ||
          !object_ids.include?(flow["DestinationPointer"])
      end
      return unless dangling

      flow_id = IO::BsonCodec.extract_id(dangling["$ID"])
      raise ValidationError, "generated flow #{flow_id} references a missing object"
    end

    def flow_auxiliary_object?(object)
      %w[Microflows$Annotation Microflows$MicroflowParameter].include?(object["$Type"])
    end

    def flow_object_signature(object)
      [object["$Type"], object.dig("Action", "$Type")]
    end

    def flow_edge_signature(flow)
      [
        flow["OriginPointer"], flow["DestinationPointer"],
        flow["IsErrorHandler"] == true,
        array_items(flow["CaseValues"]).first&.dig("$Type") ||
          flow.dig("NewCaseValue", "$Type"),
        array_items(flow["CaseValues"]).first&.dig("Value") ||
          flow.dig("NewCaseValue", "Value")
      ]
    end

    def stable_id(*parts)
      hex = Digest::SHA1.hexdigest(parts.join(":"))
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    def find_named(mpr, containment, parent_id, name)
      mpr.units_by_containment(containment).find do |raw|
        raw["ContainerID"] == parent_id && mpr.parse_contents(raw)["Name"] == name
      end
    end

    def documents_by_name(mpr, module_id)
      collect_documents(mpr, module_id).group_by do |raw|
        mpr.parse_contents(raw)["Name"]
      end
    end

    def collect_documents(mpr, parent_id)
      mpr.children_of(parent_id).flat_map do |raw|
        case raw["ContainmentName"]
        when "Documents"
          [raw]
        when "Folders"
          collect_documents(mpr, raw.fetch("UnitID"))
        else
          []
        end
      end
    end

    def module_doc(name, index, previous: nil)
      current = previous || {}
      current.merge(
        "$ID" => current["$ID"] || SecureRandom.uuid,
        "$Type" => current["$Type"] || "Projects$ModuleImpl",
        "AppStoreGuid" => current.fetch("AppStoreGuid", ""),
        "AppStoreVersion" => current.fetch("AppStoreVersion", ""),
        "AppStoreVersionGuid" => current.fetch("AppStoreVersionGuid", ""),
        "FromAppStore" => current.fetch("FromAppStore", false),
        "Name" => name,
        "NewSortIndex" => current.fetch("NewSortIndex", index.to_f)
      ).tap do |doc|
        doc.delete('SortIndex')
        doc.delete('ExportLevel')
      end
    end

    def entity_doc(entity, module_name, previous, index, access_associations: [])
      id = previous&.dig("$ID") || SecureRandom.uuid
      attrs_key = native_key(previous, "attributes", "Attributes")
      rules_key = native_key(previous, "accessRules", "AccessRules")
      events_key = native_key(previous, "eventHandlers", "EventHandlers")
      indexes_key = native_key(previous, "indexes", "Indexes")
      validation_key = native_key(previous, "validationRules", "ValidationRules")
      generalization_key = native_existing_key(
        previous, 'generalization', 'Generalization', 'maybeGeneralization', 'MaybeGeneralization'
      ) || 'MaybeGeneralization'
      previous_attrs = array_items(previous&.dig(attrs_key)).to_h do |attribute|
        [attribute["name"] || attribute["Name"], attribute]
      end
      attrs = entity.fetch(:attributes).map do |attr|
        attribute_doc(
          attr, previous_attrs[attr.fetch(:name)], oql_view: !entity[:oql_view].nil?
        )
      end
      attribute_ids = attrs.to_h { [_1['Name'] || _1.fetch('name'), _1.fetch('$ID')] }
      rules_declared = !entity[:access_rules].nil?
      access_rules = if rules_declared
        IO::BsonCodec.build_array(
          entity.fetch(:access_rules).map do |rule|
            access_rule_doc(
              rule, module_name, entity.fetch(:name),
              attributes: entity.fetch(:attributes).map { _1.fetch(:name) },
              associations: access_associations
            )
          end
        )
      else
        previous&.dig(rules_key) || IO::BsonCodec.build_array([])
      end
      doc = (previous || {}).merge(
        "$ID" => id, "$Type" => previous&.fetch("$Type", nil) || "DomainModels$EntityImpl",
        "Name" => entity.fetch(:name), "Documentation" => entity.fetch(:documentation, ""),
        "GUID" => previous&.dig("GUID") || SecureRandom.uuid,
        "Location" => previous&.dig("Location") || "#{(index % 4) * 220};#{(index / 4) * 160}",
        "Image" => previous&.fetch("Image", "") || "",
        "IsRemote" => previous&.fetch("IsRemote", false) || false,
        "RemoteSource" => previous&.fetch("RemoteSource", "") || ""
      )
      apply_oql_view!(doc, entity.fetch(:oql_view, nil), previous)
      doc[attrs_key] = IO::BsonCodec.build_array(attrs)
      doc[rules_key] = access_rules
      doc[validation_key] = validation_rules_doc(
        entity, module_name, previous&.dig(validation_key)
      )
      if entity[:indexes].nil?
        doc[indexes_key] ||= IO::BsonCodec.build_array([])
      else
        doc[indexes_key] = IO::BsonCodec.build_array(
          entity.fetch(:indexes).map { index_doc(_1, attribute_ids:) }
        )
      end
      if entity[:lifecycle].nil?
        doc[events_key] ||= IO::BsonCodec.build_array([])
      else
        doc[events_key] = IO::BsonCodec.build_array(entity.fetch(:lifecycle).map { lifecycle_doc(_1) })
      end
      if entity[:generalization]
        doc[generalization_key] = generalization_doc(entity.fetch(:generalization))
      elsif entity[:system_members]
        doc[generalization_key] = no_generalization(
          entity.fetch(:persistable, true), **entity.fetch(:system_members)
        )
      elsif previous.nil? || previous.key?(generalization_key)
        doc[generalization_key] ||= no_generalization(entity.fetch(:persistable, true))
      end
      doc
    end

    def apply_oql_view!(doc, view, previous)
      return unless view

      if view[:source]
        source_key = native_existing_key(previous, 'source', 'Source') || 'Source'
        current_source = previous&.dig(source_key)
        source = (current_source.is_a?(Hash) ? current_source : {}).merge(
          '$ID' => current_source&.fetch('$ID', nil) || SecureRandom.uuid,
          '$Type' => 'DomainModels$OqlViewEntitySource',
          'SourceDocument' => view.fetch(:source)
        )
        doc[source_key] = source
      end
      return unless view[:query]

      query_key = native_existing_key(previous, 'oqlQuery', 'OqlQuery', 'OQLQuery') || 'OqlQuery'
      doc[query_key] = view.fetch(:query)
    end

    def attribute_doc(attr, previous, oql_view: false)
      storage_type = Model::Attribute::TYPE_MAP.fetch(attr.fetch(:type).to_sym)
      type_key = native_existing_key(previous, "type", "Type", "newType", "NewType") || "NewType"
      value_key = native_existing_key(previous, "value", "Value") || "Value"
      name_key = native_key(previous, "name", "Name")
      documentation_key = native_key(previous, "documentation", "Documentation")
      previous_type = previous&.dig(type_key)
      type_doc = if previous_type.is_a?(Hash) && previous_type["$Type"] == storage_type
        previous_type
      else
        { "$ID" => SecureRandom.uuid, "$Type" => storage_type }
      end
      if attr.key?(:enumeration)
        type_doc = type_doc.reject { |key, _value| %w[enumeration Enumeration].include?(key) }
        type_doc = type_doc.merge("Enumeration" => attr[:enumeration].to_s) if attr[:enumeration]
      end
      string_type = storage_type == Model::Attribute::TYPE_MAP[:string]
      if string_type && (attr.key?(:length) || (!previous_type&.key?('length') && !previous_type&.key?('Length')))
        length_key = native_key(previous_type, 'length', 'Length')
        length = attr[:length] || Model::Attribute::DEFAULT_STRING_LENGTH
        type_doc = type_doc.merge(length_key => Integer(length))
      end
      datetime_type = storage_type == Model::Attribute::TYPE_MAP[:datetime]
      if attr.key?(:localize_date) && (datetime_type || !attr[:localize_date].nil?)
        localize_key = native_key(previous_type, 'localizeDate', 'LocalizeDate')
        type_doc = type_doc.merge(localize_key => (attr[:localize_date] == true))
      end
      previous_value = previous&.dig(value_key)
      value_doc = if oql_view
        current = previous_value.is_a?(Hash) ? previous_value : {}
        current = current.merge(
          "$ID" => current["$ID"] || SecureRandom.uuid,
          "$Type" => "DomainModels$OqlViewValue",
          "Reference" => attr.fetch(:name)
        )
        current.delete("DefaultValue")
        current.delete("defaultValue")
        current
      elsif previous_value && !attr.key?(:default) &&
            previous_value["$Type"] != "DomainModels$OqlViewValue"
        previous_value
      elsif previous_value.is_a?(Hash) && previous_value["$Type"] == "DomainModels$StoredValue"
        updated = previous_value.dup
        default_key = native_key(previous_value, "defaultValue", "DefaultValue")
        updated[default_key] = attr.fetch(:default, "").to_s
        updated
      else
        {
          "$ID" => SecureRandom.uuid, "$Type" => "DomainModels$StoredValue",
          "DefaultValue" => attr.fetch(:default, "").to_s
        }
      end
      doc = (previous || {}).merge(
        "$ID" => previous&.dig("$ID") || SecureRandom.uuid,
        "$Type" => "DomainModels$Attribute",
        "GUID" => previous&.dig("GUID") || SecureRandom.uuid
      )
      doc[name_key] = attr.fetch(:name)
      doc[documentation_key] = attr.fetch(:documentation, "")
      doc[type_key] = type_doc
      doc[value_key] = value_doc
      doc
    end

    def native_key(hash, lower, upper)
      return upper unless hash
      return lower if hash.key?(lower)
      return upper if hash.key?(upper)

      upper
    end

    def native_existing_key(hash, *keys)
      return nil unless hash

      keys.find { hash.key?(_1) }
    end

    def no_generalization(persistable, owner: false, created_date: false,
                          changed_date: false, changed_by: false)
      { "$ID" => SecureRandom.uuid, "$Type" => "DomainModels$NoGeneralization",
        "Persistable" => persistable, "HasChangedDateAttr" => changed_date,
        "HasCreatedDateAttr" => created_date, "HasOwnerAttr" => owner,
        "HasChangedByAttr" => changed_by }
    end

    def generalization_doc(target)
      declaration = target.respond_to?(:to_h) ? target.to_h.transform_keys(&:to_sym) : { target: }
      {
        '$ID' => declaration[:id].to_s.empty? ? SecureRandom.uuid : declaration[:id].to_s,
        '$Type' => 'DomainModels$Generalization',
        'Generalization' => declaration.fetch(:target).to_s
      }
    end

    def validation_rules_doc(entity, module_name, previous)
      existing = array_items(previous)
      declarations = entity.fetch(:attributes).select do |attribute|
        attribute.key?(:required) || attribute.key?(:unique)
      end
      return previous || IO::BsonCodec.build_array([]) if declarations.empty?

      kept = existing.reject do |rule|
        declarations.any? { validation_declaration_matches?(_1, rule) }
      end
      generated = declarations.flat_map do |attribute|
        %i[required unique].filter_map do |kind|
          next unless attribute[kind] == true

          existing.find { validation_rule_matches?(_1, attribute.fetch(:name), kind) } ||
            validation_rule_doc(module_name, entity.fetch(:name), attribute.fetch(:name), kind)
        end
      end
      IO::BsonCodec.build_array(kept + generated)
    end

    def validation_declaration_matches?(attribute, rule)
      %i[required unique].any? do |kind|
        attribute.key?(kind) && validation_rule_matches?(rule, attribute.fetch(:name), kind)
      end
    end

    def validation_rule_matches?(rule, attribute_name, kind)
      rule['Attribute'].to_s.split('.').last == attribute_name &&
        rule.dig('RuleInfo', '$Type').to_s.end_with?("#{kind.to_s.capitalize}RuleInfo")
    end

    def validation_rule_doc(module_name, entity_name, attribute_name, kind)
      {
        '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$ValidationRule',
        'Attribute' => "#{module_name}.#{entity_name}.#{attribute_name}",
        'Message' => {
          '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text',
          'Items' => IO::BsonCodec.build_array([{
            '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation',
            'LanguageCode' => 'en_US',
            'Text' => "#{attribute_name} #{kind == :required ? 'is required' : 'must be unique'}"
          }])
        },
        'RuleInfo' => {
          '$ID' => SecureRandom.uuid,
          '$Type' => "DomainModels$#{kind.to_s.capitalize}RuleInfo"
        }
      }
    end

    def index_doc(index, attribute_ids:)
      declarations = index[:members] || index.fetch(:attributes).zip(index.fetch(:ascending)).map do |name, ascending|
        { name:, ascending: }
      end
      members = declarations.map do |member|
        attribute = member.fetch(:name).to_s
        {
          '$ID' => member.fetch(:id, nil).to_s.empty? ? SecureRandom.uuid : member.fetch(:id).to_s,
          '$Type' => 'DomainModels$IndexedAttribute',
          'Type' => member.fetch(:type, :Normal).to_s,
          'AttributePointer' => binary_uuid(attribute_ids.fetch(attribute)),
          'AssociationPointer' => binary_uuid('00000000-0000-0000-0000-000000000000'),
          'Ascending' => member.fetch(:ascending, true) == true
        }
      end
      id = index.fetch(:id, nil).to_s.empty? ? SecureRandom.uuid : index.fetch(:id).to_s
      guid = index.fetch(:guid, nil).to_s.empty? ? id : index.fetch(:guid).to_s
      {
        '$ID' => id, '$Type' => 'DomainModels$EntityIndex',
        'GUID' => binary_uuid(guid),
        'Attributes' => IO::BsonCodec.build_array(members, marker: 2),
        'IncludeInOffline' => index.fetch(:include_offline, false)
      }
    end

    def binary_uuid(value)
      return value if value.is_a?(BSON::Binary)

      BSON::Binary.new(IO::BsonCodec.uuid_to_blob(value), :generic)
    end

    def access_rule_doc(rule, module_name, entity_name, attributes: [], associations: [])
      read = rule.fetch(:read, :none)
      write = rule.fetch(:write, :none)
      default_rights = rule[:default_rights] || access_default_rights(read, write)
      members = if rule[:members]
                  exact_access_member_docs(rule.fetch(:members), module_name, entity_name)
                else
                  access_member_docs(
                    read, write, module_name, entity_name, attributes:, associations:
                  )
                end
      {
        "$ID" => rule.fetch(:id, nil).to_s.empty? ? SecureRandom.uuid : rule.fetch(:id).to_s,
        "$Type" => "DomainModels$AccessRule",
        "Documentation" => rule.fetch(:documentation, '').to_s,
        "AllowedModuleRoles" => IO::BsonCodec.build_array(rule.fetch(:roles), marker: 1),
        "AllowCreate" => rule.fetch(:create, false),
        "AllowDelete" => rule.fetch(:delete, false),
        "DefaultMemberAccessRights" => default_rights,
        "MemberAccesses" => IO::BsonCodec.build_array(members),
        "XPathConstraint" => rule.fetch(:xpath, "")
      }.tap do |doc|
        caption = rule[:xpath_caption]
        doc["XPathConstraintCaption"] = caption.to_s unless caption.nil?
      end
    end

    def exact_access_member_docs(members, module_name, entity_name)
      members.map do |member|
        association = member.fetch(:kind, :attribute).to_sym == :association
        name = member.fetch(:name).to_s
        reference = member[:reference].to_s
        {
          "$ID" => member.fetch(:id, nil).to_s.empty? ? SecureRandom.uuid : member.fetch(:id).to_s,
          "$Type" => "DomainModels$MemberAccess",
          "Association" => association ? qualified_member(reference, "#{module_name}.#{name}") : "",
          "Attribute" => association ? "" : qualified_member(reference, "#{module_name}.#{entity_name}.#{name}"),
          "AccessRights" => member.fetch(:rights).to_s
        }
      end
    end

    def qualified_member(reference, fallback)
      reference.empty? ? fallback : reference
    end

    def access_default_rights(read, write)
      return "ReadWrite" if write == :all
      return "ReadOnly"  if read == :all
      "None"
    end

    def access_member_docs(read, write, module_name, entity_name, attributes: [], associations: [])
      explicit_writes = write.is_a?(Array) ? write.map(&:to_s) : []
      explicit_reads  = read.is_a?(Array)  ? read.map(&:to_s)  : []
      all_members = (attributes + associations + explicit_reads + explicit_writes).map(&:to_s).uniq
      all_members.map do |member|
        rights = if write == :all || explicit_writes.include?(member)
                   'ReadWrite'
                 elsif read == :all || explicit_reads.include?(member)
                   'ReadOnly'
                 else
                   'None'
                 end
        association = associations.map(&:to_s).include?(member)
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "DomainModels$MemberAccess",
          "Association" => association ? "#{module_name}.#{member}" : "",
          "Attribute" => association ? "" : "#{module_name}.#{entity_name}.#{member}",
          "AccessRights" => rights
        }
      end
    end

    def association_doc(association, from_id:, to_id:, previous:, oql_view: false)
      doc = (previous || {}).merge(
        "$ID" => previous&.dig("$ID") || SecureRandom.uuid,
        "$Type" => "DomainModels$Association",
        "Name" => association.fetch(:name),
        "Documentation" => association.fetch(:documentation, ''),
        "ParentPointer" => from_id,
        "ChildPointer" => to_id,
        "ParentConnection" => "0;50",
        "ChildConnection" => "100;50",
        "GUID" => previous&.dig("GUID") || SecureRandom.uuid,
        "Type" => association.fetch(:type).to_s,
        "Owner" => association.fetch(:owner, :Default).to_s,
        "StorageFormat" => association[:storage_format]&.to_s ||
          (association.fetch(:type) == :ReferenceSet ? "Table" : "Column")
      )
      behavior = previous&.dig('DeleteBehavior') || previous&.dig('deleteBehavior') || {}
      parent_key = native_key(behavior, 'parentDeleteBehavior', 'ParentDeleteBehavior')
      child_key = native_key(behavior, 'childDeleteBehavior', 'ChildDeleteBehavior')
      parent_error_key = native_key(behavior, 'parentErrorMessage', 'ParentErrorMessage')
      child_error_key = native_key(behavior, 'childErrorMessage', 'ChildErrorMessage')
      behavior = behavior.merge(
        '$ID' => behavior['$ID'] || SecureRandom.uuid,
        '$Type' => 'DomainModels$DeleteBehavior',
        parent_key => association.fetch(:parent_delete, :DeleteMeButKeepReferences).to_s,
        child_key => association.fetch(:child_delete, :DeleteMeButKeepReferences).to_s,
        parent_error_key => behavior[parent_error_key], child_error_key => behavior[child_error_key]
      )
      doc[native_key(previous, 'deleteBehavior', 'DeleteBehavior')] = behavior
      source_key = native_existing_key(previous, 'source', 'Source') || 'Source'
      if oql_view
        source = previous&.dig(source_key)
        source = {} unless source.is_a?(Hash)
        doc[source_key] = source.merge(
          '$ID' => source['$ID'] || SecureRandom.uuid,
          '$Type' => 'DomainModels$OqlViewAssociationSource',
          'Reference' => association.fetch(:name)
        )
      elsif doc.dig(source_key, '$Type') == 'DomainModels$OqlViewAssociationSource'
        doc.delete(source_key)
      end
      doc
    end

    def cross_association_doc(association, from_id:, target:, previous:, oql_view: false)
      doc = association_doc(
        association, from_id:, to_id: nil, previous:, oql_view:
      ).merge(
        '$Type' => 'DomainModels$CrossAssociation',
        'Child' => target,
        'ParentPointer' => from_id
      )
      doc.delete('ChildPointer')
      doc.delete('ParentConnection')
      doc.delete('ChildConnection')
      doc
    end

    def lifecycle_doc(callback)
      event, moment = callback.fetch(:event).to_s.split("_", 2)
      {
        "$ID" => callback.fetch(:id, nil).to_s.empty? ? SecureRandom.uuid : callback.fetch(:id).to_s,
        "$Type" => "DomainModels$EventHandler",
        "Event" => event == "before" || event == "after" ? moment.capitalize : event.capitalize,
        "Moment" => event.capitalize,
        "Microflow" => callback.fetch(:handler),
        "PassEventObject" => callback.fetch(:pass_event_object, true) == true,
        "RaiseErrorOnFalse" => callback.fetch(:raise_error_on_false, event == "before") == true
      }
    end

    def page_doc(page, module_name = nil)
      if page[:deep_structure].is_a?(Hash)
        return page[:deep_structure].merge(
          "$ID" => SecureRandom.uuid,
          "Name" => page.fetch(:name),
          "__mxrb_allowed_roles_declared" => !page[:allowed_roles].nil?,
          "__mxrb_deep_structure_declared" => true
        )
      end

      context_entity = page_context_entity(page, module_name)
      widgets = page.fetch(:widgets, []).map { widget_doc(_1, context_entity:) }
      # Backwards-compatible page-level bindings target widgets by name.
      page.fetch(:events, []).each do |event|
        next unless event[:target]
        target = widgets.find { _1["Name"] == event[:target].to_s }
        target[event_property(event.fetch(:event))] = client_action_doc(event) if target
      end
      content = if page[:data_source]
        [data_view_doc(page.fetch(:data_source), widgets)]
      else
        widgets
      end
      content = content.map { legacy_widget_tree(_1) } if oldest_layout_contract?
      roles_declared = !page[:allowed_roles].nil?
      argument = {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$FormCallArgument",
        "Parameter" => "#{page.fetch(:layout)}.Main"
      }
      if oldest_layout_contract?
        argument['Widget'] = legacy_single_widget(content)
      else
        argument['Widgets'] = IO::BsonCodec.build_array(content, marker: 2)
      end
      form_call = {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$LayoutCall",
        "Arguments" => IO::BsonCodec.build_array([argument], marker: 2),
        "Form" => page.fetch(:layout)
      }
      doc = { "$ID" => SecureRandom.uuid, "$Type" => "Forms$Page", "Name" => page.fetch(:name),
        "__mxrb_unit_id" => page[:unit_id],
        "Documentation" => "", "Url" => "", "FormCall" => form_call,
        "Title" => text_doc(page.fetch(:title)), "MarkAsUsed" => false, "Excluded" => false,
        "AllowedModuleRoles" => IO::BsonCodec.build_array(Array(page[:allowed_roles]), marker: 1),
        "__mxrb_allowed_roles_declared" => roles_declared,
        "__mxrb_deep_structure_declared" => false,
        "Parameters" => IO::BsonCodec.build_array([]),
        "PopupWidth" => page.fetch(:popup) ? 600 : 0,
        "PopupHeight" => page.fetch(:popup) ? 400 : 0,
        "PopupResizable" => page.fetch(:popup), "ExportLevel" => "Hidden" }
      doc
    end

    def legacy_widget_tree(value)
      transformed = value.transform_values do |child|
        case child
        when Hash then legacy_widget_tree(child)
        when Array then child.map { _1.is_a?(Hash) ? legacy_widget_tree(_1) : _1 }
        else child
        end
      end
      singular = {
        'Forms$DivContainer' => [%w[Widgets Widget]],
        'Forms$DataView' => [%w[Widgets Widget], %w[FooterWidgets FooterWidget]],
        'Forms$TabPage' => [%w[Widgets Widget]]
      }.fetch(transformed['$Type'], [])
      singular.each do |plural, single|
        next unless transformed.key?(plural)

        transformed[single] = legacy_single_widget(array_items(transformed.delete(plural)))
      end
      transformed
    end

    def legacy_single_widget(widgets)
      return nil if widgets.empty?
      return widgets.first if widgets.one?

      {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$VerticalFlow',
        'Widgets' => IO::BsonCodec.build_array(widgets, marker: 2),
        'Name' => 'verticalFlow', 'Class' => '', 'Style' => '', 'TabIndex' => 0
      }
    end

    def menu_doc(menu)
      if menu[:deep_structure].is_a?(Hash)
        return menu[:deep_structure].merge(
          "$ID" => SecureRandom.uuid,
          "Name" => menu.fetch(:name)
        )
      end

      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Menus$MenuDocument",
        "Name" => menu.fetch(:name),
        "Documentation" => "",
        "Excluded" => false,
        "ItemCollection" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Menus$MenuItemCollection",
          "Items" => IO::BsonCodec.build_array(menu.fetch(:items, []).map { menu_item_doc(_1) })
        }
      }
    end

    CONSTANT_TYPE_MAP = {
      string: "DataTypes$StringType", integer: "DataTypes$IntegerType",
      boolean: "DataTypes$BooleanType", decimal: "DataTypes$DecimalType",
      datetime: "DataTypes$DateTimeType"
    }.freeze

    SCHEDULED_EVENT_INTERVAL_MAP = {
      milliseconds: "Millisecond", seconds: "Second", minutes: "Minute",
      hours: "Hour", days: "Day", weeks: "Week", months: "Month", years: "Year"
    }.freeze

    def enumeration_doc(enum)
      values = Array(enum.fetch(:values, [])).map do |val|
        captions = val.fetch(:captions, { 'en_US' => val[:caption] || val.fetch(:name) })
        caption_ids = val.fetch(:caption_ids, {})
        value = {
          "$ID" => val[:id].to_s.empty? ? SecureRandom.uuid : val[:id].to_s,
          "$Type" => "Enumerations$EnumerationValue",
          "Name" => val.fetch(:name),
          "Caption" => {
            "$ID" => val[:caption_id].to_s.empty? ? SecureRandom.uuid : val[:caption_id].to_s,
            "$Type" => "Texts$Text",
            "Items" => IO::BsonCodec.build_array(
              captions.map do |language, text|
                translation_id = caption_ids[language.to_s].to_s
                {
                  "$ID" => translation_id.empty? ? SecureRandom.uuid : translation_id,
                  "$Type" => "Texts$Translation",
                  "LanguageCode" => language.to_s, "Text" => text.to_s
                }
              end,
              marker: val.fetch(:translations_marker, 3)
            )
          },
          "Image" => val.fetch(:image, '').to_s,
          "RemoteValue" => val[:remote_value]
        }
        value["ExportLevel"] = val[:export_level].to_s unless val[:export_level].nil?
        value
      end
      document = {
        "$ID" => enum[:id].to_s.empty? ? SecureRandom.uuid : enum[:id].to_s,
        "$Type" => "Enumerations$Enumeration",
        "Name" => enum.fetch(:name),
        "Documentation" => enum.fetch(:documentation, ""),
        "Excluded" => enum.fetch(:excluded, false) == true,
        "ExportLevel" => enum.fetch(:export_level, "Hidden"),
        "RemoteSource" => enum[:remote_source],
        "Values" => IO::BsonCodec.build_array(values, marker: enum.fetch(:values_marker, 3))
      }
      document["__mxrb_unit_id"] = enum[:unit_id].to_s unless enum[:unit_id].to_s.empty?
      document
    end

    def constant_doc(constant)
      type_sym = constant.fetch(:type).to_sym
      type_str = CONSTANT_TYPE_MAP.fetch(type_sym) do
        raise ArgumentError, "unsupported constant type #{type_sym.inspect}; " \
                             "use one of: #{CONSTANT_TYPE_MAP.keys.join(', ')}"
      end
      document = {
        "$ID" => constant[:id].to_s.empty? ? SecureRandom.uuid : constant[:id].to_s,
        "$Type" => "Constants$Constant",
        "Name" => constant.fetch(:name),
        "Documentation" => constant.fetch(:documentation, ""),
        "Excluded" => constant.fetch(:excluded, false) == true,
        "ExportLevel" => constant.fetch(:export_level, "Hidden"),
        "ExposedToClient" => constant.fetch(:exposed_to_client, false) == true,
        "Type" => {
          "$ID" => constant[:type_id].to_s.empty? ? SecureRandom.uuid : constant[:type_id].to_s,
          "$Type" => type_str
        },
        "DefaultValue" => constant.fetch(:value, "").to_s
      }
      document["__mxrb_unit_id"] = constant[:unit_id].to_s unless constant[:unit_id].to_s.empty?
      document
    end

    def scheduled_event_doc(event)
      unit_sym = event.fetch(:unit).to_sym
      interval_type = SCHEDULED_EVENT_INTERVAL_MAP.fetch(unit_sym) do
        raise ArgumentError, "unsupported scheduled event unit #{unit_sym.inspect}; " \
                             "use one of: #{SCHEDULED_EVENT_INTERVAL_MAP.keys.join(', ')}"
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "ScheduledEvents$ScheduledEvent",
        "Name" => event.fetch(:name),
        "Documentation" => event.fetch(:documentation, ""),
        "ExportLevel" => "Hidden",
        "Microflow" => event.fetch(:microflow),
        "StartDateTime" => Time.utc(2000, 1, 1),
        "TimeZone" => "UTC",
        "Schedule" => scheduled_event_schedule_doc(event),
        "OnOverlap" => "SkipNext",
        "Enabled" => event.fetch(:enabled, true),
        "IntervalType" => interval_type,
        "Interval" => event.fetch(:interval, 1)
      }
    end

    def scheduled_event_schedule_doc(event)
      interval = Integer(event.fetch(:interval, 1))
      case event.fetch(:unit).to_sym
      when :minutes
        { '$ID' => SecureRandom.uuid, '$Type' => 'ScheduledEvents$MinuteSchedule',
          'Multiplier' => interval }
      when :hours
        { '$ID' => SecureRandom.uuid, '$Type' => 'ScheduledEvents$HourSchedule',
          'Multiplier' => interval, 'MinuteOffset' => 0 }
      when :days
        raise ArgumentError, 'day schedules support interval: 1' unless interval == 1

        { '$ID' => SecureRandom.uuid, '$Type' => 'ScheduledEvents$DaySchedule',
          'HourOfDay' => 0, 'MinuteOfHour' => 0 }
      else
        raise ArgumentError, 'modern schedules support minutes, hours, or days'
      end
    end

    def project_security_doc(security)
      role_definitions = security.fetch(:user_roles, [])
      if role_definitions.empty?
        role_definitions = [
          { name: "Administrator", admin: true, module_roles: [] }
        ]
      end
      roles = role_definitions.map { user_role_doc(_1) }
      default_admin = role_definitions.find { _1[:admin] == true }&.fetch(:name, nil)
      default_admin ||= roles.first.fetch("Name")
      password_policy = {
        "$ID" => security[:password_policy_id].to_s.empty? ?
          SecureRandom.uuid : security[:password_policy_id].to_s,
        "$Type" => "Security$PasswordPolicySettings",
        "MinimumLength" => 6,
        "RequireDigit" => true,
        "RequireMixedCase" => true,
        "RequireSymbol" => false
      }
      security.fetch(:password_policy, {}).to_h.each do |key, value|
        native_key = {
          minimum_length: "MinimumLength",
          require_digit: "RequireDigit",
          require_mixed_case: "RequireMixedCase",
          require_symbol: "RequireSymbol"
        }.fetch(key.to_sym, key.to_s)
        password_policy[native_key] = value
      end
      {
        "$ID" => security[:id].to_s.empty? ? SecureRandom.uuid : security[:id].to_s,
        "$Type" => "Security$ProjectSecurity",
        "SecurityLevel" => security[:security_level] || "CheckNothing",
        "CheckSecurity" => true,
        "AdminUserName" => "MxAdmin",
        "AdminPassword" => "1",
        "AdminUserRole" => security[:admin_user_role] || default_admin,
        "EnableDemoUsers" => security.fetch(:demo_users_enabled, false) == true,
        "EnableGuestAccess" => security.fetch(:guest_access_enabled, false) == true,
        "GuestUserRole" => security[:guest_user_role].to_s,
        "SignInMicroflow" => security[:sign_in_microflow].to_s,
        "StrictMode" => false,
        "StrictPageUrlCheck" => true,
        "UserRoles" => IO::BsonCodec.build_array(roles, marker: 2),
        "DemoUsers" => IO::BsonCodec.build_array(
          Array(security[:demo_users]).map { demo_user_doc(_1) }, marker: 2
        ),
        "FileDocumentAccess" => access_container("Security$FileDocumentAccessRuleContainer"),
        "ImageAccess" => access_container("Security$ImageAccessRuleContainer"),
        "PasswordPolicySettings" => password_policy
      }
    end

    def user_role_doc(role)
      id = role[:id].to_s
      guid = role[:guid].to_s
      {
        "$ID" => id.empty? ? SecureRandom.uuid : id,
        "$Type" => "Security$UserRole",
        "Name" => role.fetch(:name),
        "Description" => role.fetch(:description, '').to_s,
        "CheckSecurity" => role.fetch(:check_security, true) == true,
        "GUID" => BSON::Binary.new(
          IO::BsonCodec.uuid_to_blob(guid.empty? ? SecureRandom.uuid : guid)
        ),
        "ManageableRoles" => IO::BsonCodec.build_array(
          Array(role[:manageable_roles]).map(&:to_s), marker: 1
        ),
        "ManageAllRoles" => role[:admin] == true,
        "ManageUsersWithoutRoles" => role.fetch(:manage_users_without_roles, false) == true,
        "ModuleRoles" => IO::BsonCodec.build_array(role.fetch(:module_roles, []), marker: 1)
      }
    end

    def demo_user_doc(user)
      {
        "$ID" => user[:id].to_s.empty? ? SecureRandom.uuid : user[:id].to_s,
        "$Type" => "Security$DemoUserImpl",
        "UserName" => user.fetch(:name),
        "Password" => user.fetch(:password),
        "Entity" => user.fetch(:entity),
        "UserRoles" => IO::BsonCodec.build_array(user.fetch(:roles), marker: 1)
      }
    end

    def module_security_doc(roles, legacy: false)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Security$ModuleSecurity",
        "ModuleRoles" => IO::BsonCodec.build_array(
          roles.map { module_role_doc(_1) }, marker: legacy ? 3 : 2
        )
      }
    end

    def module_role_doc(role)
      {
        "$ID" => role[:id].to_s.empty? ? SecureRandom.uuid : role[:id].to_s,
        "$Type" => "Security$ModuleRole",
        "Name" => role.fetch(:name),
        "Description" => role.fetch(:description, "")
      }
    end

    def access_container(type)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => type,
        "AccessRules" => IO::BsonCodec.build_array([])
      }
    end

    def menu_item_doc(item)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Menus$MenuItem",
        "Caption" => text_doc(item.fetch(:caption)),
        "Action" => item[:page] ? form_action_doc(item.fetch(:page)) : no_action_doc,
        "Icon" => nil,
        "Items" => IO::BsonCodec.build_array(item.fetch(:items, []).map { menu_item_doc(_1) })
      }
    end

    def form_action_doc(page)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$FormAction",
        "DisabledDuringExecution" => false,
        "FormSettings" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$FormSettings",
          "Form" => page.to_s,
          "ParameterMappings" => IO::BsonCodec.build_array([], marker: 2),
          "TitleOverride" => nil
        },
        "NumberOfPagesToClose2" => "",
        "PagesForSpecializations" => IO::BsonCodec.build_array([], marker: 2)
      }
    end

    def no_action_doc(disabled: false)
      {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$NoAction",
        "DisabledDuringExecution" => disabled
      }
    end

    def widget_doc(widget = nil, context_entity: nil, **keyword_widget)
      widget ||= keyword_widget
      type = widget.fetch(:type)
      widget = qualify_page_widget_attribute(widget, context_entity)

      if type == :snippet
        return snippet_call_doc(widget)
      end
      return pluggable_widget_doc(widget, data_grid2_descriptor) if type == :data_grid
      if %i[drop_down reference_selector].include?(type)
        return pluggable_widget_doc(widget, combo_box_descriptor)
      end
      if type == :pluggable_widget
        options = widget.fetch(:options)
        return pluggable_widget_doc(widget, {
          id: options.fetch(:widget_id), name: options.fetch(:widget_name),
          studio_category: "Custom", studio_pro_category: "Custom"
        })
      end
      if type == :native_widget
        options = widget.fetch(:options)
        return deep_copy(options.fetch(:deep_structure)).merge(
          "$ID" => SecureRandom.uuid, "$Type" => options.fetch(:native_type),
          "Name" => widget.fetch(:name)
        )
      end

      options = widget.fetch(:options, {})
      doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => widget_storage_type(type),
        "Name" => widget.fetch(:name),
        "Appearance" => appearance_doc(options.fetch(:class, "")),
        "Class" => "",
        "Style" => ""
      }
      doc["AttributePath"] = options[:attribute].to_s if options[:attribute]
      doc["LabelText"] = text_doc(options[:caption]) if input_widget?(type) && options.key?(:caption)
      doc["Caption"] = text_doc(options[:caption]) if type == :button
      doc["Content"] = client_template_doc(options[:caption]) if type == :text
      doc.merge!(modern_widget_properties(type, options))

      if type == :tab_control
        pages = tab_pages(options[:tabs])
        doc["TabPages"] = IO::BsonCodec.build_array(pages)
        doc["DefaultPagePointer"] = pages.first&.fetch("$ID", nil)
      end

      if type == :container
        children = Array(widget[:children]).map { widget_doc(_1, context_entity:) }
        doc["Widgets"] = IO::BsonCodec.build_array(children)
        doc["Class"] = options[:class].to_s if options[:class]
      end

      widget.fetch(:events, []).each do |event|
        doc[event_property(event.fetch(:event))] = client_action_doc(event)
      end
      doc
    end

    def qualify_page_widget_attribute(widget, context_entity)
      type = widget.fetch(:type).to_sym
      return widget unless input_widget?(type) || type == :drop_down

      attribute = widget.dig(:options, :attribute)
      return widget unless attribute

      qualified = qualified_attribute_identifier(attribute, context_entity)
      options = widget.fetch(:options, {}).merge(attribute: qualified)
      widget.merge(options:)
    end

    def page_context_entity(page, module_name)
      source = page[:data_source]
      entity = flow_return_entity(source&.dig(:name), module_name)
      return entity if entity

      attributes = simple_page_attributes(page.fetch(:widgets, []))
      return if attributes.empty?

      matching = module_entities(module_name).select do |candidate|
        names = candidate.fetch(:attributes, []).map { _1.fetch(:name).to_s }
        (attributes - names).empty?
      end
      return unless matching.one?

      "#{module_name}.#{matching.first.fetch(:name)}"
    end

    def simple_page_attributes(widgets)
      Array(widgets).flat_map do |widget|
        type = widget.fetch(:type).to_sym
        attribute = widget.dig(:options, :attribute).to_s
        own = if (input_widget?(type) || type == :drop_down) &&
                 !attribute.empty? && !attribute.include?('.') && !attribute.include?('/')
          [attribute]
        else
          []
        end
        own + simple_page_attributes(widget[:children])
      end.uniq
    end

    def flow_return_entity(name, module_name)
      return if name.to_s.empty?

      owner_name, flow_name = qualified_artifact_parts(name, module_name)
      owner = @definition.fetch(:modules, []).find { _1.fetch(:name).to_s == owner_name }
      flow = Array(owner&.fetch(:microflows, [])).find { _1.fetch(:name).to_s == flow_name }
      return unless flow

      entity = object_entity_type(flow[:return_type], owner_name)
      return entity if entity

      variables = flow_variable_entities(flow[:body], flow[:parameters], owner_name)
      variables[flow[:return_variable_name].to_s]
    end

    def qualified_artifact_parts(name, module_name)
      value = name.to_s
      value.include?('.') ? value.split('.', 2) : [module_name.to_s, value]
    end

    def module_entities(module_name)
      mod = @definition.fetch(:modules, []).find { _1.fetch(:name).to_s == module_name.to_s }
      Array(mod&.fetch(:entities, []))
    end

    def deep_copy(value)
      case value
      when Hash then value.to_h { |key, item| [key, deep_copy(item)] }
      when Array then value.map { deep_copy(_1) }
      else value
      end
    end

    def snippet_call_doc(widget)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$SnippetCallWidget",
        "Name" => widget.fetch(:name),
        "Appearance" => appearance_doc, "TabIndex" => 0,
        "FormCall" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$SnippetCall",
          "Form" => widget.dig(:options, :snippet).to_s,
          "ParameterMappings" => IO::BsonCodec.build_array([], marker: 2)
        }
      }
    end

    def input_widget?(type)
      %i[text_box number_input text_area check_box date_picker]
        .include?(type.to_sym)
    end

    def widget_storage_type(type)
      {
        button:             "Forms$ActionButton",
        text_box:           "Forms$TextBox",
        number_input:       "Forms$TextBox",
        text_area:          "Forms$TextArea",
        check_box:          "Forms$CheckBox",
        date_picker:        "Forms$DatePicker",
        text:               "Forms$DynamicText",
        tab_control:        "Forms$TabControl",
        container:          "Forms$DivContainer"
      }.fetch(type.to_sym)
    end

    def data_grid2_descriptor
      {
        id: "com.mendix.widget.web.datagrid.Datagrid", name: "Data grid 2",
        studio_category: "Data Containers", studio_pro_category: "Data containers"
      }
    end

    # A project created outside Studio Pro may not have the pluggable-widget
    # package available yet. These standard-shaped fallback fields preserve
    # the concise Ruby projection until Studio Pro can hydrate the widget.
    def configure_fallback_data_grid!(doc, options)
      entity = options[:entity].to_s
      columns = Array(options[:columns]).map do |column|
        attribute = column[:attribute].to_s
        attribute = "#{entity}.#{attribute}" if !entity.empty? && !attribute.empty? && !attribute.include?('.')
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DataGridColumn',
          'Name' => column[:name].to_s,
          'AttributeRef' => attribute_ref_doc(attribute),
          'Caption' => text_doc(column[:caption] || column[:name])
        }
      end
      toolbar = Array(options.dig(:toolbar, :buttons)).map do |button|
        kind = { new: 'New', delete: 'Delete', search: 'Search', export: 'ExportToExcel' }
               .fetch(button[:type].to_sym)
        {
          '$ID' => SecureRandom.uuid, '$Type' => "Forms$Grid#{kind}Button",
          'Caption' => text_doc(button[:caption].to_s)
        }
      end
      doc['DataSource'] = {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DatabaseSource', 'Entity' => entity
      }
      doc['Columns'] = IO::BsonCodec.build_array(columns)
      doc['ToolBar'] = {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$GridControlBar',
        'Buttons' => IO::BsonCodec.build_array(toolbar)
      }
      doc
    end

    def configure_fallback_combo_box!(doc, options)
      doc['AttributePath'] = options[:attribute].to_s if options[:attribute]
      doc['LabelText'] = text_doc(options[:caption]) if options.key?(:caption)
      doc['SelectorType'] = options[:__kind].to_sym == :reference_selector ? 'Reference' : 'Enumeration'
      doc['DisplayAttribute'] = options[:display_attribute].to_s if options[:display_attribute]
      doc
    end

    def combo_box_descriptor
      {
        id: "com.mendix.widget.web.combobox.Combobox", name: "Combo box",
        studio_category: "Input Widgets", studio_pro_category: "Input widgets"
      }
    end

    def pluggable_widget_doc(widget, descriptor)
      definition = WidgetPackage.find(File.dirname(@path), descriptor.fetch(:id))
      validate_official_data_grid2_contract!(widget, descriptor, definition)
      if definition
        type, object = WidgetPackage.template(definition)
      else
        object_type_id = SecureRandom.uuid
        object = {
          "$ID" => SecureRandom.uuid, "$Type" => "CustomWidgets$WidgetObject",
          "Properties" => IO::BsonCodec.build_array([], marker: 2),
          "TypePointer" => object_type_id
        }
        type = {
          "$ID" => SecureRandom.uuid, "$Type" => "CustomWidgets$CustomWidgetType",
          "HelpUrl" => "",
          "ObjectType" => {
            "$ID" => object_type_id, "$Type" => "CustomWidgets$WidgetObjectType",
            "PropertyTypes" => IO::BsonCodec.build_array([], marker: 2)
          },
          "OfflineCapable" => true, "StudioCategory" => descriptor.fetch(:studio_category),
          "StudioProCategory" => descriptor.fetch(:studio_pro_category),
          "SupportedPlatform" => "Web", "WidgetDescription" => "",
          "WidgetId" => descriptor.fetch(:id), "WidgetName" => descriptor.fetch(:name),
          "WidgetNeedsEntityContext" => false, "WidgetPluginWidget" => true
        }
      end
      doc = {
        "$ID" => SecureRandom.uuid, "$Type" => "CustomWidgets$CustomWidget",
        "Appearance" => appearance_doc(widget.dig(:options, :class).to_s),
        "ConditionalEditabilitySettings" => nil, "ConditionalVisibilitySettings" => nil,
        "Editable" => "Always", "LabelTemplate" => nil, "Name" => widget.fetch(:name),
        "Object" => object,
        "TabIndex" => 0,
        "Type" => type,
        "__mxrb_widget_options" => widget.fetch(:options, {}).merge(__kind: widget.fetch(:type))
      }
      options = doc.fetch('__mxrb_widget_options')
      configure_data_grid2!(doc, options) if descriptor.fetch(:id) == data_grid2_descriptor[:id]
      configure_combo_box!(doc, options) if descriptor.fetch(:id) == combo_box_descriptor[:id]
      configure_pluggable_widget!(doc, options) if widget.fetch(:type) == :pluggable_widget
      if definition.nil? && descriptor.fetch(:id) == data_grid2_descriptor[:id]
        configure_fallback_data_grid!(doc, options)
      end
      if definition.nil? && descriptor.fetch(:id) == combo_box_descriptor[:id]
        configure_fallback_combo_box!(doc, options)
      end
      widget.fetch(:events, []).each do |event|
        if descriptor.fetch(:id) == data_grid2_descriptor[:id] && event.fetch(:event).to_sym == :on_change
          property = custom_widget_properties(doc)['onSelectionChange']
          if property
            property['Value']['Action'] = client_action_doc(event)
          else
            doc[event_property(event.fetch(:event))] = client_action_doc(event)
          end
        else
          doc[event_property(event.fetch(:event))] = client_action_doc(event)
        end
      end
      doc
    end

    def validate_official_data_grid2_contract!(widget, descriptor, definition)
      return unless definition && descriptor.fetch(:id) == data_grid2_descriptor[:id]

      toolbar = Array(widget.dig(:options, :toolbar, :buttons))
      unless toolbar.empty?
        raise ValidationError,
              'Data Grid 2 toolbar buttons are not portable to the official widget schema; ' \
              'use explicit page buttons or a pluggable widget'
      end
      return unless widget.fetch(:events, []).any? { _1.fetch(:event).to_sym == :on_change }

      raise ValidationError,
            'Data Grid 2 on_change is not certified against the official widget schema; ' \
            'use an explicit action button to call the nanoflow or microflow'
    end

    def modern_widget_properties(type, options)
      case type.to_sym
      when :text
        {
          "ConditionalVisibilitySettings" => nil, "NativeAccessibilitySettings" => nil,
          "NativeTextStyle" => "Text", "RenderMode" => "Text", "TabIndex" => 0
        }
      when :container
        {
          "ConditionalVisibilitySettings" => nil, "NativeAccessibilitySettings" => nil,
          "OnClickAction" => no_action_doc(disabled: true), "RenderMode" => "Div",
          "ScreenReaderHidden" => false, "TabIndex" => 0
        }
      when :button
        {
          "Action" => no_action_doc(disabled: true), "AriaRole" => "Button", "ButtonStyle" => "Default",
          "CaptionTemplate" => client_template_doc(options[:caption]),
          "ConditionalVisibilitySettings" => nil, "Icon" => nil,
          "NativeAccessibilitySettings" => nil, "RenderType" => "Button", "TabIndex" => 0,
          "Tooltip" => text_doc("")
        }
      when :text_box, :number_input then text_box_properties(options)
      when :text_area               then text_area_properties(options)
      when :check_box                then check_box_properties(options)
      when :date_picker              then date_picker_properties(options)
      when :tab_control
        {
          "ActivePageAttributeRef" => nil, "ActivePageOnChangeAction" => no_action_doc,
          "ActivePageSourceVariable" => nil, "ConditionalVisibilitySettings" => nil,
          "TabIndex" => 0
        }
      else {}
      end
    end

    def text_box_properties(options)
      editable_widget_properties(options).merge(
        "Autocomplete" => true, "AutocompletePurpose" => "On", "AutoFocus" => false,
        "FormattingInfo" => formatting_info_doc, "InputMask" => "", "IsPasswordBox" => false,
        "KeyboardType" => "Default", "MaxLengthCode" => -1,
        "OnEnterKeyPressAction" => no_action_doc, "PlaceholderTemplate" => client_template_doc(""),
        "SubmitBehaviour" => "OnEndEditing", "SubmitOnInputDelay" => 300
      )
    end

    def text_area_properties(options)
      editable_widget_properties(options).merge(
        "AutoFocus" => false, "CounterMessage" => text_doc(""),
        "MaxLengthCode" => -1, "NumberOfLines" => options.fetch(:lines, 5),
        "PlaceholderTemplate" => client_template_doc("")
      )
    end

    def check_box_properties(options)
      editable_widget_properties(options).merge(
        "LabelPosition" => "Default", "NativeRenderMode" => "Switch"
      )
    end

    def date_picker_properties(options)
      editable_widget_properties(options).merge(
        "AutoFocus" => false, "FormattingInfo" => formatting_info_doc,
        "PlaceholderTemplate" => client_template_doc("")
      )
    end

    def editable_widget_properties(options)
      {
        "AriaRequired" => false, "AttributeRef" => attribute_ref_doc(options[:attribute]),
        "ConditionalEditabilitySettings" => nil, "ConditionalVisibilitySettings" => nil,
        "Editable" => "Always", "LabelTemplate" => client_template_doc(options[:caption]),
        "NativeAccessibilitySettings" => nil,
        "OnChangeAction" => no_action_doc, "OnEnterAction" => no_action_doc,
        "OnLeaveAction" => no_action_doc, "ReadOnlyStyle" => "Inherit",
        "ScreenReaderLabel" => nil, "SourceVariable" => nil, "TabIndex" => 0,
        "Validation" => widget_validation_doc
      }
    end

    def attribute_ref_doc(attribute, entity: nil)
      identifier = qualified_attribute_identifier(attribute, entity)
      return nil unless identifier

      {
        "$ID" => SecureRandom.uuid, "$Type" => "DomainModels$AttributeRef",
        "Attribute" => identifier, "EntityRef" => nil
      }
    end

    def qualified_attribute_identifier(attribute, entity = nil)
      value = attribute.to_s
      return if value.empty?

      value = value.tr('/', '.')
      return value if value.split('.').size >= 3
      return unless entity

      entity_name = qualified_entity_name(entity)
      return unless entity_name
      if value.include?('.') && value.split('.').first == entity_name.split('.').last
        return "#{entity_name.split('.').first}.#{value}"
      end
      return if value.include?('.')

      "#{entity_name}.#{value}"
    end

    def qualified_entity_name(entity, module_name = nil)
      value = entity.to_s
      return if value.empty?
      return value if value.include?('.')
      return unless module_name

      "#{module_name}.#{value}"
    end

    def formatting_info_doc
      {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$FormattingInfo",
        "CustomDateFormat" => "", "DateFormat" => "Date", "DecimalPrecision" => 2,
        "EnumFormat" => "Text", "GroupDigits" => false
      }
    end

    def widget_validation_doc
      {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$WidgetValidation",
        "Expression" => "", "Message" => text_doc("")
      }
    end

    def tab_pages(tabs)
      Array(tabs).map do |tab|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$TabPage",
          "Name" => tab.fetch(:name),
          "Caption" => text_doc(tab[:caption].to_s),
          "Widgets" => IO::BsonCodec.build_array(
            Array(tab[:widgets]).map { widget_doc(_1) }, marker: 2
          )
        }
      end
    end

    def event_property(event)
      {
        on_change: "OnChangeAction", on_click: "Action",
        on_enter: "OnEnterAction", on_leave: "OnLeaveAction",
        on_submit: "Action", on_load: "OnLoadAction"
      }.fetch(event.to_sym)
    end

    def client_action_doc(event)
      case event.fetch(:kind).to_sym
      when :action
        native_action_doc(event.fetch(:handler))
      when :page
        form_action_doc(event.fetch(:handler))
      when :nanoflow
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$CallNanoflowClientAction",
          "ConfirmationInfo" => nil, "DisabledDuringExecution" => true,
          "Nanoflow" => event.fetch(:handler),
          "OutputMappings" => IO::BsonCodec.build_array([], marker: 3),
          "ParameterMappings" => IO::BsonCodec.build_array([], marker: 2),
          "ProgressBar" => "None", "ProgressMessage" => nil
        }
      else
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$MicroflowAction",
          "MicroflowSettings" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Forms$MicroflowSettings",
            "Microflow" => event.fetch(:handler),
            "Asynchronous" => false, "ConfirmationInfo" => nil,
            "FormValidations" => "All",
            "OutputMappings" => IO::BsonCodec.build_array([], marker: 3),
            "ParameterMappings" => IO::BsonCodec.build_array([], marker: 2),
            "ProgressBar" => "None", "ProgressMessage" => nil
          },
          "DisabledDuringExecution" => true
        }
      end
    end

    def native_action_doc(handler)
      case handler.to_s
      when "save_changes"
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$SaveChangesClientAction",
          "DisabledDuringExecution" => true,
          "ClosePage" => true,
          "SyncAutomatically" => false
        }
      when "cancel_changes"
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$CancelChangesClientAction",
          "DisabledDuringExecution" => true,
          "ClosePage" => true
        }
      when "delete"
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$DeleteClientAction",
          "ClosePage" => false, "DisabledDuringExecution" => true,
          "SourceVariable" => nil
        }
      when "close_page"
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$ClosePageClientAction",
          "DisabledDuringExecution" => true, "NumberOfPagesToClose" => ""
        }
      else
        raise ArgumentError, "unsupported native action #{handler.inspect}"
      end
    end

    def data_view_doc(source, widgets)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$DataView",
        "Name" => "dataView",
        "Appearance" => appearance_doc, "ConditionalEditabilitySettings" => nil,
        "ConditionalVisibilitySettings" => nil, "DataSource" => data_view_source_doc(source),
        "Editability" => "Always", "FooterWidgets" => IO::BsonCodec.build_array([], marker: 2),
        "LabelWidth" => 0, "NoEntityMessage" => text_doc(""), "ReadOnlyStyle" => "Control",
        "ShowFooter" => false, "TabIndex" => 0,
        "Widgets" => IO::BsonCodec.build_array(widgets, marker: 2)
      }
    end

    def data_view_source_doc(source)
      if source.fetch(:kind).to_sym == :nanoflow
        {
          "$ID" => SecureRandom.uuid, "$Type" => "Forms$NanoflowSource",
          "ForceFullObjects" => false, "Nanoflow" => source.fetch(:name),
          "ParameterMappings" => IO::BsonCodec.build_array([], marker: 2)
        }
      else
        {
          "$ID" => SecureRandom.uuid, "$Type" => "Forms$MicroflowSource",
          "ForceFullObjects" => false,
          "MicroflowSettings" => client_microflow_settings_doc(source.fetch(:name))
        }
      end
    end

    def client_microflow_settings_doc(name)
      {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$MicroflowSettings",
        "Asynchronous" => false, "ConfirmationInfo" => nil, "FormValidations" => "All",
        "Microflow" => name, "OutputMappings" => IO::BsonCodec.build_array([], marker: 3),
        "ParameterMappings" => IO::BsonCodec.build_array([], marker: 2),
        "ProgressBar" => "None", "ProgressMessage" => nil
      }
    end

    def microflow_doc(flow, module_name = nil)
      flow_name = flow.fetch(:name)
      params = flow.fetch(:parameters).map do |param|
        { "$ID" => stable_id(flow_name, "parameter", param.fetch(:name)),
          "$Type" => "Microflows$MicroflowParameter",
          "DefaultValue" => "", "Documentation" => "",
          "HasVariableNameBeenChanged" => false, "IsRequired" => true,
          "Name" => param.fetch(:name), "RelativeMiddlePoint" => "0;0",
          "Size" => "30;30",
          "VariableType" => microflow_data_type_doc(param.fetch(:type), module_name) }
      end
      roles_declared  = !flow[:allowed_roles].nil?
      body_declared   = !flow[:body].nil? || !flow[:return_expression].nil?
      return_var_name = flow[:return_variable_name] || "ReturnValue"
      allow_concurrent = flow[:allow_concurrent_execution]
      apply_entity_access = flow[:apply_entity_access]
      mark_as_used = flow[:mark_as_used]
      excluded = flow[:excluded]

      body = qualify_flow_member_references(flow[:body], flow[:parameters], module_name)
      graph = build_microflow_graph(
        body, flow[:return_expression] || flow[:return_variable_name]
      )
      object_collection = {
        "$ID" => stable_id(flow_name, "object_collection"),
        "$Type" => "Microflows$MicroflowObjectCollection",
        "Objects" => IO::BsonCodec.build_array(params + graph[:objects])
      }

      { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$Microflow",
        "__mxrb_unit_id" => flow[:unit_id],
        "Name" => flow_name, "Documentation" => flow.fetch(:documentation, ""),
        "ReturnVariableName" => return_var_name,
        "AllowConcurrentExecution" => allow_concurrent.nil? ? true : allow_concurrent,
        "ApplyEntityAccess" => apply_entity_access.nil? ? false : apply_entity_access,
        "MarkAsUsed" => mark_as_used.nil? ? false : mark_as_used,
        "Excluded" => excluded.nil? ? false : excluded,
        "AllowedModuleRoles" => IO::BsonCodec.build_array(Array(flow[:allowed_roles]), marker: 1),
        "__mxrb_allowed_roles_declared" => roles_declared,
        "__mxrb_body_declared" => body_declared,
        "__mxrb_preserve_native_body" => flow[:preserve_native_body] == true,
        "__mxrb_allow_concurrent_execution_declared" => !allow_concurrent.nil?,
        "__mxrb_apply_entity_access_declared" => !apply_entity_access.nil?,
        "__mxrb_mark_as_used_declared" => !mark_as_used.nil?,
        "__mxrb_excluded_declared" => !excluded.nil?,
        "MicroflowReturnType" => microflow_data_type_doc(flow[:return_type], module_name),
        "ObjectCollection" => object_collection,
        "Flows" => IO::BsonCodec.build_array(graph[:flows]) }
    end

    def microflow_data_type_doc(type, module_name)
      if type.is_a?(Hash)
        return type.merge("$ID" => stable_id("data_type", module_name, type.to_s))
      end

      name = type.to_s
      native = case name.downcase
      when "", "void", "nil" then "DataTypes$VoidType"
      when "boolean", "bool" then "DataTypes$BooleanType"
      when "string" then "DataTypes$StringType"
      when "integer" then "DataTypes$IntegerType"
      when "long" then "DataTypes$LongType"
      when "decimal" then "DataTypes$DecimalType"
      when "float" then "DataTypes$FloatType"
      when "datetime", "date_time" then "DataTypes$DateTimeType"
      else
        "DataTypes$ObjectType"
      end
      doc = { "$ID" => stable_id("data_type", module_name, name), "$Type" => native }
      if native == "DataTypes$ObjectType"
        doc["Entity"] = name.include?(".") ? name : "#{module_name}.#{name}"
      end
      doc
    end

    def qualify_flow_member_references(body, parameters, module_name)
      variables = parameter_entity_types(parameters, module_name)
      qualify_activity_members(Array(body), variables, module_name).first
    end

    def flow_variable_entities(body, parameters, module_name)
      variables = parameter_entity_types(parameters, module_name)
      qualify_activity_members(Array(body), variables, module_name).last
    end

    def parameter_entity_types(parameters, module_name)
      Array(parameters).each_with_object({}) do |parameter, result|
        entity = object_entity_type(parameter[:type], module_name)
        result[parameter.fetch(:name).to_s] = entity if entity
      end
    end

    def object_entity_type(type, module_name)
      if type.is_a?(Hash)
        native = type['$Type'] || type[:'$Type']
        return unless native == 'DataTypes$ObjectType'

        return qualified_entity_name(type['Entity'] || type[:Entity], module_name)
      end

      value = type.to_s
      primitive = %w[
        void nil boolean bool string integer long decimal float datetime date_time
      ]
      return if value.empty? || primitive.include?(value.downcase) || value.include?('$')

      qualified_entity_name(value, module_name)
    end

    def qualify_activity_members(activities, inherited_variables, module_name)
      variables = inherited_variables.dup
      qualified = Array(activities).map do |activity|
        item = activity.dup
        type = item.fetch(:type).to_sym
        case type
        when :create_object, :retrieve_objects
          entity = qualified_entity_name(item[:entity], module_name)
          item[:entity] = entity if entity
          variables[item[:variable].to_s] = entity if entity
        when :retrieve_association
          entity = association_destination(item[:association])
          variables[item[:variable].to_s] = entity unless entity.to_s.empty?
        when :change_object
          item[:entity] ||= variables[item[:variable].to_s]
        when :decision
          item = qualify_decision_activity(item, variables, module_name)
        when :inheritance_decision
          item[:branches] = item.fetch(:branches).transform_values do |branch|
            qualify_activity_members(branch, variables, module_name).first
          end
        when :loop_over
          loop_variables = variables.dup
          iterator_entity = variables[item[:variable].to_s]
          loop_variables[item[:iterator].to_s] = iterator_entity if iterator_entity
          item[:activities] = qualify_activity_members(
            item[:activities], loop_variables, module_name
          ).first
        when :while_loop, :rescue_all
          item[:activities] = qualify_activity_members(
            item[:activities], variables, module_name
          ).first
        end
        item
      end
      [qualified, variables]
    end

    def qualify_decision_activity(activity, variables, module_name)
      item = activity.dup
      if item[:branches]
        item[:branches] = item.fetch(:branches).transform_values do |branch|
          qualify_activity_members(branch, variables, module_name).first
        end
      else
        item[:true_branch] = qualify_activity_members(
          item[:true_branch], variables, module_name
        ).first
        item[:false_branch] = qualify_activity_members(
          item[:false_branch], variables, module_name
        ).first
      end
      item
    end

    def build_microflow_graph(body, return_expression)
      objects = []
      flows   = []

      start_id = SecureRandom.uuid
      objects << flow_object_doc(start_id, "Microflows$StartEvent", 50, 100, "20;20")

      prev_id = start_id
      x = 190

      # Separate rescue_all from regular items (rescue_all must be last)
      main_items   = Array(body).reject { _1[:type].to_sym == :rescue_all }
      rescue_block = Array(body).find   { _1[:type].to_sym == :rescue_all }

      main_items.each_with_index do |activity, i|
        is_last    = i == main_items.size - 1
        error_type = (rescue_block && is_last) ? "Custom" : "None"
        prev_id, x = process_activity(activity, prev_id, objects, flows, x, 100, error_type: error_type)
      end

      last_main_id = prev_id

      end_id    = SecureRandom.uuid
      end_value = return_expression.to_s
      if prev_id
        objects << flow_object_doc(end_id, "Microflows$EndEvent", x, 100, "20;20").merge(
          "Documentation" => "", "ReturnValue" => end_value
        )
        flows << sequence_flow_doc(prev_id, end_id)
      end

      if rescue_block
        x_err   = 190
        y_err   = 250
        err_pid = last_main_id
        terminal = false
        Array(rescue_block[:activities]).each_with_index do |act, i|
          act_id = SecureRandom.uuid
          object = case act[:type].to_sym
          when :return_event
            terminal = true
            flow_object_doc(
              act_id, "Microflows$EndEvent", x_err, y_err, "20;20"
            ).merge("Documentation" => "", "ReturnValue" => act[:expression].to_s)
          when :error_event
            terminal = true
            flow_object_doc(act_id, "Microflows$ErrorEvent", x_err, y_err, "20;20")
          when :continue_event
            terminal = true
            flow_object_doc(act_id, "Microflows$ContinueEvent", x_err, y_err, "20;20")
          else
            build_activity(act, act_id, x_err, y_err)
          end
          objects << object
          if i == 0
            error_flow = sequence_flow_doc(err_pid, act_id)
            mark_error_flow!(error_flow)
            flows << error_flow
          else
            flows << sequence_flow_doc(err_pid, act_id)
          end
          err_pid = act_id
          x_err  += 140
        end
        unless terminal
          err_end_id = SecureRandom.uuid
          objects << flow_object_doc(
            err_end_id, "Microflows$EndEvent", x_err, y_err, "20;20"
          ).merge("Documentation" => "", "ReturnValue" => "")
          flows << sequence_flow_doc(err_pid, err_end_id)
        end
      end

      { objects: objects, flows: flows }
    end

    def process_activity(activity, prev_id, objects, flows, x, y, error_type: "None")
      case activity[:type].to_sym
      when :decision
        process_decision(activity, prev_id, objects, flows, x, y)
      when :inheritance_decision
        process_inheritance_decision(activity, prev_id, objects, flows, x, y)
      when :loop_over, :while_loop
        act_id = SecureRandom.uuid
        objects << loop_activity_doc(activity, act_id, x, y, flows)
        flows << sequence_flow_doc(prev_id, act_id) if prev_id
        [act_id, x + 140]
      when :return_event, :error_event, :continue_event
        act_id = SecureRandom.uuid
        type = {
          return_event: "Microflows$EndEvent",
          error_event: "Microflows$ErrorEvent",
          continue_event: "Microflows$ContinueEvent"
        }.fetch(activity[:type].to_sym)
        object = flow_object_doc(act_id, type, x, y, "20;20")
        if activity[:type].to_sym == :return_event
          object["Documentation"] = ""
          object["ReturnValue"] = activity[:expression].to_s
        end
        objects << object
        flows << sequence_flow_doc(prev_id, act_id) if prev_id
        [nil, x + 140]
      else
        act_id = SecureRandom.uuid
        objects << build_activity(activity, act_id, x, y, error_type: error_type)
        flows << sequence_flow_doc(prev_id, act_id) if prev_id
        [act_id, x + 140]
      end
    end

    def process_decision(activity, prev_id, objects, flows, x, y)
      split_id  = SecureRandom.uuid
      branches = activity[:branches] || {
        true => Array(activity[:true_branch]),
        false => Array(activity[:false_branch])
      }

      objects << flow_object_doc(
        split_id, "Microflows$ExclusiveSplit", x, y, "90;60"
      ).merge(
                   "SplitCondition" => split_condition_doc(activity[:condition]),
                   "Caption" => activity[:condition],
                   "ErrorHandlingType" => "Rollback",
                   "Documentation" => "")
      flows << sequence_flow_doc(prev_id, split_id) if prev_id

      branch_width = [branches.values.map(&:size).max.to_i, 1].max
      x_branch = x + 140
      x_merge  = x + 140 * (branch_width + 1)
      results = branches.each_with_index.map do |(case_value, activities), index|
        process_decision_branch(
          Array(activities), split_id, case_value,
          objects, flows, x_branch, y + index * 150
        )
      end
      return [nil, x_merge + 140] if results.all? { _1[:terminal] }

      merge_id = SecureRandom.uuid
      objects << flow_object_doc(
        merge_id, "Microflows$ExclusiveMerge", x_merge, y, "40;40"
      )
      results.each do |result|
        if result[:first].nil?
          flows << decision_flow_doc(split_id, merge_id, result[:case])
        elsif !result[:terminal]
          flows << sequence_flow_doc(result[:last], merge_id)
        end
      end
      [merge_id, x_merge + 140]
    end

    def split_condition_doc(condition)
      unless condition.is_a?(Hash)
        return {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$ExpressionSplitCondition",
          "Expression" => condition
        }
      end

      mappings = condition.fetch(:pass, {}).map do |parameter, argument|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$RuleCallParameterMapping",
          "Parameter" => parameter.to_s,
          "Argument" => member_value_expr(argument)
        }
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$RuleSplitCondition",
        "RuleCall" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$RuleCall",
          "Microflow" => condition[:rule].to_s,
          "ParameterMappings" => IO::BsonCodec.build_array(mappings, marker: 2)
        }
      }
    end

    def process_decision_branch(activities, split_id, case_value, objects, flows, x, y)
      first = nil
      previous = nil
      terminal = false
      activities.each do |activity|
        break if terminal

        if activity[:type].to_sym == :rescue_all
          build_rescue_branch(
            previous, activity[:activities], objects, flows, x, y + 120
          )
          next
        end

        before = objects.size
        next_id, next_x = process_activity(
          activity, previous, objects, flows, x, y
        )
        created_first = objects[before]&.dig("$ID")
        first ||= created_first
        unless previous
          flows << decision_flow_doc(split_id, created_first, case_value)
        end
        terminal = next_id.nil?
        previous = next_id
        x = next_x
      end
      { first: first, last: previous, terminal: terminal, case: case_value }
    end

    def build_rescue_branch(origin_id, activities, objects, flows, x, y)
      return unless origin_id

      origin = objects.find { _1["$ID"] == origin_id }
      if origin&.dig("Action").is_a?(Hash)
        origin["Action"]["ErrorHandlingType"] = custom_error_handling_type
      end
      previous = nil
      Array(activities).each do |activity|
        before = objects.size
        next_id, x = process_activity(
          activity, previous, objects, flows, x, y
        )
        created_first = objects[before]&.dig("$ID")
        unless previous
          error_flow = sequence_flow_doc(origin_id, created_first)
          mark_error_flow!(error_flow)
          flows << error_flow
        end
        previous = next_id
        break unless previous
      end
    end

    def process_inheritance_decision(activity, prev_id, objects, flows, x, y)
      split_id = SecureRandom.uuid
      branches = activity.fetch(:branches)
      objects << flow_object_doc(
        split_id, "Microflows$InheritanceSplit", x, y, "60;40"
      ).merge(
        "Caption" => "", "Documentation" => "",
        "SplitVariableName" => activity[:variable]
      )
      flows << sequence_flow_doc(prev_id, split_id) if prev_id
      width = [branches.values.map(&:size).max.to_i, 1].max
      x_merge = x + 140 * (width + 1)
      results = branches.each_with_index.map do |(case_value, activities), index|
        process_decision_branch(
          Array(activities), split_id, case_value,
          objects, flows, x + 140, y + index * 150
        ).tap { _1[:case_kind] = :inheritance }
      end
      # Replace the just-created enumeration case documents with inheritance
      # cases. Their edge endpoints remain unchanged.
      flows.select { _1["OriginPointer"] == split_id }.each do |flow|
        set_flow_case(flow, flow_case_raw_value(flow), kind: :inheritance)
      end
      return [nil, x_merge + 140] if results.all? { _1[:terminal] }

      merge_id = SecureRandom.uuid
      objects << flow_object_doc(
        merge_id, "Microflows$ExclusiveMerge", x_merge, y, "40;40"
      )
      results.each do |result|
        if result[:first].nil?
          flow = decision_flow_doc(split_id, merge_id, result[:case])
          set_flow_case(flow, result[:case], kind: :inheritance)
          flows << flow
        elsif !result[:terminal]
          flows << sequence_flow_doc(result[:last], merge_id)
        end
      end
      [merge_id, x_merge + 140]
    end

    def loop_activity_doc(activity, id, x, y, all_flows)
      inner_objs  = []
      i_prev = nil
      i_x    = 50
      started = false
      Array(activity[:activities]).each do |act|
        break if started && i_prev.nil?

        i_prev, i_x = process_activity(
          act, i_prev, inner_objs, all_flows, i_x, 100
        )
        started = true
      end

      source = if activity[:type].to_sym == :while_loop
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$WhileLoopCondition",
          "WhileExpression" => activity[:condition]
        }
      else
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$IterableList",
          "ListVariableName" => activity[:variable],
          "VariableName" => activity[:iterator]
        }
      end
      doc = flow_object_doc(id, "Microflows$LoopedActivity", x, y, "300;200").merge(
        "ErrorHandlingType" => "Rollback",
        "ObjectCollection" => {
          "$ID" => SecureRandom.uuid, "$Type" => "Microflows$MicroflowObjectCollection",
          "Objects" => IO::BsonCodec.build_array(inner_objs)
        })
      major = @definition.fetch(:version).to_s.split(".").first.to_i
      if major < 8 && activity[:type].to_sym == :loop_over
        doc["ListVariableName"] = activity[:variable]
        doc["IteratorVariableName"] = activity[:iterator]
        doc["Documentation"] = ""
      else
        doc["LoopSource"] = source
      end
      doc
    end

    def decision_flow_doc(split_id, to_id, value)
      sequence_flow_doc(split_id, to_id, case_value: value)
    end

    def flow_case_raw_value(flow)
      array_items(flow["CaseValues"]).first&.dig("Value") ||
        flow.dig("NewCaseValue", "Value") || ""
    end

    def set_flow_case(flow, value, kind:)
      case_doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => kind == :inheritance ?
          "Microflows$InheritanceCase" : "Microflows$EnumerationCase",
        "Value" => value.to_s
      }
      major = @definition.fetch(:version).to_s.split(".").first.to_i
      if major >= 10
        flow["CaseValues"] = IO::BsonCodec.build_array([case_doc], marker: 2)
        flow.delete("NewCaseValue")
      else
        flow["NewCaseValue"] = case_doc
        flow.delete("CaseValues")
      end
      flow
    end

    def sequence_flow_doc(from_id, to_id, case_value: nil)
      major = @definition.fetch(:version).to_s.split(".").first.to_i
      case_doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => case_value.nil? ? "Microflows$NoCase" : "Microflows$EnumerationCase"
      }
      case_doc["Value"] = case_value.to_s unless case_value.nil?
      doc = {
        "$ID" => SecureRandom.uuid, "$Type" => "Microflows$SequenceFlow",
        "OriginPointer" => from_id, "DestinationPointer" => to_id,
        "OriginConnectionIndex" => 1, "DestinationConnectionIndex" => 3,
        "IsErrorHandler" => false
      }
      if major >= 10
        doc["Line"] = {
          "$ID" => SecureRandom.uuid, "$Type" => "Microflows$BezierCurve",
          "OriginControlVector" => "0;0", "DestinationControlVector" => "0;0"
        }
        doc["CaseValues"] = IO::BsonCodec.build_array([case_doc], marker: 2)
      else
        doc["OriginBezierVector"] = "30;0"
        doc["DestinationBezierVector"] = "-30;0"
        doc["NewCaseValue"] = case_doc
      end
      doc
    end

    def mark_error_flow!(flow)
      flow["IsErrorHandler"] = true
      flow["OriginConnectionIndex"] = 2
      flow["DestinationConnectionIndex"] = 0
      if flow["Line"]
        flow["Line"]["OriginControlVector"] = "0;30"
        flow["Line"]["DestinationControlVector"] = "0;-15"
      else
        flow["OriginBezierVector"] = "0;30"
        flow["DestinationBezierVector"] = "0;-15"
      end
      flow
    end

    def build_activity(activity, id, x, y, error_type: "None")
      action = activity_action_doc(activity)
      doc = flow_object_doc(id, "Microflows$ActionActivity", x, y, "120;60").merge(
        "Documentation" => "",
        "AutoGenerateCaption" => true, "BackgroundColor" => "Default",
        "Caption" => "Activity", "Action" => action
      )
      action["ErrorHandlingType"] = custom_error_handling_type if error_type == "Custom"
      doc
    end

    def custom_error_handling_type
      major = @definition.fetch(:version).to_s.split(".").first.to_i
      major >= 9 ? "CustomWithoutRollBack" : "Custom"
    end

    def flow_object_doc(id, type, x, y, size)
      {
        "$ID" => id, "$Type" => type,
        "RelativeMiddlePoint" => "#{x};#{y}", "Size" => size
      }
    end

    def activity_action_doc(activity)
      case activity[:type].to_sym
      when :create_object
        commit = if activity[:commit] == true
          activity[:with_events] == false ? "YesWithoutEvents" : "Yes"
        else
          "No"
        end
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$CreateChangeAction",
          "Commit" => commit,
          "Entity" => activity[:entity], "ErrorHandlingType" => "Rollback",
          "Items" => IO::BsonCodec.build_array(
            Array(activity[:members]).map { change_action_item_doc(_1, entity: activity[:entity]) },
            marker: 2
          ),
          "RefreshInClient" => activity[:refresh] == true,
          "VariableName" => activity[:variable] }
      when :change_object
        commit = if activity[:commit] == true
          activity[:with_events] == false ? "YesWithoutEvents" : "Yes"
        else
          "No"
        end
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ChangeAction",
          "ChangeVariableName" => activity[:variable],
          "Commit" => commit,
          "ErrorHandlingType" => "Rollback",
          "Items" => IO::BsonCodec.build_array(
            Array(activity[:members]).map do |member|
              change_action_item_doc(member, entity: activity[:entity])
            end, marker: 2
          ),
          "RefreshInClient" => activity[:refresh] == true }
      when :retrieve_objects
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$RetrieveAction",
          "ErrorHandlingType" => "Rollback",
          "ResultVariableName" => activity[:variable],
          "RetrieveSource" => {
            "$ID" => SecureRandom.uuid, "$Type" => "Microflows$DatabaseRetrieveSource",
            "Entity" => activity[:entity],
            "NewSortings" => {
              "$ID" => SecureRandom.uuid, "$Type" => "Microflows$SortingsList",
              "Sortings" => IO::BsonCodec.build_array(
                Array(activity[:sortings]).map { retrieve_sorting_doc(_1) }, marker: 2
              )
            },
            "Range" => retrieve_range_doc(activity),
            "XpathConstraint" => activity[:xpath] || ""
          } }
      when :retrieve_association
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$RetrieveAction",
          "ErrorHandlingType" => "Rollback",
          "ResultVariableName" => activity[:variable],
          "RetrieveSource" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$AssociationRetrieveSource",
            "AssociationId" => activity[:association],
            "StartVariableName" => activity[:start_variable]
          } }
      when :commit
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$CommitAction",
          "CommitVariableName" => activity[:variable],
          "ErrorHandlingType" => "Rollback",
          "RefreshInClient" => activity[:refresh] == true,
          "WithEvents" => activity[:with_events] == true }
      when :delete_object
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$DeleteAction",
          "DeleteVariableName" => activity[:variable],
          "ErrorHandlingType" => "Rollback",
          "RefreshInClient" => activity[:refresh] == true }
      when :call_microflow
        major = @definition.fetch(:version).to_s.split(".").first.to_i
        result_name = activity[:result_name] || activity[:variable].to_s
        mappings = Array(activity[:mappings]).map do |m|
          parameter = m[:param].to_s
          parameter = "#{activity[:name]}.#{parameter}" unless parameter.include?('.')
          mapping = {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$MicroflowCallParameterMapping",
            "Parameter" => parameter,
            "Argument" => member_value_expr(m[:value])
          }
          mapping["ArgumentModel"] = no_expression_doc if major.between?(6, 10)
          mapping
        end
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$MicroflowCallAction",
          "ErrorHandlingType" => "Rollback",
          "UseReturnVariable" => activity[:use_return] == true,
          "ResultVariableName" => result_name,
          "MicroflowCall" => {
            "$ID" => SecureRandom.uuid, "$Type" => "Microflows$MicroflowCall",
            "Microflow" => activity[:name],
            "ParameterMappings" => IO::BsonCodec.build_array(mappings, marker: 2)
          }.tap { |call| call["Queue"] = "" if major.between?(8, 9) } }
      when :create_variable
        doc = { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$CreateVariableAction",
          "ErrorHandlingType" => "Rollback",
          "InitialValue" => member_value_expr(activity[:value]),
          "InitialValueModel" => no_expression_doc,
          "VariableName" => activity[:variable] }
        doc["VariableType"] = variable_type_doc(activity[:variable_type]) if activity[:variable_type]
        doc
      when :change_variable
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ChangeVariableAction",
          "ChangeVariableName" => activity[:variable],
          "ErrorHandlingType" => "Rollback",
          "Value" => member_value_expr(activity[:value]),
          "ValueModel" => no_expression_doc }
      when :show_message
        translations = activity[:translations] || { "en_US" => activity[:text] }
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ShowMessageAction",
          "Blocking" => activity[:blocking] == true,
          "ErrorHandlingType" => "Rollback",
          "Template" => {
            "$ID" => SecureRandom.uuid, "$Type" => "Microflows$TextTemplate",
            "Parameters" => IO::BsonCodec.build_array(
              template_parameter_docs(activity[:parameters]), marker: 2
            ),
            "Text" => localized_text_doc(translations)
          },
          "Type" => activity[:message_type].to_s.capitalize }
      when :log_message
        major = @definition.fetch(:version).to_s.split('.').first.to_i
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$LogMessageAction",
          "ErrorHandlingType" => "Rollback",
          "IncludeLatestStackTrace" => activity[:include_stack] == true,
          "Level" => activity[:level].to_s.capitalize,
          "MessageTemplate" => {
            "$ID" => SecureRandom.uuid, "$Type" => "Microflows$StringTemplate",
            "Parameters" => IO::BsonCodec.build_array(
              template_parameter_docs(activity[:parameters]), marker: 2
            ),
            "Text" => activity[:message]
          },
          "Node" => activity[:node] || "'MXRB'" }.tap do |document|
            document['NodeModel'] = no_expression_doc if major.between?(6, 10)
          end
      when :show_page
        show_form_action_doc(activity)
      when :close_page
        close_form_action_doc(activity)
      when :call_java
        java_action_call_doc(activity)
      when :call_javascript
        javascript_action_call_doc(activity)
      when :call_nanoflow
        nanoflow_call_doc(activity)
      when :call_app_service
        app_service_call_doc(activity)
      when :aggregate
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$AggregateAction",
          "AggregateFunction" => mendix_enum(activity[:function]),
          "AggregateVariableName" => activity[:variable],
          "Attribute" => activity[:attribute].to_s,
          "ErrorHandlingType" => "Rollback",
          "VariableName" => activity[:output] }
      when :rollback
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$RollbackAction",
          "ErrorHandlingType" => "Rollback",
          "RefreshInClient" => activity[:refresh] == true,
          "RollbackVariableName" => activity[:variable] }
      when :cast
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$CastAction",
          "ErrorHandlingType" => "Rollback",
          "VariableName" => activity[:variable] }
      when :create_list
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$CreateListAction",
          "Entity" => activity[:entity], "ErrorHandlingType" => "Rollback",
          "VariableName" => activity[:variable] }
      when :list_operation
        operation = {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$#{mendix_enum(activity[:operation])}",
          "ListName" => activity[:variable]
        }
        operation["SecondListOrObjectName"] = activity[:second] if activity[:second]
        operation["Expression"] = activity[:expression] if activity[:expression]
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ListOperationsAction",
          "ErrorHandlingType" => "Rollback",
          "NewOperation" => operation,
          "ResultVariableName" => activity[:output] }
      when :change_list
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ChangeListAction",
          "ChangeVariableName" => activity[:variable],
          "ErrorHandlingType" => "Rollback",
          "Type" => mendix_enum(activity[:action]),
          "Value" => member_value_expr(activity[:value]) }
      when :validation_feedback
        validation_feedback_action_doc(activity)
      when :call_rest
        rest_call_action_doc(activity)
      when :execute_database_query
        database_query_action_doc(activity)
      when :import_xml
        import_xml_action_doc(activity)
      when :download_file
        download_file_action_doc(activity)
      end
    end

    def database_query_action_doc(activity)
      if activity[:query].to_s.empty? && activity[:dynamic_query].to_s.empty?
        raise ValidationError, "database query action requires query or dynamic_query"
      end

      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "DatabaseConnector$ExecuteDatabaseQueryAction",
        "ConnectionParameterMappings" => database_query_parameter_docs(
          activity[:connection_parameters], "DatabaseConnector$ConnectionParameterMapping"
        ),
        "DynamicQuery" => member_value_expr(activity[:dynamic_query]),
        "ErrorHandlingType" => mendix_enum(activity[:error]),
        "OutputVariableName" => activity[:variable].to_s,
        "ParameterMappings" => database_query_parameter_docs(
          activity[:parameters], "DatabaseConnector$QueryParameterMapping"
        ),
        "Query" => activity[:query].to_s
      }
    end

    def database_query_parameter_docs(mappings, type)
      documents = Array(mappings).map do |mapping|
        {
          "$ID" => SecureRandom.uuid, "$Type" => type,
          "ParameterName" => mapping.fetch(:name).to_s,
          "Value" => member_value_expr(mapping[:value])
        }
      end
      IO::BsonCodec.build_array(documents, marker: 2)
    end

    def import_xml_action_doc(activity)
      if activity[:variable].to_s.empty? || activity[:mapping].to_s.empty? ||
         activity[:output].to_s.empty? || activity[:result_entity].to_s.empty?
        raise ValidationError,
              "import_xml requires document, mapping, as, and result_entity"
      end

      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$ImportXmlAction",
        "ResultHandling" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$ResultHandling",
          "Bind" => true,
          "ImportMappingCall" => import_mapping_call_doc(activity),
          "ResultVariableName" => activity[:output].to_s,
          "VariableType" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "DataTypes$ObjectType",
            "Entity" => activity[:result_entity].to_s
          }
        },
        "IsValidationRequired" => activity[:validate] == true,
        "XmlDocumentVariableName" => activity[:variable].to_s,
        "ErrorHandlingType" => mendix_enum(activity[:error])
      }
    end

    def import_mapping_call_doc(activity)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$ImportMappingCall",
        "Commit" => mendix_enum(activity[:commit]),
        "ContentType" => mendix_enum(activity[:content_type]),
        "ForceSingleOccurrence" => activity[:force_single] == true,
        "ObjectHandlingBackup" => mendix_enum(activity[:object_handling]),
        "ParameterVariableName" => activity[:parameter_variable].to_s,
        "Range" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$ConstantRange",
          "SingleObject" => activity[:single] == true
        },
        "ReturnValueMapping" => activity[:mapping].to_s
      }
    end

    def download_file_action_doc(activity)
      raise ValidationError, "download_file requires a variable" if activity[:variable].to_s.empty?

      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$DownloadFileAction",
        "FileDocumentVariableName" => activity[:variable].to_s,
        "ShowFileInBrowser" => activity[:show_in_browser] == true,
        "ErrorHandlingType" => mendix_enum(activity[:error])
      }
    end

    def rest_call_action_doc(activity)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$RestCallAction",
        "ErrorHandlingType" => mendix_enum(activity[:error]),
        "ErrorResultHandlingType" => mendix_enum(activity[:error_result]),
        "HttpConfiguration" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$HttpConfiguration",
          "ClientCertificate" => "",
          "CustomLocation" => "",
          "CustomLocationTemplate" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$StringTemplate",
            "Parameters" => IO::BsonCodec.build_array(
              template_parameter_docs(activity[:location_parameters]), marker: 2
            ),
            "Text" => activity[:location]
          },
          "HttpAuthenticationPassword" => "",
          "HttpAuthenticationUserName" => "",
          "HttpHeaderEntries" => IO::BsonCodec.build_array(
            activity[:headers].map do |key, value|
              {
                "$ID" => SecureRandom.uuid,
                "$Type" => "Microflows$HttpHeaderEntry",
                "Key" => key, "Value" => value
              }
            end
          ),
          "HttpMethod" => mendix_enum(activity[:method]),
          "OverrideLocation" => true,
          "UseHttpAuthentication" => false
        },
        "ProxyConfiguration" => nil,
        "RequestHandling" => rest_request_handling_doc(activity),
        "RequestHandlingType" => activity[:request_body].nil? ? "Mapping" : "Custom",
        "RequestProxyType" => "DefaultProxy",
        "ResultHandling" => rest_result_handling_doc(activity),
        "ResultHandlingType" => mendix_enum(activity.fetch(:result_handling, "mapping")),
        "TimeOutExpression" => activity[:timeout].to_s,
        "UseRequestTimeOut" => !activity[:timeout].to_s.empty?
      }
    end

    def rest_request_handling_doc(activity)
      unless activity[:request_body].nil?
        return {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$CustomRequestHandling",
          "Template" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$StringTemplate",
            "Parameters" => IO::BsonCodec.build_array(
              template_parameter_docs(activity[:request_parameters]), marker: 2
            ),
            "Text" => activity[:request_body].to_s
          }
        }
      end

      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$MappingRequestHandling",
        "ContentType" => "Json",
        "MappingId" => activity[:request_mapping].to_s,
        "MappingVariableName" => activity[:request_variable].to_s
      }
    end

    def rest_result_handling_doc(activity)
      if activity.fetch(:result_handling, "mapping").to_s == "http_response"
        if activity[:variable].to_s.empty? || activity[:result_entity].to_s.empty?
          raise ValidationError,
                "HTTP response result handling requires as and result_entity"
        end

        return {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$ResultHandling",
          "Bind" => true,
          "ImportMappingCall" => nil,
          "ResultVariableName" => activity[:variable].to_s,
          "VariableType" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "DataTypes$ObjectType",
            "Entity" => activity[:result_entity].to_s
          }
        }
      end

      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$ResultHandling",
        "Bind" => !activity[:variable].to_s.empty?,
        "ImportMappingCall" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$ImportMappingCall",
          "Commit" => mendix_enum(activity[:commit]),
          "ContentType" => mendix_enum(activity.fetch(:result_content_type, 'json')),
          "ForceSingleOccurrence" => activity[:force_single] == true,
          "ObjectHandlingBackup" => mendix_enum(activity.fetch(:object_handling, 'create')),
          "ParameterVariableName" => activity[:parameter_variable].to_s,
          "Range" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$ConstantRange",
            "SingleObject" => activity[:single] == true
          },
          "ReturnValueMapping" => activity[:result_mapping].to_s
        },
        "ResultVariableName" => activity[:variable].to_s,
        "VariableType" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "DataTypes$ObjectType",
          "Entity" => activity[:result_entity].to_s
        }
      }
    end

    def show_form_action_doc(activity)
      major = @definition.fetch(:version).to_s.split(".").first.to_i
      settings = {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$FormSettings",
        "Form" => activity[:page]
      }
      if major >= 11
        settings["ParameterMappings"] = IO::BsonCodec.build_array(
          Array(activity[:mappings]).map { page_parameter_mapping_doc(_1) }, marker: 2
        )
        settings["TitleOverride"] = page_title_template_doc(activity[:title])
      elsif major >= 8
        settings["TitleOverride"] = activity[:title] ?
          localized_text_doc(activity[:title]) : nil
      else
        settings["FormTitle"] = activity[:title] ?
          localized_text_doc(activity[:title]) : nil
        settings["Location"] = mendix_enum(activity[:location] || "Content")
      end

      doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$ShowFormAction",
        "ErrorHandlingType" => "Rollback",
        "FormSettings" => settings
      }
      doc["FormObjectVariable"] = activity[:variable].to_s unless major >= 11 || activity[:variable].to_s.empty?
      doc["NumberOfPagesToClose"] = activity[:close_pages].to_s if major >= 8
      doc
    end

    def page_title_template_doc(translations)
      return nil unless translations

      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$TextTemplate",
        "Text" => localized_text_doc(translations),
        "Parameters" => IO::BsonCodec.build_array([], marker: 2)
      }
    end

    def retrieve_range_doc(activity)
      limit = activity[:limit]
      if limit
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$CustomRange",
          "LimitExpression" => limit.to_s,
          "OffsetExpression" => ""
        }
      else
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$ConstantRange",
          "SingleObject" => activity[:single] == true
        }
      end
    end

    def retrieve_sorting_doc(sorting)
      attribute, order = Array(sorting)
      major, minor = @definition.fetch(:version).to_s.split(".").map(&:to_i)
      doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$RetrieveSorting",
        "SortOrder" => mendix_enum(order || "Ascending")
      }
      if major > 7 || (major == 7 && minor >= 11)
        doc["AttributeRef"] = {
          "$ID" => SecureRandom.uuid,
          "$Type" => "DomainModels$AttributeRef",
          "Attribute" => attribute.to_s,
          "EntityRef" => nil
        }
      else
        doc["AttributePath"] = attribute.to_s
      end
      doc
    end

    def close_form_action_doc(activity)
      major = @definition.fetch(:version).to_s.split(".").first.to_i
      doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$CloseFormAction",
        "ErrorHandlingType" => "Rollback"
      }
      doc["NumberOfPagesToClose"] = activity[:count].to_s if major >= 8
      doc
    end

    def page_parameter_mapping_doc(mapping)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$PageParameterMapping",
        "Argument" => member_value_expr(mapping[:value]),
        "Parameter" => mapping[:parameter],
        "Variable" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$PageVariable",
          "PageParameter" => "",
          "SnippetParameter" => "",
          "UseAllPages" => false,
          "Widget" => ""
        }
      }
    end

    def mendix_enum(value)
      value.to_s.split("_").map(&:capitalize).join
    end

    def java_action_call_doc(activity)
      major, minor = @definition.fetch(:version).to_s.split(".").map(&:to_i)
      result_name = activity[:result_name] || activity[:variable].to_s
      value_type = major >= 8 ? "Microflows$BasicCodeActionParameterValue" :
        "Microflows$BasicJavaActionParameterValue"
      mappings = Array(activity[:mappings]).map do |mapping|
        value = code_action_parameter_doc(
          mapping[:value], basic_type: value_type, code: false,
          modern_java: major >= 11
        )
        if value["Argument"] &&
           (major.between?(8, 10) || (major == 7 && minor >= 11))
          value["ArgumentModel"] = no_expression_doc
        end
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$JavaActionParameterMapping",
          "Parameter" => mapping[:param],
          "Value" => value
        }
      end
      doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$JavaActionCallAction",
        "ErrorHandlingType" => "Rollback",
        "JavaAction" => activity[:name],
        "ParameterMappings" => IO::BsonCodec.build_array(mappings, marker: 2),
        "ResultVariableName" => result_name
      }
      doc["UseReturnVariable"] = activity[:use_return] == true if major >= 8 || (major == 7 && minor >= 11)
      doc["QueueSettings"] = nil if major >= 10
      doc["Queue"] = "" if major.between?(8, 9)
      doc
    end

    def javascript_action_call_doc(activity)
      result_name = activity[:result_name] || activity[:variable].to_s
      mappings = Array(activity[:mappings]).map do |mapping|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$JavaScriptActionParameterMapping",
          "Parameter" => mapping[:param],
          "ParameterValue" => code_action_parameter_doc(
            mapping[:value],
            basic_type: "Microflows$BasicCodeActionParameterValue",
            code: true
          )
        }
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$JavaScriptActionCallAction",
        "ErrorHandlingType" => "Abort",
        "JavaScriptAction" => activity[:name],
        "OutputVariableName" => result_name,
        "ParameterMappings" => IO::BsonCodec.build_array(mappings, marker: 2),
        "UseReturnVariable" => activity[:use_return] == true
      }
    end

    def code_action_parameter_doc(value, basic_type:, code:, modern_java: false)
      unless value.is_a?(Hash) && value[:kind]
        return {
          "$ID" => SecureRandom.uuid,
          "$Type" => basic_type,
          "Argument" => member_value_expr(value)
        }
      end

      kind = value[:kind].to_sym
      if modern_java && kind == :microflow
        return {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$MicroflowParameterValue",
          "Microflow" => value[:value]
        }
      end

      suffix = code ? "CodeActionParameterValue" : "JavaActionParameterValue"
      prefix, field = case kind
      when :entity         then ["EntityType", "Entity"]
      when :microflow      then ["Microflow", "Microflow"]
      when :import_mapping then ["ImportMapping", "ImportMapping"]
      when :export_mapping then ["ExportMapping", "ExportMapping"]
      else
        return value[:value] if value[:value].is_a?(Hash)
        ["Basic", "Argument"]
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$#{prefix}#{suffix}",
        field => value[:value]
      }
    end

    def nanoflow_call_doc(activity)
      result_name = activity[:result_name] || activity[:variable].to_s
      mappings = Array(activity[:mappings]).map do |mapping|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$NanoflowCallParameterMapping",
          "Argument" => member_value_expr(mapping[:value]),
          "Parameter" => mapping[:param]
        }
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$NanoflowCallAction",
        "ErrorHandlingType" => "Abort",
        "NanoflowCall" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$NanoflowCall",
          "Nanoflow" => activity[:name],
          "ParameterMappings" => IO::BsonCodec.build_array(mappings, marker: 2)
        },
        "OutputVariableName" => result_name,
        "UseReturnVariable" => activity[:use_return] == true
      }
    end

    def app_service_call_doc(activity)
      result_name = activity[:result_name] || activity[:variable].to_s
      mappings = Array(activity[:mappings]).map do |mapping|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "AppServices$AppServiceActionParameterMapping",
          "Argument" => member_value_expr(mapping[:value]),
          "Parameter" => mapping[:param]
        }
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$AppServiceCallAction",
        "AppServiceAction" => activity[:name],
        "ErrorHandlingType" => "Rollback",
        "ParameterMappings" => IO::BsonCodec.build_array(mappings, marker: 2),
        "ResultVariableName" => result_name,
        "UseReturnVariable" => activity[:use_return] == true
      }
    end

    def validation_feedback_action_doc(activity)
      translations = activity[:translations].map do |language, text|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Texts$Translation",
          "LanguageCode" => language,
          "Text" => text
        }
      end
      parameters = Array(activity[:parameters]).map do |expression|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$TemplateParameter",
          "Expression" => member_value_expr(expression),
          "ExpressionModel" => no_expression_doc
        }
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$ValidationFeedbackAction",
        "Association" => activity[:association].to_s,
        "Attribute" => activity[:attribute].to_s,
        "ErrorHandlingType" => mendix_enum(activity[:error]),
        "FeedbackTemplate" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$TextTemplate",
          "Parameters" => IO::BsonCodec.build_array(parameters, marker: 2),
          "Text" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Texts$Text",
            "Items" => IO::BsonCodec.build_array(translations)
          }
        },
        "ValidationVariableName" => activity[:variable]
      }
    end

    def no_expression_doc
      { "$ID" => SecureRandom.uuid, "$Type" => "Expressions$NoExpression" }
    end

    def template_parameter_docs(parameters)
      Array(parameters).map do |expression|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$TemplateParameter",
          "Expression" => member_value_expr(expression),
          "ExpressionModel" => no_expression_doc
        }
      end
    end

    def localized_text_doc(translations)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Texts$Text",
        "Items" => IO::BsonCodec.build_array(
          translations.map do |language, text|
            {
              "$ID" => SecureRandom.uuid,
              "$Type" => "Texts$Translation",
              "LanguageCode" => language.to_s,
              "Text" => text.to_s
            }
          end
        )
      }
    end

    def variable_type_doc(type)
      native_type = type.to_s
      unless native_type.include?("$")
        type_name = native_type.split("_").map(&:capitalize).join
        type_name = "DateTime" if type_name == "Datetime"
        native_type = "DataTypes$#{type_name}Type"
      end
      { "$ID" => SecureRandom.uuid, "$Type" => native_type }
    end

    def change_action_item_doc(member, entity: nil)
      association = qualified_association_identifier(member[:association], entity)
      attribute = qualified_attribute_identifier(member[:attribute], entity)
      if member[:association] && !association
        raise SerializationError,
              "cannot qualify association #{member[:association].inspect} without an object entity"
      end
      if member[:attribute] && !attribute
        raise SerializationError,
              "cannot qualify attribute #{member[:attribute].inspect} without an object entity"
      end
      { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ChangeActionItem",
        "Association" => association.to_s,
        "Attribute" => attribute.to_s,
        "Type" => mendix_enum(member[:operation] || "Set"),
        "Value" => member_value_expr(member[:value]),
        "ValueModel" => no_expression_doc }
    end

    def qualified_association_identifier(association, entity = nil)
      value = association.to_s
      return if value.empty?

      value = value.tr('/', '.')
      return value if value.include?('.')

      entity_name = qualified_entity_name(entity)
      return unless entity_name

      "#{entity_name.split('.').first}.#{value}"
    end

    def member_value_expr(value)
      case value
      when Symbol        then "$#{value}"
      when Integer, Float then value.to_s
      when true, false    then value.to_s
      when nil            then ""
      else value.to_s
      end
    end

    def nanoflow_doc(flow)
      doc = microflow_doc(flow)
      normalize_nanoflow_error_handling!(doc)
      doc.merge(
        "$Type" => "Microflows$Nanoflow",
        "AllowConcurrentExecution" => nil,
        "UseListParameterByReference" => true
      ).compact
    end

    def normalize_nanoflow_error_handling!(value)
      case value
      when Hash
        value["ErrorHandlingType"] = "Abort" if value["ErrorHandlingType"] == "Rollback"
        value.each_value { normalize_nanoflow_error_handling!(_1) }
      when Array
        value.each { normalize_nanoflow_error_handling!(_1) }
      end
      value
    end

    def text_doc(text)
      { "$ID" => SecureRandom.uuid, "$Type" => "Texts$Text",
        "Items" => IO::BsonCodec.build_array([
          { "$ID" => SecureRandom.uuid, "$Type" => "Texts$Translation",
            "LanguageCode" => "en_US", "Text" => text }
        ]) }
    end

    def client_template_doc(text)
      {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$ClientTemplate",
        "Fallback" => text_doc(""),
        "Parameters" => IO::BsonCodec.build_array([], marker: 2),
        "Template" => text_doc(text.to_s)
      }
    end

    def empty_client_template_doc
      {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ClientTemplate',
        'Fallback' => {
          '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text',
          'Items' => IO::BsonCodec.build_array([])
        },
        'Parameters' => IO::BsonCodec.build_array([], marker: 2),
        'Template' => {
          '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text',
          'Items' => IO::BsonCodec.build_array([])
        }
      }
    end

    def appearance_doc(class_name = "")
      {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$Appearance",
        "Class" => class_name.to_s,
        "DesignProperties" => IO::BsonCodec.build_array([]),
        "DynamicClasses" => "", "Style" => ""
      }
    end

    def array_items(value)
      IO::BsonCodec.parse_array(value)[:items]
    end
  end
end
