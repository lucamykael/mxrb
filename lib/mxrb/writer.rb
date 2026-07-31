# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "sqlite3"

module Mxrb
  # Applies a DSL definition to a new or existing MPR. Names are used as the
  # stable key, making repeated `mxrb generate` runs idempotent.
  class Writer
    LEGACY_NAVIGATION_PROFILES = {
      "Desktop" => "DesktopProfile",
      "Tablet" => "TabletProfile",
      "Phone" => "PhoneProfile",
      "OfflinePhone" => "OfflinePhoneProfile",
      "HybridPhone" => "HybridPhoneProfile6",
      "HybridTablet" => "HybridTabletProfile6"
    }.freeze

    def initialize(path, definition)
      @path = File.expand_path(path)
      @definition = definition
    end

    def write!
      create_project! unless File.exist?(@path)
      mpr = IO::MprFile.open(@path)
      mpr.transaction do
        apply(mpr)
        mpr.write_architecture_definition(@definition)
      end
      materialize_project_assets
      materialize_design_system
      self
    ensure
      mpr&.close
    end

    private

    def materialize_design_system
      design_system = @definition[:design_system]
      return unless design_system

      Model::DesignMaterializer.new(File.dirname(@path), design_system).materialize!
    end

    def materialize_project_assets
      assets = @definition[:project_assets]
      return unless assets

      manifest = JSON.parse(File.read(assets.fetch(:manifest)))
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
      path = @definition[:native_units_path]
      return nil if path.to_s.empty? || !File.file?(path)

      JSON.parse(File.read(path))["format_version"]
    end

    def apply(mpr)
      root = mpr.root_unit
      root_id = root.fetch("UnitID")
      root_doc = mpr.parse_contents(root)
      root_doc = {
        "$ID" => root_doc["$ID"] || root_id,
        "$Type" => "Projects$Project",
        "IsSystemProject" => false
      }
      mpr.update_unit(root_id, root_doc)
      native_units = load_native_units(@definition[:native_units_path])
      native_units = apply_native_unit_overrides(
        native_units, @definition.fetch(:native_unit_overrides, [])
      )
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
      end
      write_project_security(mpr, root_id, @definition[:security]) if @definition[:security]
      write_project_navigation(mpr, root_id, @definition[:navigation]) if @definition[:navigation]
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
        next unless unit.fetch('type') == 'Settings$ProjectSettings'

        array_items(unit.dig('doc', 'Settings')).each do |setting|
          setting['EnableNewStringBehavior'] = true \
            if setting['$Type'] == 'Forms$WebUIProjectSettingsPart'
        end
      end
      apply_native_unit_tree(mpr, root_id, units)
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
      mod.fetch(:native_documents, []).each do |document|
        upsert_native_unit(
          mpr, module_id,
          'containment' => document.fetch(:containment), 'doc' => document.fetch(:doc)
        )
      end
    end

    def apply_native_unit_tree(mpr, target_root_id, units)
      if units.any? { _1["unit_id"].to_s.empty? || _1["container_id"].to_s.empty? }
        units.each { upsert_native_unit(mpr, target_root_id, _1) }
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
        end
        pending = blocked
      end
    end

    def upsert_native_unit(mpr, container_id, unit)
      doc = unit.fetch("doc")
      name = doc["Name"] || doc["name"]
      existing = if name.to_s.empty?
        mpr.children_of(container_id).find { mpr.parse_contents(_1)["$Type"] == doc["$Type"] }
      else
        mpr.children_of(container_id).find do |raw|
          existing_doc = mpr.parse_contents(raw)
          (existing_doc["Name"] || existing_doc["name"]) == name && existing_doc["$Type"] == doc["$Type"]
        end
      end
      if existing
        current = mpr.parse_contents(existing)
        preserved = {
          "$ID" => current["$ID"] || existing.fetch("UnitID"),
          "$Type" => doc["$Type"]
        }.merge(current).merge(doc)
        mpr.update_unit(existing.fetch("UnitID"), preserved)
        existing.fetch("UnitID")
      else
        containment = unit.fetch("containment")
        mpr.insert_unit(container_uuid: container_id, containment_name: containment, contents_doc: doc)
      end
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
        if security[:security_level]
          editable["SecurityLevel"] = doc.fetch("SecurityLevel")
        end
        {
          demo_users_enabled: "EnableDemoUsers",
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
        key = LEGACY_NAVIGATION_PROFILES.fetch(profile.fetch(:name).to_s)
        document[key] = navigation_profile_doc(profile, previous: existing[key])
      end
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
        "Page" => home[:page],
        "Microflow" => home[:microflow]
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
        "Icon" => item[:icon] && {
          "$ID" => SecureRandom.uuid, "$Type" => "Forms$GlyphIcon", "Code" => item[:icon]
        },
        "Items" => IO::BsonCodec.build_array(
          item.fetch(:items, []).map { navigation_menu_item_doc(_1) }
        )
      }
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
      return if raw.nil? && mod.fetch(:module_roles, []).empty?

      doc = module_security_doc(mod.fetch(:module_roles, []))
      if raw
        existing = mpr.parse_contents(raw)
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
      associations = existing_associations.values
      mod.fetch(:entities).flat_map do |entity|
        entity.fetch(:associations, []).map do |association|
          generated = association_doc(
            association,
            from_id: entity_ids.fetch(entity.fetch(:name)),
            to_id: entity_ids.fetch(association.fetch(:target)) {
              @all_entity_ids.fetch(association.fetch(:target)) {
                raise ArgumentError, "unknown association target #{association.fetch(:target).inspect}"
              }
            },
            previous: existing_associations[association.fetch(:name)]
          )
          associations = associations.reject { _1["Name"] == generated["Name"] } + [generated]
        end
      end

      doc = existing.merge(
        "$ID" => raw&.fetch("UnitID", nil) || SecureRandom.uuid,
        "$Type" => "DomainModels$DomainModel"
      )
      doc[entities_key] = IO::BsonCodec.build_array(entities)
      doc[associations_key] = IO::BsonCodec.build_array(associations)
      doc[cross_associations_key] ||= IO::BsonCodec.build_array([])
      doc[annotations_key] ||= IO::BsonCodec.build_array([])

      if raw
        mpr.update_unit(raw.fetch("UnitID"), doc)
      else
        mpr.insert_unit(container_uuid: module_id, containment_name: "DomainModel", contents_doc: doc)
      end
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
        upsert_document(mpr, module_id, existing[page.fetch(:name)], page_doc(page))
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
        mpr.insert_unit(container_uuid: module_id, containment_name: "Documents", contents_doc: doc)
      end
    end

    def merge_existing_document(existing, generated)
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
      doc.delete("__mxrb_mark_as_used_declared")
      doc.delete("__mxrb_excluded_declared")
      doc
    end

    def preserve_flow_metadata(merged, existing, generated)
      {
        "AllowConcurrentExecution" => "__mxrb_allow_concurrent_execution_declared",
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
        attribute_doc(attr, previous_attrs[attr.fetch(:name)])
      end
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
        "$ID" => id, "$Type" => "DomainModels$EntityImpl",
        "Name" => entity.fetch(:name), "Documentation" => entity.fetch(:documentation, ""),
        "GUID" => previous&.dig("GUID") || SecureRandom.uuid,
        "Location" => previous&.dig("Location") || "#{(index % 4) * 220};#{(index / 4) * 160}",
        "Image" => previous&.fetch("Image", "") || "",
        "IsRemote" => previous&.fetch("IsRemote", false) || false,
        "RemoteSource" => previous&.fetch("RemoteSource", "") || ""
      )
      doc[attrs_key] = IO::BsonCodec.build_array(attrs)
      doc[rules_key] = access_rules
      doc[validation_key] = validation_rules_doc(
        entity, module_name, previous&.dig(validation_key)
      )
      if entity[:indexes].nil?
        doc[indexes_key] ||= IO::BsonCodec.build_array([])
      else
        doc[indexes_key] = IO::BsonCodec.build_array(
          entity.fetch(:indexes).map { index_doc(_1, module_name, entity.fetch(:name)) }
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

    def attribute_doc(attr, previous)
      storage_type = Model::Attribute::TYPE_MAP.fetch(attr.fetch(:type))
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
      type_doc = type_doc.merge("Enumeration" => attr[:enumeration].to_s) if attr[:enumeration]
      if attr[:length]
        length_key = native_key(previous_type, 'length', 'Length')
        type_doc = type_doc.merge(length_key => Integer(attr[:length]))
      end
      if attr.key?(:localize_date)
        localize_key = native_key(previous_type, 'localizeDate', 'LocalizeDate')
        type_doc = type_doc.merge(localize_key => (attr[:localize_date] == true))
      end
      previous_value = previous&.dig(value_key)
      value_doc = if previous_value && !attr.key?(:default)
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
      {
        '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$Generalization',
        'Generalization' => target.to_s
      }
    end

    def validation_rules_doc(entity, module_name, previous)
      existing = array_items(previous)
      declarations = entity.fetch(:attributes).select do |attribute|
        attribute.key?(:required) || attribute.key?(:unique)
      end
      return previous || IO::BsonCodec.build_array([]) if declarations.empty?

      declared_names = declarations.map { _1.fetch(:name) }
      kept = existing.reject do |rule|
        declared_names.include?(rule['Attribute'].to_s.split('.').last) &&
          rule.dig('RuleInfo', '$Type').to_s.match?(/(?:Required|Unique)RuleInfo\z/)
      end
      generated = declarations.flat_map do |attribute|
        %i[required unique].filter_map do |kind|
          validation_rule_doc(module_name, entity.fetch(:name), attribute.fetch(:name), kind) \
            if attribute[kind] == true
        end
      end
      IO::BsonCodec.build_array(kept + generated)
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

    def index_doc(index, module_name, entity_name)
      members = index.fetch(:attributes).zip(index.fetch(:ascending)).map do |attribute, ascending|
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$IndexedAttribute',
          'Type' => 'Normal', 'Attribute' => "#{module_name}.#{entity_name}.#{attribute}",
          'Association' => nil, 'Ascending' => ascending
        }
      end
      {
        '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$EntityIndex',
        'DataStorageGuid' => SecureRandom.uuid,
        'IndexedAttributes' => IO::BsonCodec.build_array(members),
        'IncludeInOffline' => index.fetch(:include_offline, false)
      }
    end

    def access_rule_doc(rule, module_name, entity_name, attributes: [], associations: [])
      read = rule.fetch(:read, :none)
      write = rule.fetch(:write, :none)
      default_rights = access_default_rights(read, write)
      members = access_member_docs(
        read, write, module_name, entity_name, attributes:, associations:
      )
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "DomainModels$AccessRule",
        "Documentation" => "",
        "AllowedModuleRoles" => IO::BsonCodec.build_array(rule.fetch(:roles), marker: 1),
        "AllowCreate" => rule.fetch(:create, false),
        "AllowDelete" => rule.fetch(:delete, false),
        "DefaultMemberAccessRights" => default_rights,
        "MemberAccesses" => IO::BsonCodec.build_array(members),
        "XPathConstraint" => rule.fetch(:xpath, "")
      }
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

    def association_doc(association, from_id:, to_id:, previous:)
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
        "StorageFormat" => association.fetch(:type) == :ReferenceSet ? "Table" : "Column"
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
      doc
    end

    def lifecycle_doc(callback)
      event, moment = callback.fetch(:event).to_s.split("_", 2)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "DomainModels$EventHandler",
        "Event" => event == "before" || event == "after" ? moment.capitalize : event.capitalize,
        "Moment" => event.capitalize,
        "Microflow" => callback.fetch(:handler),
        "PassEventObject" => true,
        "RaiseErrorOnFalse" => event == "before"
      }
    end

    def page_doc(page)
      if page[:deep_structure].is_a?(Hash)
        return page[:deep_structure].merge(
          "$ID" => SecureRandom.uuid,
          "Name" => page.fetch(:name),
          "__mxrb_allowed_roles_declared" => !page[:allowed_roles].nil?,
          "__mxrb_deep_structure_declared" => true
        )
      end

      widgets = page.fetch(:widgets, []).map { widget_doc(_1) }
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
      roles_declared = !page[:allowed_roles].nil?
      form_call = {
        "$ID" => SecureRandom.uuid, "$Type" => "Forms$LayoutCall",
        "Arguments" => IO::BsonCodec.build_array([{
          "$ID" => SecureRandom.uuid, "$Type" => "Forms$FormCallArgument",
          "Parameter" => "#{page.fetch(:layout)}.Main",
          "Widgets" => IO::BsonCodec.build_array(content, marker: 2)
        }], marker: 2),
        "Form" => page.fetch(:layout)
      }
      doc = { "$ID" => SecureRandom.uuid, "$Type" => "Forms$Page", "Name" => page.fetch(:name),
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
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Enumerations$EnumerationValue",
          "Name" => val.fetch(:name),
          "Caption" => { "$ID" => SecureRandom.uuid, "$Type" => "Texts$Text", "Items" => [] },
          "Image" => "",
          "ExportLevel" => "Hidden"
        }.tap do |value|
          value["Caption"]["Items"] = IO::BsonCodec.build_array([{
            "$ID" => SecureRandom.uuid, "$Type" => "Texts$Translation",
            "LanguageCode" => "en_US", "Text" => val[:caption] || val.fetch(:name)
          }])
        end
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Enumerations$Enumeration",
        "Name" => enum.fetch(:name),
        "Documentation" => enum.fetch(:documentation, ""),
        "ExportLevel" => "Hidden",
        "Values" => IO::BsonCodec.build_array(values)
      }
    end

    def constant_doc(constant)
      type_sym = constant.fetch(:type).to_sym
      type_str = CONSTANT_TYPE_MAP.fetch(type_sym) do
        raise ArgumentError, "unsupported constant type #{type_sym.inspect}; " \
                             "use one of: #{CONSTANT_TYPE_MAP.keys.join(', ')}"
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Constants$Constant",
        "Name" => constant.fetch(:name),
        "Documentation" => constant.fetch(:documentation, ""),
        "ExportLevel" => "Hidden",
        "Type" => { "$ID" => SecureRandom.uuid, "$Type" => type_str },
        "DefaultValue" => constant.fetch(:value, "").to_s
      }
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
      password_policy = {
        "$ID" => SecureRandom.uuid,
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
        "$ID" => SecureRandom.uuid,
        "$Type" => "Security$ProjectSecurity",
        "SecurityLevel" => security[:security_level] || "CheckNothing",
        "CheckSecurity" => true,
        "AdminUserName" => "MxAdmin",
        "AdminPassword" => "1",
        "AdminUserRole" => security[:admin_user_role] || roles.first.fetch("Name"),
        "EnableDemoUsers" => security.fetch(:demo_users_enabled, false) == true,
        "EnableGuestAccess" => security.fetch(:guest_access_enabled, false) == true,
        "GuestUserRole" => security[:guest_user_role].to_s,
        "SignInMicroflow" => security[:sign_in_microflow].to_s,
        "StrictMode" => false,
        "StrictPageUrlCheck" => true,
        "UserRoles" => IO::BsonCodec.build_array(roles, marker: 2),
        "DemoUsers" => IO::BsonCodec.build_array([], marker: 2),
        "FileDocumentAccess" => access_container("Security$FileDocumentAccessRuleContainer"),
        "ImageAccess" => access_container("Security$ImageAccessRuleContainer"),
        "PasswordPolicySettings" => password_policy
      }
    end

    def user_role_doc(role)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Security$UserRole",
        "Name" => role.fetch(:name),
        "Description" => "",
        "CheckSecurity" => true,
        "GUID" => BSON::Binary.new(IO::BsonCodec.uuid_to_blob(SecureRandom.uuid)),
        "ManageableRoles" => IO::BsonCodec.build_array([], marker: 1),
        "ManageAllRoles" => role[:admin] == true,
        "ManageUsersWithoutRoles" => false,
        "ModuleRoles" => IO::BsonCodec.build_array(role.fetch(:module_roles, []), marker: 1)
      }
    end

    def module_security_doc(roles)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Security$ModuleSecurity",
        "ModuleRoles" => IO::BsonCodec.build_array(roles.map { module_role_doc(_1) }, marker: 2)
      }
    end

    def module_role_doc(role)
      {
        "$ID" => SecureRandom.uuid,
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

    def no_action_doc
      { "$ID" => SecureRandom.uuid, "$Type" => "Forms$NoAction" }
    end

    def widget_doc(widget)
      type = widget.fetch(:type)

      if type == :snippet
        return snippet_call_doc(widget)
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
      doc["LabelText"] = text_doc(options[:caption] || "") if type == :drop_down

      if type == :data_grid
        doc["Columns"] = IO::BsonCodec.build_array(data_grid_columns(options[:columns]), marker: 2)
        doc["DataSource"] = data_grid_source(options[:entity]) if options[:entity]
        doc["SearchBar"] = search_bar_doc(options[:search_bar]) if options[:search_bar]
        doc["ToolBar"] = toolbar_doc(options[:toolbar]) if options[:toolbar]
      end

      if type == :tab_control
        doc["TabPages"] = IO::BsonCodec.build_array(tab_pages(options[:tabs]))
      end

      if type == :container
        children = Array(widget[:children]).map { widget_doc(_1) }
        doc["Widgets"] = IO::BsonCodec.build_array(children)
        doc["Class"] = options[:class].to_s if options[:class]
      end

      widget.fetch(:events, []).each do |event|
        doc[event_property(event.fetch(:event))] = client_action_doc(event)
      end
      doc
    end

    def snippet_call_doc(widget)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$SnippetCall",
        "Name" => widget.fetch(:name),
        "SnippetSettings" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$SnippetSettings",
          "Snippet" => widget.dig(:options, :snippet).to_s
        }
      }
    end

    def search_bar_doc(search_bar)
      fields = Array(search_bar[:fields]).map do |field|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$AttributeSearchField",
          "Name" => "searchField_#{field[:attribute]}",
          "AttributeRef" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Forms$AttributeRef",
            "Attribute" => field[:attribute].to_s
          },
          "Label" => text_doc(field[:caption] || field[:attribute].to_s),
          "DefaultValue" => "",
          "Placeholder" => text_doc("")
        }
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$SearchBar",
        "SearchFields" => IO::BsonCodec.build_array(fields)
      }
    end

    def toolbar_doc(toolbar)
      type_map = {
        new:    "Forms$GridNewButton",
        delete: "Forms$GridDeleteButton",
        search: "Forms$GridSearchButton",
        export: "Forms$GridExportToExcelButton"
      }
      buttons = Array(toolbar[:buttons]).map do |btn|
        bson_type = type_map.fetch(btn[:type].to_sym, "Forms$GridNewButton")
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => bson_type,
          "Caption" => text_doc(btn[:caption].to_s),
          "Class" => "",
          "Style" => "",
          "ButtonStyle" => "Default"
        }
      end
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$GridToolBar",
        "Buttons" => IO::BsonCodec.build_array(buttons)
      }
    end

    def input_widget?(type)
      %i[text_box number_input check_box date_picker reference_selector drop_down].include?(type.to_sym)
    end

    def widget_storage_type(type)
      {
        button:             "Forms$ActionButton",
        text_box:           "Forms$TextBox",
        number_input:       "Forms$TextBox",
        check_box:          "Forms$CheckBox",
        date_picker:        "Forms$DatePicker",
        reference_selector: "Forms$ReferenceSelector",
        text:               "Forms$DynamicText",
        data_grid:          "Forms$DataGrid",
        tab_control:        "Forms$TabControl",
        drop_down:          "Forms$DropDownWidget",
        container:          "Forms$DivContainer"
      }.fetch(type.to_sym)
    end

    def data_grid_columns(columns)
      Array(columns).map do |column|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$DataGridColumn",
          "Name" => column.fetch(:name),
          "AttributePath" => column[:attribute]&.to_s,
          "Caption" => text_doc(column[:caption].to_s),
          "Class" => "",
          "Style" => "",
          "Editable" => false
        }.compact
      end
    end

    def data_grid_source(entity)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Forms$NewGridDatabaseSource",
        "Entity" => entity.to_s
      }
    end

    def tab_pages(tabs)
      Array(tabs).map do |tab|
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$TabPage",
          "Name" => tab.fetch(:name),
          "Caption" => text_doc(tab[:caption].to_s),
          "Widgets" => IO::BsonCodec.build_array([], marker: 2)
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
      when :nanoflow
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$CallNanoflowClientAction",
          "Nanoflow" => event.fetch(:handler),
          "DisabledDuringExecution" => true
        }
      else
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$MicroflowClientAction",
          "MicroflowSettings" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Forms$MicroflowSettings",
            "Microflow" => event.fetch(:handler),
            "FormValidations" => "All"
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
          "ClosePage" => true,
          "SyncAutomatically" => false
        }
      when "cancel_changes"
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$CancelChangesClientAction",
          "ClosePage" => true
        }
      when "delete"
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$DeleteClientAction",
          "ClosePage" => false
        }
      when "close_page"
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Forms$ClosePageClientAction"
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
        "DataSource" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => source.fetch(:kind).to_sym == :nanoflow ?
            "Forms$NanoflowSource" : "Forms$MicroflowSource",
          "MicroflowSettings" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Forms$MicroflowSettings",
            "Microflow" => source.fetch(:name)
          }
        },
        "Widgets" => IO::BsonCodec.build_array(widgets)
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
      body_declared   = !flow[:body].nil?
      return_var_name = flow[:return_variable_name] || "ReturnValue"
      allow_concurrent = flow[:allow_concurrent_execution]
      mark_as_used = flow[:mark_as_used]
      excluded = flow[:excluded]

      graph = build_microflow_graph(
        flow[:body], flow[:return_expression] || flow[:return_variable_name]
      )
      object_collection = {
        "$ID" => stable_id(flow_name, "object_collection"),
        "$Type" => "Microflows$MicroflowObjectCollection",
        "Objects" => IO::BsonCodec.build_array(params + graph[:objects])
      }

      { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$Microflow",
        "Name" => flow_name, "Documentation" => flow.fetch(:documentation, ""),
        "ReturnVariableName" => return_var_name,
        "AllowConcurrentExecution" => allow_concurrent.nil? ? true : allow_concurrent,
        "MarkAsUsed" => mark_as_used.nil? ? false : mark_as_used,
        "Excluded" => excluded.nil? ? false : excluded,
        "AllowedModuleRoles" => IO::BsonCodec.build_array(Array(flow[:allowed_roles]), marker: 1),
        "__mxrb_allowed_roles_declared" => roles_declared,
        "__mxrb_body_declared" => body_declared,
        "__mxrb_preserve_native_body" => flow[:preserve_native_body] == true,
        "__mxrb_allow_concurrent_execution_declared" => !allow_concurrent.nil?,
        "__mxrb_mark_as_used_declared" => !mark_as_used.nil?,
        "__mxrb_excluded_declared" => !excluded.nil?,
        "MicroflowReturnType" => microflow_data_type_doc(flow[:return_type], module_name),
        "ObjectCollection" => object_collection,
        "Flows" => IO::BsonCodec.build_array(graph[:flows]) }
    end

    def microflow_data_type_doc(type, module_name)
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
            Array(activity[:members]).map { change_action_item_doc(_1) }, marker: 2
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
          mapping = {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$MicroflowCallParameterMapping",
            "Parameter" => m[:param],
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
          "Node" => activity[:node].to_s,
          "NodeModel" => no_expression_doc }
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
        { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ListOperationsAction",
          "ErrorHandlingType" => "Rollback",
          "NewOperation" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$#{mendix_enum(activity[:operation])}",
            "ListName" => activity[:variable],
            "SecondListOrObjectName" => activity[:second]
          },
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
      end
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
        "RequestHandling" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$MappingRequestHandling",
          "ContentType" => "Json",
          "MappingId" => activity[:request_mapping].to_s,
          "MappingVariableName" => activity[:request_variable].to_s
        },
        "RequestHandlingType" => "Mapping",
        "RequestProxyType" => "DefaultProxy",
        "ResultHandling" => rest_result_handling_doc(activity),
        "ResultHandlingType" => "Mapping",
        "TimeOutExpression" => activity[:timeout].to_s,
        "UseRequestTimeOut" => !activity[:timeout].to_s.empty?
      }
    end

    def rest_result_handling_doc(activity)
      {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Microflows$ResultHandling",
        "Bind" => !activity[:variable].to_s.empty?,
        "ImportMappingCall" => {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$ImportMappingCall",
          "Commit" => mendix_enum(activity[:commit]),
          "ContentType" => "Json",
          "ForceSingleOccurrence" => false,
          "ObjectHandlingBackup" => "Create",
          "ParameterVariableName" => "",
          "Range" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$ConstantRange",
            "SingleObject" => false
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
      if limit && !limit.to_s.match?(/\A\d+\z/)
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
          mapping[:value], basic_type: value_type, code: false
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

    def code_action_parameter_doc(value, basic_type:, code:)
      unless value.is_a?(Hash) && value[:kind]
        return {
          "$ID" => SecureRandom.uuid,
          "$Type" => basic_type,
          "Argument" => member_value_expr(value)
        }
      end

      kind = value[:kind].to_sym
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
      attribute = member[:attribute].to_s
      if entity && !attribute.empty? && !attribute.include?('.') && !attribute.include?('/')
        attribute = "#{entity}.#{attribute}"
      end
      { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ChangeActionItem",
        "Association" => member[:association].to_s,
        "Attribute" => attribute,
        "Type" => mendix_enum(member[:operation] || "Set"),
        "Value" => member_value_expr(member[:value]),
        "ValueModel" => no_expression_doc }
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
      microflow_doc(flow).merge(
        "$Type" => "Microflows$Nanoflow",
        "AllowConcurrentExecution" => nil,
        "UseListParameterByReference" => true
      ).compact
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
