# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "digest"

module Mxrb
  # Exports an MPR into an editable, layered Ruby source tree.
  class Exporter
    MODES = %i[mendix ruby].freeze
    LAYERS = %w[domain application presentation infrastructure].freeze
    MODULE_PROGRESS_WEIGHT = 10
    MARKETPLACE_PROVENANCE = [
      ".mxrb/marketplace.lock.json",
      ".mxrb/marketplace",
      ".mxrb/marketplace-originals"
    ].freeze
    EDITABLE_FLOW_OBJECT_TYPES = %w[
      Microflows$StartEvent
      Microflows$EndEvent
      Microflows$ActionActivity
      Microflows$ExclusiveSplit
      Microflows$InheritanceSplit
      Microflows$ExclusiveMerge
      Microflows$LoopedActivity
      Microflows$ErrorEvent
      Microflows$ContinueEvent
      Microflows$Annotation
      Microflows$MicroflowParameter
    ].freeze
    EDITABLE_ACTION_TYPES = %w[
      Microflows$CreateObjectAction
      Microflows$CreateChangeAction
      Microflows$ChangeObjectAction
      Microflows$ChangeAction
      Microflows$RetrieveAction
      Microflows$CommitObjectsAction
      Microflows$CommitAction
      Microflows$DeleteAction
      Microflows$MicroflowCallAction
      Microflows$CreateVariableAction
      Microflows$ChangeVariableAction
      Microflows$ShowMessageAction
      Microflows$LogMessageAction
      Microflows$ShowFormAction
      Microflows$CloseFormAction
      Microflows$JavaActionCallAction
      Microflows$JavaScriptActionCallAction
      Microflows$NanoflowCallAction
      Microflows$AppServiceCallAction
      Microflows$AggregateAction
      Microflows$RollbackAction
      Microflows$CastAction
      Microflows$CreateListAction
      Microflows$ListOperationsAction
      Microflows$ChangeListAction
      Microflows$ValidationFeedbackAction
      Microflows$RestCallAction
    ].freeze

    attr_reader :mode

    def initialize(mpr_path, output_dir, mode: :mendix)
      @mpr_path = File.expand_path(mpr_path)
      @output_dir = File.expand_path(output_dir)
      @mode = mode.to_sym
      raise ArgumentError, "export mode must be mendix or ruby" unless MODES.include?(@mode)
    end

    def export!(parallel: true)
      return export_ruby!(parallel:) if mode == :ruby

      Progress.with("Exporting #{File.basename(@mpr_path)}") do |progress|
        FileUtils.mkdir_p(@output_dir)
        Mxrb.open(@mpr_path) do |project|
          @architecture = project.architecture_definition
          units = project.all_units
          modules = project.modules
          @inferred_public_artifacts = infer_public_artifacts(modules)
          assets = project_asset_files
          progress.update(
            current: 0,
            total: 4 + assets.size + (units.size * 2) + (modules.size * MODULE_PROGRESS_WEIGHT),
            detail: "preparing Ruby project"
          )
          export_app_structure
          progress.advance(detail: "project structure")
          export_project_assets(assets, progress)
          export_native_units(project, units, progress)
          ruby_sources = export_ruby_app_sources(project)
          export_security(project)
          progress.advance(detail: "project security")
          export_architecture_contracts(project)
          progress.advance(detail: "navigation and design system")
          export_modules(modules, progress, parallel:)
          write_project(project, ruby_sources:)
          progress.advance(detail: "project.rb")
        end
      end
      @output_dir
    end

    private

    def export_ruby!(parallel:)
      sidecar = File.join(@output_dir, ".mxrb", "mendix")
      self.class.new(@mpr_path, sidecar, mode: :mendix).export!(parallel:)
      RubyApp::Exporter.new(@mpr_path, @output_dir, mendix_sidecar: sidecar).export!
    end

    def export_module(mod)
      root = File.join(@output_dir, "modules", mod.name)
      LAYERS.each { FileUtils.mkdir_p(File.join(root, _1)) }

      export_domain(root, mod)
      export_microflows(root, mod)
      export_application_documents(root, mod)
      export_infrastructure_documents(root, mod)
      export_pages(root, mod)
      export_menus(root, mod)
      export_nanoflows(root, mod)
      export_module_scaffolding(root)
      export_module_security(root, mod)
      write(File.join(root, "module.rb"), module_source(mod))
    end

    def export_app_structure
      %w[
        app/security app/navigation app/navigation/responsive app/design_system
        theme resources themesource widgets javasource javascriptsource
      ].each { write(File.join(@output_dir, _1, ".keep"), "") }
    end

    def project_asset_files
      source_root = File.dirname(@mpr_path)
      (Model::DesignSystem::ASSET_DIRECTORIES + MARKETPLACE_PROVENANCE).flat_map do |directory|
        root = File.join(source_root, directory)
        next [root] if File.file?(root) && !File.symlink?(root)
        next [] unless File.directory?(root) && !File.symlink?(root)

        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
      end.select { File.file?(_1) && !File.symlink?(_1) }.sort
    end

    def export_project_assets(files, progress)
      source_root = File.dirname(@mpr_path)
      entries = files.map do |source|
        relative = Pathname.new(source).relative_path_from(Pathname.new(source_root)).to_s
        target = File.join(@output_dir, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
        result = {
          "path" => relative,
          "size" => File.size(source),
          "sha256" => Digest::SHA256.file(source).hexdigest
        }
        progress.advance(detail: "asset #{relative}")
        result
      end
      write(
        File.join(@output_dir, ".mxrb", "assets.json"),
        JSON.pretty_generate("version" => 1, "files" => entries)
      )
    end

    def export_native_units(project, project_units, progress)
      units = project_units.filter_map do |unit|
        doc = project.parse_bson(unit)
        type = doc["$Type"]
        next if type.to_s.empty? || type == "Projects$Project"

        {
          "unit_id" => unit["UnitID"],
          "container_id" => unit["ContainerID"],
          "module" => module_name_for(project, unit),
          "containment" => unit["ContainmentName"],
          "name" => doc["Name"] || doc["name"] || "",
          "type" => type,
          "contents" => Base64.strict_encode64(IO::BsonCodec.serialize(doc))
        }
      ensure
        progress.advance(detail: "native baseline")
      end
      write(
        File.join(@output_dir, ".mxrb", "native_units.json"),
        JSON.pretty_generate("format_version" => project.format_version.to_s, "units" => units)
      )
      source = project_units.filter_map do |unit|
        doc = project.parse_bson(unit)
        next if doc["$Type"].to_s.empty? || doc["$Type"] == "Projects$Project"
        next if Model::Module::EDITABLE_DOCUMENT_TYPES.include?(doc["$Type"])

        native_unit_source(project, unit, doc)
      ensure
        progress.advance(detail: "editable native units")
      end
      write(
        File.join(@output_dir, ".mxrb", "native_units.rb"),
        "# frozen_string_literal: true\n\n#{source.join("\n")}"
      )
    end

    def export_ruby_app_sources(project)
      files = project.mpr.ruby_app_sources
      return false if files.empty?

      payload = files.map do |file|
        contents = file.fetch(:contents)
        {
          "path" => file.fetch(:path), "sha256" => file.fetch(:sha256),
          "contents" => Base64.strict_encode64(contents), "mode" => file.fetch(:mode, 0o644)
        }
      end
      write(
        File.join(@output_dir, ".mxrb", "ruby_sources.json"),
        JSON.pretty_generate("version" => 1, "files" => payload)
      )
      true
    end

    def export_modules(modules, progress, parallel:)
      operation = lambda do |mod|
        export_module(mod)
        progress.advance(MODULE_PROGRESS_WEIGHT, detail: "module #{mod.name}")
      end
      if parallel && modules.size > 1
        modules.map { |mod| Thread.new { operation.call(mod) } }.each(&:join)
      else
        modules.each { operation.call(_1) }
      end
    end

    def native_unit_source(project, unit, doc)
      <<~RUBY
        native_unit #{ruby(unit.fetch("UnitID"))},
                    container_id: #{ruby(unit.fetch("ContainerID"))},
                    containment: #{ruby(unit.fetch("ContainmentName"))},
                    module_name: #{ruby(module_name_for(project, unit))},
                    deep_structure: #{native_ruby(doc, 20)}
      RUBY
    end

    def module_name_for(project, unit)
      container = unit["ContainerID"]
      project.modules.find { _1.id == container }&.name ||
        project.modules.find { |mod| native_descendant_of?(project, container, mod.id) }&.name
    end

    def native_descendant_of?(project, child_id, ancestor_id)
      current = project.raw_unit(child_id)
      until current.nil? || current["UnitID"] == current["ContainerID"]
        return true if current["ContainerID"] == ancestor_id
        current = project.raw_unit(current["ContainerID"])
      end
      false
    end

    def export_security(project)
      doc = project_security_doc(project)
      source = doc ? security_source(doc) : "# frozen_string_literal: true\n"
      write(File.join(@output_dir, "app", "security", "security.rb"), source)
    end

    def export_architecture_contracts(project)
      navigation = @architecture&.fetch(:navigation, nil)
      navigation ||= project.navigation.to_h unless project.navigation.empty?
      design_system = @architecture&.fetch(:design_system, nil)
      write(
        File.join(@output_dir, "app", "navigation", "navigation.rb"),
        navigation_source(navigation)
      )
      write(
        File.join(@output_dir, "app", "design_system", "design_system.rb"),
        design_system_source(design_system)
      )
    end

    def export_module_scaffolding(root)
      %w[
        domain/entities domain/dtos domain/oql_views domain/enumerations domain/constants
        domain/rules domain/policies
        application/ports/repositories application/queries application/queries/datasets
        application/validations application/jobs application/jobs/scheduled_events
        presentation/features presentation/client_actions presentation/snippets presentation/view_models
        presentation/menus
        infrastructure/persistence/mendix infrastructure/persistence/external
        infrastructure/mappings infrastructure/actions infrastructure/endpoints
        infrastructure/integrations
        security
      ].each { write(File.join(root, _1, ".keep"), "") }

      security_path = File.join(root, "security", "security.rb")
      write(security_path, "# frozen_string_literal: true\n") unless File.exist?(security_path)
    end

    def export_module_security(root, mod)
      roles = mod.module_roles.map do |role|
        args = [symbol(role.fetch(:name))]
        description = role.fetch(:description, "")
        args << "description: #{ruby(description)}" unless description.empty?
        "module_role #{args.join(', ')}"
      end
      source = (["# frozen_string_literal: true", ""] + roles).join("\n") + "\n"
      write(File.join(root, "security", "security.rb"), source)
    end

    def export_domain(root, mod)
      domain = File.join(root, "domain")
      associations = mod.associations.group_by(&:from_entity_id)
      architecture = architecture_module(mod.name)
      paths = {}
      grouped = mod.entities.group_by { entity_domain_route(_1) }
      grouped.each do |route, entities|
        unique_entity_filenames(entities, route:).each do |id, filename|
          paths[id] = File.join(route, filename)
        end
      end
      domain_documents = mod.domain_documents
      oql_documents = mod.oql_view_documents
      attached_oql_documents = {}
      mod.entities.each do |entity|
        entity_metadata = architecture&.fetch(:entities, [])&.find { _1[:name] == entity.name }
        source = entity_source(entity, mod, associations.fetch(entity.id, []), entity_metadata)
        if oql_view_entity?(entity) && (document = oql_document_for(entity, oql_documents, mod.name))
          source = "#{source.rstrip}\n\n#{native_document_declaration(document)}"
          attached_oql_documents[document.fetch(:id)] = true
        end
        write(
          File.join(domain, paths.fetch(entity.id)), source
        )
      end
      used = paths.values.to_h { [_1, true] }
      domain_documents.reject { attached_oql_documents[_1.fetch(:id)] }.each do |document|
        relative = unique_relative_path(document.fetch(:route), underscore(document.fetch(:name)), used)
        write(File.join(domain, relative), mapping_document_source(document))
        paths[document.fetch(:id)] = relative
      end
      loads = paths.values.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(", ")
        %(evaluate File.join(__dir__, #{segments}))
      end
      write(File.join(domain, "model.rb"), "#{loads.join("\n")}\n")
    end

    def entity_domain_route(entity)
      return 'oql_views' if oql_view_entity?(entity)
      return 'dtos' unless entity.persistable

      'entities'
    end

    def oql_view_entity?(entity)
      entity.respond_to?(:oql_view?) && entity.oql_view?
    end

    def oql_document_for(entity, documents, module_name)
      reference = entity.oql_source_document.to_s
      return nil if reference.empty?

      documents.find do |document|
        [document.fetch(:name), "#{module_name}.#{document.fetch(:name)}"].include?(reference)
      end
    end

    def export_microflows(root, mod)
      files = unique_filenames(mod.microflows)
      by_layer = { "application" => [], "infrastructure" => [] }
      architecture = architecture_module(mod.name)
      mod.microflows.each do |flow|
        layer, category = flow_location(flow.name)
        relative = File.join(category, files.fetch(flow.id))
        metadata = flow_metadata(
          mod.name, :microflow, flow.name,
          architecture&.fetch(:microflows, [])&.find { _1[:name] == flow.name }
        )
        write(File.join(root, layer, relative), microflow_source(flow, metadata))
        by_layer.fetch(layer) << relative
      end
      repositories = architecture&.fetch(:repositories, []) || []
      unless repositories.empty?
        relative = File.join("ports", "repositories.rb")
        write(File.join(root, "application", relative), repositories_source(repositories))
        by_layer["application"] << relative
      end
      by_layer.each do |layer, paths|
        write_path_aggregator(File.join(root, layer, "#{layer}.rb"), paths)
      end
    end

    def export_pages(root, mod)
      presentation = File.join(root, "presentation")
      documents = File.join(presentation, "pages")
      FileUtils.mkdir_p(documents)
      files = unique_filenames(mod.pages)
      architecture = architecture_module(mod.name)
      paths = []
      mod.pages.each do |page|
        relative = File.join("pages", files.fetch(page.id))
        metadata = architecture&.fetch(:pages, [])&.find { _1[:name] == page.name }
        write(File.join(presentation, relative), page_source(page, metadata))
        paths << relative
      end
      write_path_aggregator(File.join(presentation, "presentation.rb"), paths)
    end

    def export_infrastructure_documents(root, mod)
      documents = mod.infrastructure_documents
      return if documents.empty?

      infrastructure = File.join(root, "infrastructure")
      used = {}
      paths = documents.map do |document|
        base = underscore(document.fetch(:name))
        relative = unique_relative_path(document.fetch(:route), base, used)
        write(File.join(infrastructure, relative), mapping_document_source(document))
        relative
      end
      append_to_aggregator(File.join(infrastructure, "infrastructure.rb"), paths)
    end

    def export_application_documents(root, mod)
      documents = mod.application_documents
      return if documents.empty?

      application = File.join(root, 'application')
      used = {}
      paths = documents.map do |document|
        relative = unique_relative_path(document.fetch(:route), underscore(document.fetch(:name)), used)
        write(File.join(application, relative), mapping_document_source(document))
        relative
      end
      append_to_aggregator(File.join(application, 'application.rb'), paths)
    end

    def unique_relative_path(directory, base, used)
      candidate = File.join(directory, "#{base}.rb")
      suffix = 2
      while used[candidate]
        candidate = File.join(directory, "#{base}_#{suffix}.rb")
        suffix += 1
      end
      used[candidate] = true
      candidate
    end

    def mapping_document_source(document)
      <<~RUBY
        # frozen_string_literal: true

        #{native_document_declaration(document)}
      RUBY
    end

    def native_document_declaration(document)
      <<~RUBY.rstrip
        native_document #{symbol(document.fetch(:name))},
                        type: #{ruby(document.fetch(:type))},
                        unit_id: #{ruby(document.fetch(:id))},
                        container_id: #{ruby(document.fetch(:container_id))},
                        containment: #{ruby(document.fetch(:containment))},
                        deep_structure: #{native_ruby(document.fetch(:doc), 24)}
      RUBY
    end

    def append_to_aggregator(path, relative_paths)
      existing = File.exist?(path) ? File.read(path).lines : []
      additions = relative_paths.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(", ")
        "evaluate File.join(__dir__, #{segments})\n"
      end
      write(path, (existing + additions).uniq.join)
    end

    def export_menus(root, mod)
      menus = mod.menus
      return if menus.empty?

      presentation = File.join(root, "presentation")
      files = unique_filenames(menus)
      paths = []
      menus.each do |menu|
        relative = File.join("menus", files.fetch(menu.id))
        write(File.join(presentation, relative), menu_source(menu))
        paths << relative
      end
      existing_path = File.join(presentation, "presentation.rb")
      existing = File.exist?(existing_path) ? File.read(existing_path).lines : []
      additions = paths.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(", ")
        "evaluate File.join(__dir__, #{segments})\n"
      end
      write(existing_path, (existing + additions).join)
    end

    def export_nanoflows(root, mod)
      flows = mod.nanoflows
      return if flows.empty?
      presentation = File.join(root, "presentation")
      files = unique_filenames(flows)
      paths = []
      architecture = architecture_module(mod.name)
      flows.each do |flow|
        relative = File.join("client_actions", files.fetch(flow.id))
        metadata = flow_metadata(
          mod.name, :nanoflow, flow.name,
          architecture&.fetch(:nanoflows, [])&.find { _1[:name] == flow.name }
        )
        write(File.join(presentation, relative), nanoflow_source(flow, metadata))
        paths << relative
      end
      existing = File.read(File.join(presentation, "presentation.rb")).lines
      additions = paths.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(", ")
        "evaluate File.join(__dir__, #{segments})\n"
      end
      write(File.join(presentation, "presentation.rb"), (existing + additions).join)
    end

    def write_path_aggregator(path, relative_paths)
      loads = relative_paths.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(", ")
        %(evaluate File.join(__dir__, #{segments}))
      end
      write(path, "#{loads.join("\n")}\n")
    end

    def flow_location(name)
      case name
      when /\A(?:DS|OQL)_/  then %w[application queries]
      when /\AVAL_/         then %w[application validations]
      when /\ASE_/          then %w[application jobs]
      when /\AAPI_/         then %w[infrastructure endpoints]
      when /\AINT_/         then %w[infrastructure integrations]
      else                       %w[application use_cases]
      end
    end

    def write_project(project, ruby_sources: false)
      module_loads = project.modules.map do |mod|
        %(  evaluate File.join(__dir__, "modules", #{ruby(mod.name)}, "module.rb"))
      end.join("\n")

      source = <<~RUBY
        # frozen_string_literal: true

        require "mxrb"

        output = ENV.fetch("MXRB_OUTPUT_PATH", File.join(__dir__, #{ruby(File.basename(@mpr_path))}))

        Mxrb.define(output) do
          mendix_version #{ruby(project.mendix_version || "10.18.0")}
          native_units File.join(__dir__, ".mxrb", "native_units.json")
          project_assets File.join(__dir__, ".mxrb", "assets.json"), root: __dir__
      #{'    ruby_app_sources File.join(__dir__, ".mxrb", "ruby_sources.json")' if ruby_sources}
          evaluate File.join(__dir__, ".mxrb", "native_units.rb")
          evaluate File.join(__dir__, "app", "security", "security.rb")
          evaluate File.join(__dir__, "app", "navigation", "navigation.rb")
          evaluate File.join(__dir__, "app", "design_system", "design_system.rb")
      #{module_loads}
        end
      RUBY
      write(File.join(@output_dir, "project.rb"), source)
    end

    def module_source(mod)
      <<~RUBY
        # frozen_string_literal: true

        self.module #{symbol(mod.name)} do
          evaluate File.join(__dir__, "domain", "model.rb")
          evaluate File.join(__dir__, "application", "application.rb")
          evaluate File.join(__dir__, "presentation", "presentation.rb")
          evaluate File.join(__dir__, "infrastructure", "infrastructure.rb")
          evaluate File.join(__dir__, "security", "security.rb")
        end
      RUBY
    end

    def project_security_doc(project)
      raw = project.all_units.find { |unit| project.parse_bson(unit)["$Type"] == "Security$ProjectSecurity" }
      raw && project.parse_bson(raw)
    end

    def security_source(doc)
      level = doc["SecurityLevel"]
      roles = IO::BsonCodec.parse_array(doc["UserRoles"]).fetch(:items).map do |role|
        module_roles = IO::BsonCodec.parse_array(role["ModuleRoles"]).fetch(:items)
        admin = role["ManageAllRoles"] == true
        args = [symbol(role.fetch("Name"))]
        args << "module_roles: #{ruby(module_roles)}" unless module_roles.empty?
        args << "admin: true" if admin
        "  user_role #{args.join(', ')}"
      end
      options = []
      options << "  admin_user_role #{ruby(doc["AdminUserRole"])}" unless doc["AdminUserRole"].to_s.empty?
      options << "  demo_users #{doc["EnableDemoUsers"] == true}"
      demo_users = doc["DemoUsers"] || IO::BsonCodec.build_array([])
      IO::BsonCodec.parse_array(demo_users).fetch(:items).each do |user|
        assigned_roles = IO::BsonCodec.parse_array(user["UserRoles"]).fetch(:items)
        options << "  demo_user #{ruby(user["UserName"])}, entity: #{ruby(user["Entity"])}, " \
                   "roles: #{ruby(assigned_roles)}, password: #{ruby(user["Password"])}"
      end
      guest = "  guest_access #{doc["EnableGuestAccess"] == true}"
      guest += ", role: #{ruby(doc["GuestUserRole"])}" unless doc["GuestUserRole"].to_s.empty?
      options << guest
      options << "  sign_in_microflow #{ruby(doc["SignInMicroflow"])}" unless doc["SignInMicroflow"].to_s.empty?
      password = doc["PasswordPolicySettings"]
      if password.is_a?(Hash)
        known = {
          "MinimumLength" => :minimum_length,
          "RequireDigit" => :require_digit,
          "RequireMixedCase" => :require_mixed_case,
          "RequireSymbol" => :require_symbol
        }
        policy = password.each_with_object({}) do |(key, value), result|
          next if %w[$ID $Type].include?(key)

          result[known.fetch(key, key.to_sym)] = value
        end
        options << "  password_policy(**#{ruby(policy)})"
      end
      <<~RUBY
        # frozen_string_literal: true

        security do
          security_level #{ruby(level)}
      #{roles.join("\n")}
      #{options.join("\n")}
        end
      RUBY
    end

    def navigation_source(navigation)
      return "# frozen_string_literal: true\n" unless navigation

      profiles = navigation.fetch(:profiles, []).flat_map { navigation_profile_source(_1) }
      <<~RUBY
        # frozen_string_literal: true

        navigation do
      #{profiles.join("\n")}
        end
      RUBY
    end

    def navigation_profile_source(profile)
      args = [symbol(profile.fetch(:name))]
      args << "home_page: #{ruby(profile[:home_page])}" if profile[:home_page]
      args << "home_microflow: #{ruby(profile[:home_microflow])}" if profile[:home_microflow]
      args << "sign_in_page: #{ruby(profile[:sign_in_page])}" if profile[:sign_in_page]
      args << "menu: #{ruby(profile[:menu])}" if profile[:menu]
      role_homes = profile.fetch(:role_homes, {})
      args << "role_homes: #{ruby(role_homes)}" if role_homes.is_a?(Hash) && !role_homes.empty?
      args << "offline: true" if profile[:offline]
      args << "kind: #{ruby(profile[:kind])}" unless profile[:kind].to_s.empty?
      args << "app_icon: #{ruby(profile[:app_icon])}" if profile[:app_icon]
      body = navigation_profile_body(profile, role_homes)
      return ["  profile #{args.join(', ')}"] if body.empty?

      ["  profile #{args.join(', ')} do", *body, "  end"]
    end

    def navigation_profile_body(profile, role_homes)
      details = role_homes.is_a?(Array) ? role_homes : profile.fetch(:role_home_details, [])
      titles = profile.fetch(:app_title, {}).map do |locale, text|
        "    title #{ruby(locale)}, #{ruby(text)}"
      end
      homes = details.map do |home|
        options = []
        options << "page: #{ruby(home[:page])}" if home[:page]
        options << "microflow: #{ruby(home[:microflow])}" if home[:microflow]
        suffix = options.empty? ? "" : ", #{options.join(', ')}"
        "    home_for #{ruby(home.fetch(:role))}#{suffix}"
      end
      items = profile.fetch(:items, []).flat_map { navigation_item_source(_1, 4) }
      extensions = if profile.fetch(:name).to_s == "Responsive"
                     ['    evaluate_dir File.join(__dir__, "responsive")']
                   else
                     []
                   end
      titles + homes + items + extensions
    end

    def design_system_source(design_system)
      return "# frozen_string_literal: true\n" unless design_system

      lines = design_system.fetch(:tokens, []).map do |token|
        args = [symbol(token.fetch(:name))]
        args << "value: #{ruby(token[:value])}" unless token[:value].nil?
        "  #{token.fetch(:kind)} #{args.join(', ')}"
      end
      lines.concat(design_system.fetch(:layouts, []).map { "  layout #{ruby(_1)}" })
      lines.concat(design_system.fetch(:components, []).map { "  component #{ruby(_1)}" })
      lines.concat(design_system.fetch(:accessibility, []).map { "  accessibility #{ruby(_1)}" })
      design_system.fetch(:themes, []).each do |theme|
        args = [ruby(theme.fetch(:name))]
        args << "inherits: #{ruby(theme[:inherits])}" if theme[:inherits]
        lines << "  theme #{args.join(', ')} do"
        theme.fetch(:tokens, []).each do |token|
          token_args = [symbol(token.fetch(:name))]
          token_args << "value: #{ruby(token[:value])}" unless token[:value].nil?
          lines << "    #{token.fetch(:kind)} #{token_args.join(', ')}"
        end
        lines << "  end"
      end
      design_system.fetch(:contrast_pairs, []).each do |pair|
        lines << "  contrast foreground: #{ruby(pair.fetch(:foreground))}, " \
                 "background: #{ruby(pair.fetch(:background))}, level: #{symbol(pair.fetch(:level))}"
      end
      lines << "  forbid_literal_colors" if design_system[:forbid_literal_colors]
      <<~RUBY
        # frozen_string_literal: true

        design_system do
      #{lines.join("\n")}
        end
      RUBY
    end

    def navigation_item_source(item, indent)
      pad = " " * indent
      caption = item.fetch(:caption)
      primary = caption["en_US"] || caption[:en_US] || caption.values.first || ""
      translations = caption.reject { |locale, _| locale.to_s == "en_US" }
      args = [ruby(primary)]
      args << "page: #{ruby(item[:page])}" if item[:page]
      args << "microflow: #{ruby(item[:microflow])}" if item[:microflow]
      args << "icon: #{ruby(item[:icon])}" if item[:icon]
      args << "translations: #{ruby(translations)}" unless translations.empty?
      children = item.fetch(:items, [])
      return ["#{pad}item #{args.join(', ')}"] if children.empty?

      ["#{pad}item #{args.join(', ')} do",
       *children.flat_map { navigation_item_source(_1, indent + 2) },
       "#{pad}end"]
    end

    def entity_source(entity, mod, associations, metadata = nil)
      attrs = entity.attributes.map do |attr|
        options = []
        options << "default: #{ruby(attr.default_value)}" unless attr.default_value.nil? || attr.default_value == ""
        options << "documentation: #{ruby(attr.documentation)}" unless attr.documentation.to_s.empty?
        options << "length: #{attr.length}" unless attr.length.nil?
        options << "localize_date: #{attr.localize_date}" unless attr.localize_date.nil?
        options << "enumeration: #{ruby(attr.enumeration)}" unless attr.enumeration.to_s.empty?
        options << 'required: true' if attr.required
        options << 'unique: true' if attr.unique
        "  #{attr.type || :string} #{symbol(attr.name)}#{options.empty? ? '' : ", #{options.join(', ')}"}"
      end
      assocs = associations.map do |assoc|
        target = mod.entities.find { _1.id == assoc.to_entity_id }&.name || assoc.to_entity_id
        qualified_target = target.to_s.include?('.') ? target : "#{mod.name}.#{target}"
        cardinality = association_cardinality(assoc)
        options = ["cardinality: #{symbol(cardinality)}"]
        options << "name: #{ruby(assoc.name)}"
        documentation = assoc.respond_to?(:documentation) ? assoc.documentation : nil
        options << "documentation: #{ruby(documentation)}" unless documentation.to_s.empty?
        inferred_storage = assoc.association_type == :ReferenceSet ? :Table : :Column
        storage_format = assoc.respond_to?(:storage_format) ? assoc.storage_format : nil
        if storage_format && storage_format != inferred_storage
          options << "storage_format: #{symbol(storage_format)}"
        end
        parent_delete = assoc.respond_to?(:parent_delete_behavior) ?
          assoc.parent_delete_behavior : :NoAction
        child_delete = assoc.respond_to?(:child_delete_behavior) ?
          assoc.child_delete_behavior : :NoAction
        options << "parent_delete: #{symbol(parent_delete)}" unless parent_delete == :NoAction
        options << "child_delete: #{symbol(child_delete)}" unless child_delete == :NoAction
        "  association #{ruby(qualified_target)}, #{options.join(', ')}"
      end
      flags = []
      flags << "  non_persistent!" unless entity.persistable
      if oql_view_entity?(entity)
        options = []
        options << "source: #{ruby(entity.oql_source_document)}" if entity.oql_source_document
        options << "query: #{ruby(entity.oql_query)}" unless entity.oql_query.to_s.empty?
        flags << "  oql_view #{options.join(', ')}" unless options.empty?
      end
      flags << "  documentation #{ruby(entity.documentation)}" unless entity.documentation.to_s.empty?
      generalization = entity.respond_to?(:generalization_target) ? entity.generalization_target : nil
      flags << "  generalizes #{ruby(generalization)}" if generalization
      system_members = entity.respond_to?(:system_members) ? entity.system_members : {}
      system_options = system_members.to_h.select { |_key, value| value }
      unless system_options.empty?
        flags << "  system_members #{system_options.map { |key, value| "#{key}: #{value}" }.join(', ')}"
      end
      indexes = entity.respond_to?(:indexes) ? entity.indexes : []
      Array(indexes).each do |index|
        indexed = IO::BsonCodec.parse_array(
          index['attributes'] || index['Attributes'] || index['IndexedAttributes']
        )[:items]
        members = indexed.filter_map { _1['attribute'] || _1['Attribute'] }.map { _1.to_s.split('.').last }
        next if members.empty?

        directions = indexed.map { |member| member.fetch('ascending', member.fetch('Ascending', true)) }
        options = []
        options << "ascending: #{ruby(directions)}" unless directions.all?
        include_offline = index['includeInOffline'] || index['IncludeInOffline']
        options << 'include_offline: true' if include_offline
        flags << "  index #{members.map { symbol(_1) }.join(', ')}#{options.empty? ? '' : ", #{options.join(', ')}"}"
      end
      metadata&.fetch(:lifecycle, [])&.each do |callback|
        flags << "  #{callback.fetch(:event)} microflow: #{symbol(callback.fetch(:handler))}"
      end
      access_rules = Array(entity.access_rules)
      access_lines = access_rules.filter_map { |rule| access_rule_source(rule) }
      # A partial access-rule export would replace the complete native rule
      # collection. Keep the collection opaque unless every rule is editable.
      access_lines = [] unless access_lines.size == access_rules.size
      <<~RUBY
        # frozen_string_literal: true

        entity #{symbol(entity.name)} do
      #{(attrs + assocs + flags + access_lines).join("\n")}
        end
      RUBY
    end

    def association_cardinality(association)
      return :many_to_many if association.association_type == :ReferenceSet
      return :one_to_one if association.owner == :Both

      :many_to_one
    end

    def access_rule_source(rule)
      role_list = rule.fetch(:roles).reject { _1.to_s.empty? }
      return nil if role_list.empty?
      roles = role_list.map { ruby(_1) }.join(", ")
      opts = []
      opts << "create: true" if rule[:create]
      opts << "delete: true" if rule[:delete]
      read_val  = reconstruct_access(rule.fetch(:default_rights, "None"), rule.fetch(:members, []), "ReadOnly",  "ReadWrite")
      write_val = reconstruct_access(rule.fetch(:default_rights, "None"), rule.fetch(:members, []), "ReadWrite", nil)
      opts << "read: #{format_access(read_val)}"   unless read_val  == :none
      opts << "write: #{format_access(write_val)}" unless write_val == :none
      opts << "default_rights: #{ruby(rule.fetch(:default_rights, 'None'))}"
      opts << "members: #{native_ruby(rule.fetch(:members, []))}"
      xpath = rule.fetch(:xpath, "")
      opts << "xpath: #{ruby(xpath)}" unless xpath.empty?
      "  access_rule #{[roles, *opts].join(', ')}"
    end

    def reconstruct_access(default_rights, members, primary_rights, secondary_rights)
      if default_rights == "ReadWrite"
        return :all if primary_rights == "ReadWrite"
        return :all if primary_rights == "ReadOnly"
      end
      if default_rights == "ReadOnly"
        return :all if primary_rights == "ReadOnly"
        explicit = members.select { _1[:rights] == primary_rights }.map { _1[:name] }
        return explicit unless explicit.empty?
        return :none
      end
      # default_rights == "None"
      explicit = members.select { |m|
        m[:rights] == primary_rights ||
          (secondary_rights && m[:rights] == secondary_rights)
      }.map { _1[:name] }
      explicit.empty? ? :none : explicit
    end

    def format_access(value)
      case value
      when :all, :none then ":#{value}"
      when Array       then "[#{value.map { symbol(_1) }.join(', ')}]"
      else ":#{value}"
      end
    end

    def unique_entity_filenames(entities, route: nil)
      suffix = route == "dtos" ? "_dto" : nil
      unique_filenames(entities, suffix:)
    end

    def unique_filenames(entities, suffix: nil)
      used = {}
      entities.to_h do |entity|
        base = underscore(entity.name)
        base = "#{base}#{suffix}" if suffix && !base.end_with?(suffix)
        candidate = "#{base}.rb"
        sequence = 2
        while used[candidate]
          candidate = "#{base}_#{sequence}.rb"
          sequence += 1
        end
        used[candidate] = true
        [entity.id, candidate]
      end
    end

    def underscore(value)
      value.to_s
           .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .tr(" -", "__")
           .gsub(/[^a-zA-Z0-9_]/, "")
           .downcase
    end

    def microflow_source(flow, metadata = nil)
      parameters = flow.parameters.filter_map do |param|
        next unless param.is_a?(Hash)
        name = param["Name"] || param["name"]
        type = param["VariableType"] || param["Type"] || param["type"]
        type_source = type.is_a?(Hash) ? native_ruby(type) : symbol(type)
        "  parameter #{symbol(name)}, type: #{type_source}" if name && type
      end
      body = parameters
      body << "  return_type #{symbol(flow.return_type)}" if flow.return_type.is_a?(String)
      body << "  documentation #{ruby(flow.documentation)}" unless flow.documentation.to_s.empty?
      body << "  allow_concurrent_execution #{flow.allow_concurrent_execution ? 'true' : 'false'}"
      apply_entity_access = flow.respond_to?(:apply_entity_access) && flow.apply_entity_access
      body << "  apply_entity_access #{apply_entity_access ? 'true' : 'false'}"
      body << "  mark_as_used #{flow.mark_as_used ? 'true' : 'false'}"
      body << "  excluded #{flow.excluded ? 'true' : 'false'}"
      body << "  allowed_roles #{flow.allowed_module_roles.map { symbol(_1) }.join(', ')}" unless flow.allowed_module_roles.empty?
      metadata&.fetch(:calls, [])&.each do |call|
        body << "  call #{call.fetch(:kind)}: #{symbol(call.fetch(:name))}"
      end
      metadata&.fetch(:repositories, [])&.each do |repository|
        body << "  uses_repository #{symbol(repository)}"
      end
      objects = Array(flow.objects)
      flows = Array(flow.flows)
      if editable_flow_body?(objects, flows)
        dsl_lines = body_dsl_lines(objects, flows, 2)
        body.concat(dsl_lines)
        fingerprint = flow_body_fingerprint(dsl_lines, flow)
        body << "  body_fingerprint #{ruby(fingerprint)}" if fingerprint
      elsif objects.any?
        body << "  # Native body baseline retained: this graph shape has no typed DSL mapping yet"
      end
      declaration = [symbol(flow.name)]
      declaration << "public: true" if metadata&.fetch(:public, false)
      <<~RUBY
        # frozen_string_literal: true

        microflow #{declaration.join(', ')} do
      #{body.join("\n")}
        end
      RUBY
    end

    def nanoflow_source(flow, metadata = nil)
      microflow_source(flow, metadata).sub(/(^\s*)microflow /, '\1nanoflow ')
    end

    def flow_body_fingerprint(lines, flow)
      builder = Dsl::FlowBuilder.new(
        flow.name, runtime: :server, kind: :microflow, public: false
      )
      builder.instance_eval(lines.join("\n"), @mpr_path, 1)
      definition = builder.to_h
      Dsl::FlowBuilder.body_digest(
        definition[:body], definition[:return_expression]
      )
    rescue StandardError, SyntaxError
      nil
    end

    def repositories_source(repositories)
      repositories.map do |repository|
        options = []
        options << "implementation: #{symbol(repository[:implementation])}" if repository[:implementation]
        options << "public: true" if repository[:public]
        options << "documentation: #{ruby(repository[:documentation])}" unless repository[:documentation].to_s.empty?
        "repository #{symbol(repository.fetch(:name))}#{options.empty? ? '' : ", #{options.join(', ')}"}"
      end.join("\n") + "\n"
    end

    def page_source(page, metadata = nil)
      body = []
      body << "  layout #{ruby(page.layout_id)}" if page.layout_id
      body << "  title #{ruby(page.title)}"
      body << "  popup!" if page.popup_width.to_i.positive? || page.popup_height.to_i.positive?
      body << "  allowed_roles #{page.allowed_module_roles.map { symbol(_1) }.join(', ')}" unless page.allowed_module_roles.empty?
      deep = page_deep_structure(page)
      if (source = metadata&.dig(:data_source) || page.data_source)
        body << "  data_source #{source.fetch(:kind)}: #{reference(source.fetch(:name))}"
      end
      body << "  deep_structure(#{native_ruby(deep, 2)})" if deep
      metadata&.fetch(:events, [])&.each do |event|
        args = []
        args << "target: #{symbol(event[:target])}" if event[:target]
        args << "#{event.fetch(:kind)}: #{symbol(event.fetch(:handler))}"
        body << "  #{event.fetch(:event)} #{args.join(', ')}"
      end
      widgets = metadata ? metadata.fetch(:widgets, []) : page.widgets
      widgets.each do |widget|
        rendered = render_widget(widget, 2)
        body.concat(rendered)
      end
      <<~RUBY
        # frozen_string_literal: true

        page #{symbol(page.name)} do
      #{body.join("\n")}
        end
      RUBY
    end

    PAGE_TYPED_KEYS = %w[$ID Name name].freeze
    def page_deep_structure(page)
      raw = page.raw_document
      return nil unless raw.is_a?(Hash)

      raw.reject { |key, _| PAGE_TYPED_KEYS.include?(key.to_s) }
    end

    def native_ruby(value, indent = 0)
      case value
      when BSON::Binary
        encoded = Base64.strict_encode64(value.data)
        "bson_binary(#{ruby(encoded)}, subtype: #{value.type.inspect})"
      when Time
        "Time.at(#{value.to_i}, #{value.nsec}, :nanosecond).utc"
      when Hash
        return "{}" if value.empty?

        pad = " " * indent
        child_pad = " " * (indent + 2)
        entries = value.map do |key, item|
          "#{child_pad}#{ruby(key)} => #{native_ruby(item, indent + 2)}"
        end
        "{\n#{entries.join(",\n")}\n#{pad}}"
      when Array
        return "[]" if value.empty?

        pad = " " * indent
        child_pad = " " * (indent + 2)
        entries = value.map { "#{child_pad}#{native_ruby(_1, indent + 2)}" }
        "[\n#{entries.join(",\n")}\n#{pad}]"
      else
        ruby(value)
      end
    end

    def menu_source(menu)
      body = menu.items.flat_map { menu_item_source(_1, 2) }
      if menu.raw_document.is_a?(Hash)
        deep = menu.raw_document.reject { |key, _| %w[$ID Name name].include?(key.to_s) }
        body.unshift("  deep_structure(#{native_ruby(deep, 2)})")
      end
      <<~RUBY
        # frozen_string_literal: true

        menu #{symbol(menu.name)} do
      #{body.join("\n")}
        end
      RUBY
    end

    def menu_item_source(item, indent)
      pad = " " * indent
      args = [ruby(item.fetch(:caption))]
      args << "page: #{ruby(item[:page])}" if item[:page]
      children = Array(item[:items])
      return ["#{pad}item #{args.join(', ')}"] if children.empty?

      lines = ["#{pad}item #{args.join(', ')} do"]
      lines.concat(children.flat_map { menu_item_source(_1, indent + 2) })
      lines << "#{pad}end"
    end

    def render_widget(widget, indent)
      pad       = " " * indent
      child_pad = " " * (indent + 2)
      # Architecture metadata is serialized through JSON inside generated MPRs,
      # so a second export can surface widget type values as strings.
      type      = widget.fetch(:type).to_sym
      options   = widget.fetch(:options, {})

      # Snippet: snippet :name, from: "..."
      if type == :snippet
        snippet_ref = options[:snippet].to_s
        args = [ruby(widget.fetch(:name))]
        args << "from: #{ruby(snippet_ref)}" unless snippet_ref == widget.fetch(:name).to_s
        return ["#{pad}snippet #{args.join(', ')}"]
      end

      if type == :native_widget
        return [
          "#{pad}native_widget #{symbol(widget.fetch(:name))},",
          "#{child_pad}type: #{ruby(options.fetch(:native_type))},",
          "#{child_pad}deep_structure: #{native_ruby(options.fetch(:deep_structure), indent + 2)}"
        ]
      end

      if type == :pluggable_widget
        args = [symbol(widget.fetch(:name)), "widget_id: #{ruby(options.fetch(:widget_id))}"]
        args << "widget_name: #{ruby(options[:widget_name])}" if options[:widget_name]
        args << "properties: #{native_ruby(options[:properties])}" if options[:properties]
        args << "class_name: #{ruby(options[:class])}" if options[:class]
        return ["#{pad}pluggable_widget #{args.join(', ')}"]
      end

      # drop_down
      if type == :drop_down
        args = [symbol(widget.fetch(:name))]
        args << "attribute: #{symbol(options[:attribute])}" if options[:attribute]
        args << "caption: #{ruby(options[:caption])}" if options.key?(:caption) && !options[:caption].nil?
        return ["#{pad}drop_down #{args.join(', ')}"]
      end

      # Container: recurse into children
      if type == :container
        children_lines = Array(widget[:children]).flat_map { render_widget(_1, indent + 2) }
        args = [symbol(widget.fetch(:name))]
        args << "class_name: #{ruby(options[:class])}" if options[:class]
        if children_lines.empty?
          return ["#{pad}container #{args.join(', ')}"]
        else
          lines = ["#{pad}container #{args.join(', ')} do"]
          lines.concat(children_lines)
          lines << "#{pad}end"
          return lines
        end
      end

      args = [symbol(widget.fetch(:name))]
      args << "attribute: #{symbol(options[:attribute])}" if options[:attribute]
      args << "caption: #{ruby(options[:caption])}" if options.key?(:caption) && !options[:caption].nil?
      args << "entity: #{ruby(options[:entity])}" if options[:entity]
      args << "lines: #{options[:lines]}" if type == :text_area && options[:lines]
      if type == :reference_selector && options[:display_attribute]
        args << "display_attribute: #{ruby(options[:display_attribute])}"
      end

      widget_body = []
      Array(options[:columns]).each do |column|
        column_args = [symbol(column.fetch(:name))]
        column_args << "attribute: #{symbol(column[:attribute])}" if column[:attribute]
        column_args << "caption: #{ruby(column[:caption])}" if column.key?(:caption) && !column[:caption].nil?
        widget_body << "#{child_pad}column #{column_args.join(', ')}"
      end
      Array(options[:tabs]).each do |tab|
        tab_args = [symbol(tab.fetch(:name))]
        tab_args << "caption: #{ruby(tab[:caption])}" if tab.key?(:caption) && !tab[:caption].nil?
        tab_widgets = Array(tab[:widgets])
        if tab_widgets.empty?
          widget_body << "#{child_pad}tab_page #{tab_args.join(', ')}"
        else
          widget_body << "#{child_pad}tab_page #{tab_args.join(', ')} do"
          widget_body.concat(tab_widgets.flat_map { render_widget(_1, indent + 4) })
          widget_body << "#{child_pad}end"
        end
      end

      if (sb = options[:search_bar])
        sb_lines = ["#{child_pad}search_bar do"]
        Array(sb[:fields]).each do |field|
          sf_args = [symbol(field[:attribute])]
          sf_args << "caption: #{ruby(field[:caption])}" if field[:caption]
          sb_lines << "#{child_pad}  search_field #{sf_args.join(', ')}"
        end
        sb_lines << "#{child_pad}end"
        widget_body.concat(sb_lines)
      end

      if (tb = options[:toolbar])
        tb_lines = ["#{child_pad}toolbar do"]
        Array(tb[:buttons]).each do |btn|
          btn_method = case btn[:type].to_sym
          when :new    then "new_button"
          when :delete then "delete_button"
          when :search then "search_button"
          when :export then "export_button"
          end
          next unless btn_method
          tb_arg = btn[:caption] ? "caption: #{ruby(btn[:caption])}" : nil
          tb_lines << "#{child_pad}  #{btn_method}#{tb_arg ? "(#{tb_arg})" : ""}"
        end
        tb_lines << "#{child_pad}end"
        widget_body.concat(tb_lines)
      end

      widget.fetch(:events, []).each do |event|
        widget_body << "#{child_pad}#{event.fetch(:event)} #{event.fetch(:kind)}: #{symbol(event.fetch(:handler))}"
      end

      if widget_body.empty?
        ["#{pad}#{type} #{args.join(', ')}"]
      else
        lines = ["#{pad}#{type} #{args.join(', ')} do"]
        lines.concat(widget_body)
        lines << "#{pad}end"
      end
    end

    # ── Microflow / nanoflow body export ─────────────────────────────────────

    def editable_flow_body?(objects, flows, nested: false)
      return nested if objects.empty?
      local_flows = flows_for_objects(flows, objects)
      unless nested
        return false unless objects.count { _1["$Type"] == "Microflows$StartEvent" } == 1
        return false unless objects.any? { _1["$Type"] == "Microflows$EndEvent" }
      end
      connected_objects = objects.reject do |object|
        %w[Microflows$Annotation Microflows$MicroflowParameter].include?(object["$Type"])
      end
      return false if connected_objects.size > 1 && local_flows.empty?
      return false unless objects.all? { EDITABLE_FLOW_OBJECT_TYPES.include?(_1["$Type"]) }
      return false unless local_flows.all? do
        %w[Microflows$SequenceFlow Microflows$AnnotationFlow].include?(_1["$Type"])
      end
      sequence_flows = local_flows.select { _1["$Type"] == "Microflows$SequenceFlow" }
      return false if sequence_flows.select { _1["IsErrorHandler"] == true }
                           .group_by { _1["OriginPointer"] }.any? { |_origin, items| items.size > 1 }

      by_id = objects.to_h { [_1["$ID"], _1] }

      objects.all? do |object|
        case object["$Type"]
        when "Microflows$ActionActivity"
          editable_action?(object["Action"] || {})
        when "Microflows$ExclusiveSplit"
          decision_shape_editable?(object, sequence_flows, by_id)
        when "Microflows$InheritanceSplit"
          branches = sequence_flows.select { _1["OriginPointer"] == object["$ID"] }
          !object["SplitVariableName"].to_s.empty? &&
            branches.size >= 2 &&
            branches.all? { by_id.key?(_1["DestinationPointer"]) }
        when "Microflows$LoopedActivity"
          collection = object["ObjectCollection"] || {}
          inner_objects = bson_items(collection["Objects"])
          source = loop_source(object)
          return false unless %w[
            Microflows$WhileLoopCondition Microflows$IterableList
            Microflows$IteratorList
          ].include?(source["$Type"])
          editable_flow_body?(
            inner_objects, flows, nested: true
          )
        else
          true
        end
      end
    end

    def editable_action?(action)
      return false unless EDITABLE_ACTION_TYPES.include?(action["$Type"])

      case action["$Type"]
      when "Microflows$ChangeObjectAction"
        action.fetch("Commit", "No") == "No" && action.fetch("RefreshInClient", false) == false
      when "Microflows$CreateChangeAction", "Microflows$ChangeAction"
        %w[No Yes YesWithoutEvents].include?(action.fetch("Commit", "No")) &&
          [true, false].include?(action.fetch("RefreshInClient", false))
      when "Microflows$RetrieveAction"
        source = action["RetrieveSource"] || {}
        case source["$Type"]
        when "Microflows$DatabaseRetrieveSource"
          range_type = source.dig("Range", "$Type")
          %w[Microflows$ConstantRange Microflows$CustomRange].include?(range_type) &&
            bson_items(source.dig("NewSortings", "Sortings") || source["SortItems"]).all? do |sorting|
              !(sorting["AttributePath"] || sorting.dig("AttributeRef", "Attribute")).to_s.empty?
            end
        when "Microflows$AssociationRetrieveSource"
          !source["AssociationId"].to_s.empty? && !source["StartVariableName"].to_s.empty?
        else
          false
        end
      when "Microflows$ShowMessageAction"
        bson_items(action.dig("Template", "Parameters")).all? { _1["Expression"] }
      when "Microflows$LogMessageAction"
        bson_items(action.dig("MessageTemplate", "Parameters")).all? { _1["Expression"] }
      when "Microflows$ShowFormAction"
        settings = action["FormSettings"] || {}
        title = settings["FormTitle"] || settings["TitleOverride"]
        title_supported = title.nil? ||
          (title.is_a?(Hash) && bson_items(title["Parameters"]).empty?)
        title_supported && bson_items(settings["ParameterMappings"]).all? do |mapping|
          mapping["Parameter"] && mapping["Argument"]
        end
      when "Microflows$JavaActionCallAction"
        !action["JavaAction"].to_s.empty? && bson_items(action["ParameterMappings"]).all? do |mapping|
          value = mapping["Value"] || {}
          mapping["Parameter"] && %w[
            Microflows$BasicJavaActionParameterValue
            Microflows$BasicCodeActionParameterValue
            Microflows$EntityTypeJavaActionParameterValue
            Microflows$MicroflowJavaActionParameterValue
            Microflows$ImportMappingJavaActionParameterValue
            Microflows$ExportMappingJavaActionParameterValue
          ].include?(value["$Type"])
        end
      when "Microflows$JavaScriptActionCallAction"
        !action["JavaScriptAction"].to_s.empty? && bson_items(action["ParameterMappings"]).all? do |mapping|
          value = mapping["ParameterValue"] || {}
          mapping["Parameter"] && %w[
            Microflows$BasicCodeActionParameterValue
            Microflows$EntityTypeCodeActionParameterValue
          ].include?(value["$Type"])
        end
      when "Microflows$NanoflowCallAction"
        !action.dig("NanoflowCall", "Nanoflow").to_s.empty? &&
          bson_items(action.dig("NanoflowCall", "ParameterMappings")).all? do |mapping|
          mapping["Parameter"] && mapping["Argument"]
        end
      when "Microflows$AppServiceCallAction"
        !action["AppServiceAction"].to_s.empty? && bson_items(action["ParameterMappings"]).all? do |mapping|
          mapping["Parameter"] && mapping["Argument"]
        end
      when "Microflows$ValidationFeedbackAction"
        bson_items(action.dig("FeedbackTemplate", "Parameters")).all? do |parameter|
          parameter["Expression"]
        end
      when "Microflows$RestCallAction"
        http = action["HttpConfiguration"] || {}
        request = action["RequestHandling"] || {}
        !http["HttpMethod"].to_s.empty? &&
          bson_items(http["HttpHeaderEntries"]).all? { _1["Key"] && _1["Value"] } &&
          bson_items(http.dig("CustomLocationTemplate", "Parameters")).all? {
            _1["Expression"]
          } &&
          request["$Type"] == "Microflows$MappingRequestHandling"
      else
        true
      end
    end

    def decision_shape_editable?(object, flows, by_id)
      condition = object["SplitCondition"] || {}
      condition_supported = !condition["Expression"].to_s.empty? ||
        (condition["$Type"] == "Microflows$RuleSplitCondition" &&
         !condition.dig("RuleCall", "Microflow").to_s.empty? &&
         bson_items(condition.dig("RuleCall", "ParameterMappings")).all? {
           _1["Parameter"] && _1["Argument"]
         })
      return false unless condition_supported

      branches = flows.reject { _1["IsErrorHandler"] == true }
                      .select { _1["OriginPointer"] == object["$ID"] }
      branches.size >= 2 && branches.all? { by_id.key?(_1["DestinationPointer"]) }
    end

    def body_dsl_lines(objects, flows, indent = 2, nested: false)
      return [] if objects.empty?
      by_id   = objects.to_h { |o| [o["$ID"], o] }
      fwd_map = {}
      err_map = {}
      flows.each do |f|
        next unless f["$Type"] == "Microflows$SequenceFlow"

        from     = f["OriginPointer"]
        to       = f["DestinationPointer"]
        case_val = flow_case_value(f)
        if f["IsErrorHandler"] == true
          err_map[from] = to
        else
          fwd_map[from] ||= []
          fwd_map[from] << { to: to, case_val: case_val }
        end
      end
      start = objects.find { |o| o["$Type"] == "Microflows$StartEvent" }
      if nested && !start
        destinations = flows.to_h { [_1["DestinationPointer"], true] }
        start = objects.find { !destinations.key?(_1["$ID"]) }
      end
      return [] unless start
      lines = []
      linearize_flow(start["$ID"], fwd_map, err_map, by_id, flows, {}, lines, indent, nil)
      lines
    end

    def flow_case_value(flow)
      case_doc = bson_items(flow["CaseValues"]).first || flow["NewCaseValue"]
      value = case_doc&.dig("Value")
      return true if value == "true"
      return false if value == "false"

      value
    end

    def linearize_flow(cursor, fwd, err, by_id, graph_flows, seen, lines, indent, stop_at)
      while cursor && cursor != stop_at
        break if seen[cursor]
        seen[cursor] = true
        obj = by_id[cursor]
        break unless obj

        case obj["$Type"]
        when "Microflows$StartEvent"
          cursor = (fwd[cursor] || []).first&.dig(:to)

        when "Microflows$ActionActivity"
          line = action_dsl_line(obj, indent)
          lines << line if line
          next_id  = (fwd[cursor] || []).first&.dig(:to)
          error_to = err[cursor]
          if error_to
            rescue_lines = []
            linearize_flow(
              error_to, fwd, err, by_id, graph_flows,
              seen.dup, rescue_lines, indent + 2, nil
            )
            lines << "#{' ' * indent}rescue_all do"
            lines.concat(rescue_lines)
            lines << "#{' ' * indent}end"
          end
          cursor = next_id

        when "Microflows$ExclusiveSplit"
          condition_doc = obj["SplitCondition"] || {}
          condition = if condition_doc["$Type"] == "Microflows$RuleSplitCondition"
            rule = condition_doc["RuleCall"] || {}
            mappings = bson_items(rule["ParameterMappings"]).to_h do |mapping|
              [mapping["Parameter"].to_s, mapping["Argument"].to_s]
            end
            { rule: rule["Microflow"], pass: mappings }
          else
            condition_doc["Expression"].to_s
          end
          nexts      = fwd[cursor] || []
          merge_id = find_common_merge_node(nexts.map { _1[:to] }, fwd, by_id)
          rendered_condition = condition.is_a?(Hash) ?
            "(#{ruby(condition)})" : ruby(condition)
          lines << "#{' ' * indent}decision #{rendered_condition} do"
          nexts.each do |edge|
            branch_lines = []
            linearize_flow(
              edge[:to], fwd, err, by_id, graph_flows, seen.dup,
              branch_lines, indent + 4, merge_id
            )
            lines << "#{' ' * (indent + 2)}on(#{ruby(edge[:case_val])}) do"
            lines.concat(branch_lines)
            lines << "#{' ' * (indent + 2)}end"
          end
          lines << "#{' ' * indent}end"
          cursor = merge_id

        when "Microflows$ExclusiveMerge"
          cursor = (fwd[cursor] || []).first&.dig(:to)

        when "Microflows$InheritanceSplit"
          nexts = fwd[cursor] || []
          merge_id = find_common_merge_node(nexts.map { _1[:to] }, fwd, by_id)
          lines << "#{' ' * indent}type_decision :#{obj["SplitVariableName"]} do"
          nexts.each do |edge|
            branch_lines = []
            linearize_flow(
              edge[:to], fwd, err, by_id, graph_flows, seen.dup,
              branch_lines, indent + 4, merge_id
            )
            if edge[:case_val].to_s.empty?
              lines << "#{' ' * (indent + 2)}otherwise do"
            else
              lines << "#{' ' * (indent + 2)}on_type #{ruby(edge[:case_val])} do"
            end
            lines.concat(branch_lines)
            lines << "#{' ' * (indent + 2)}end"
          end
          lines << "#{' ' * indent}end"
          cursor = merge_id

        when "Microflows$LoopedActivity"
          loop_src = loop_source(obj)
          variable  = (loop_src["ListVariableName"] || loop_src["Variable"]).to_s
          iterator  = (loop_src["VariableName"] || loop_src["IteratorVariable"]).to_s
          inner_col = obj["ObjectCollection"] || {}
          inner_objects = bson_items(inner_col["Objects"])
          inner_lines = body_dsl_lines(
            inner_objects,
            graph_flows,
            indent + 2,
            nested: true
          )
          if loop_src["$Type"] == "Microflows$WhileLoopCondition"
            lines << "#{' ' * indent}while_loop #{ruby(loop_src["WhileExpression"])} do"
          else
            as_clause = (iterator != variable && !iterator.empty?) ? ", as: :#{iterator}" : ""
            lines << "#{' ' * indent}loop_over :#{variable}#{as_clause} do"
          end
          lines.concat(inner_lines)
          lines << "#{' ' * indent}end"
          cursor = (fwd[cursor] || []).first&.dig(:to)

        when "Microflows$EndEvent"
          ret = obj["ReturnValue"].to_s.strip
          unless ret.empty?
            if (match = ret.match(/\A\$([A-Za-z_][A-Za-z0-9_]*)\z/))
              lines << "#{' ' * indent}return_value :#{match[1]}"
            else
              lines << "#{' ' * indent}return_value #{ruby(ret)}"
            end
          else
            lines << "#{' ' * indent}end_flow" if indent > 2
          end
          break

        when "Microflows$ErrorEvent"
          lines << "#{' ' * indent}error_event"
          break

        when "Microflows$ContinueEvent"
          lines << "#{' ' * indent}continue_loop"
          break

        else
          cursor = (fwd[cursor] || []).first&.dig(:to)
        end
      end
    end

    def flows_for_objects(flows, objects)
      ids = objects.to_h { [_1["$ID"], true] }
      flows.select do |flow|
        ids.key?(flow["OriginPointer"]) && ids.key?(flow["DestinationPointer"])
      end
    end

    def loop_source(object)
      object["LoopSource"] || object["LoopObject"] || begin
        if object["ListVariableName"] || object["IteratorVariableName"]
          {
            "$Type" => "Microflows$IterableList",
            "ListVariableName" => object["ListVariableName"],
            "VariableName" => object["IteratorVariableName"]
          }
        else
          {}
        end
      end
    end

    def find_merge_node(true_start, false_start, fwd, by_id)
      t = reachable_merge_ids(true_start,  fwd, by_id)
      f = reachable_merge_ids(false_start, fwd, by_id)
      (t & f).first
    end

    def find_common_merge_node(starts, fwd, by_id)
      sets = starts.compact.map { reachable_merge_ids(_1, fwd, by_id) }
      return nil if sets.empty?

      sets.reduce { |common, ids| common & ids }.first
    end

    def reachable_merge_ids(start_id, fwd, by_id)
      result  = []
      visited = {}
      queue   = [start_id].compact
      while (id = queue.shift)
        next if visited[id]
        visited[id] = true
        obj = by_id[id]
        next unless obj
        result << id if obj["$Type"] == "Microflows$ExclusiveMerge"
        (fwd[id] || []).each { |e| queue << e[:to] }
      end
      result
    end

    def action_dsl_line(obj, indent)
      action = obj["Action"] || {}
      pad    = " " * indent
      case action["$Type"]
      when "Microflows$CreateObjectAction", "Microflows$CreateChangeAction"
        legacy = action["$Type"] == "Microflows$CreateChangeAction"
        members = member_specs(action[legacy ? "Items" : "Members"])
        has_associations = members.any? { !_1[:association].to_s.empty? }
        set_arg = members.empty? || has_associations ?
          "" : ", set: { #{members_dsl(members)} }"
        variable = legacy ? action["VariableName"] : action["OutputVariableName"]
        commit_a = action["Commit"] == "Yes" ? ", commit: true" : ""
        commit_a = ", commit: true, with_events: false" if action["Commit"] == "YesWithoutEvents"
        refresh_a = action["RefreshInClient"] == true ? ", refresh: true" : ""
        command = "#{pad}create_object #{ruby(action["Entity"])}, as: :#{variable}#{set_arg}#{commit_a}#{refresh_a}"
        has_associations ? member_block(command, members, indent) : command
      when "Microflows$ChangeObjectAction", "Microflows$ChangeAction"
        legacy = action["$Type"] == "Microflows$ChangeAction"
        members = member_specs(action[legacy ? "Items" : "Members"])
        variable = legacy ? action["ChangeVariableName"] : action["Variable"]
        commit_a = action["Commit"] == "Yes" ? ", commit: true" : ""
        commit_a = ", commit: true, with_events: false" if action["Commit"] == "YesWithoutEvents"
        refresh_a = action["RefreshInClient"] == true ? ", refresh: true" : ""
        has_associations = members.any? { !_1[:association].to_s.empty? }
        set_arg = members.empty? || has_associations ?
          "" : ", set: { #{members_dsl(members)} }"
        command = "#{pad}change_object :#{variable}#{set_arg}#{commit_a}#{refresh_a}"
        has_associations ? member_block(command, members, indent) : command
      when "Microflows$RetrieveAction"
        src      = action["RetrieveSource"] || {}
        variable = action["ResultVariableName"] || action["ResultListName"]
        if src["$Type"] == "Microflows$AssociationRetrieveSource"
          "#{pad}retrieve_association :#{src["StartVariableName"]}, " \
            "association: #{ruby(src["AssociationId"])}, as: :#{variable}"
        else
          xpath = (src["XpathConstraint"] || src["XPath"]).to_s
          args = [ruby(src["Entity"]), "as: :#{variable}"]
          args << "xpath: #{ruby(xpath)}" unless xpath.empty?
          range = src["Range"] || {}
          if range["$Type"] == "Microflows$CustomRange"
            limit = range["LimitExpression"].to_s
            args << "limit: #{ruby(limit)}" unless limit.empty?
          elsif range["SingleObject"] == true
            args << "single: true"
          end
          sortings = bson_items(src.dig("NewSortings", "Sortings") || src["SortItems"])
          unless sortings.empty?
            rendered = sortings.map do |sorting|
              attribute = sorting["AttributePath"] ||
                sorting.dig("AttributeRef", "Attribute")
              "[#{ruby(attribute)}, :#{underscore(sorting["SortOrder"])}]"
            end
            args << "sort: [#{rendered.join(', ')}]"
          end
          "#{pad}retrieve_objects #{args.join(', ')}"
        end
      when "Microflows$CommitObjectsAction", "Microflows$CommitAction"
        legacy = action["$Type"] == "Microflows$CommitAction"
        variable = legacy ? action["CommitVariableName"] : action["Variable"]
        with_events = legacy ? action.fetch("WithEvents", true) : action["CommitWithoutEvents"] != true
        events_a = with_events ? "" : ", with_events: false"
        refresh_a = action["RefreshInClient"] == true ? ", refresh: true" : ""
        "#{pad}commit :#{variable}#{events_a}#{refresh_a}"
      when "Microflows$DeleteAction"
        variable = action["DeleteVariableName"] || action["DeleteVariable"]
        refresh_a = action["RefreshInClient"] == true ? ", refresh: true" : ""
        "#{pad}delete :#{variable}#{refresh_a}"
      when "Microflows$MicroflowCallAction"
        call    = action["MicroflowCall"] || {}
        out     = if action["UseReturnVariable"] == true
          (action["ResultVariableName"] || action["OutputVariableName"]).to_s
        else
          ""
        end
        as_a    = out.empty? ? "" : ", as: :#{out}"
        stored_result = (action["ResultVariableName"] || action["OutputVariableName"]).to_s
        result_a = if out.empty? && !stored_result.empty?
          ", result_name: #{symbol(stored_result)}, use_return: false"
        elsif action["UseReturnVariable"] == true && out.empty?
          ", use_return: true"
        else
          ""
        end
        params = bson_items(call["ParameterMappings"]).map { [_1["Parameter"], _1["Argument"]] }
        pass_a = params.empty? ? "" : ", pass: #{pass_source(params)}"
        "#{pad}call_microflow #{ruby(call["Microflow"])}#{as_a}#{pass_a}#{result_a}"
      when "Microflows$CreateVariableAction"
        type = action.dig("VariableType", "$Type").to_s
        type = type.delete_prefix("DataTypes$").delete_suffix("Type")
        value = action["InitialValue"]
        value_a = value.nil? || value.to_s.empty? ? "" : ", value: #{ruby_val(value)}"
        type_a = type.empty? ? "" : ", type: #{symbol(type)}"
        "#{pad}create_variable :#{action["VariableName"]}#{type_a}#{value_a}"
      when "Microflows$ChangeVariableAction"
        "#{pad}change_variable :#{action["ChangeVariableName"]}, to: #{ruby_val(action["Value"])}"
      when "Microflows$ShowMessageAction"
        template = action["Template"] || {}
        translations = translated_items(template["Text"]).to_h do |translation|
          [translation["LanguageCode"].to_s, translation["Text"].to_s]
        end
        parameters = bson_items(template["Parameters"]).map { _1["Expression"] }
        text = translations["en_US"] || translations.values.first.to_s
        type_a = action["Type"].to_s.empty? ? "" : ", type: :#{underscore(action["Type"])}"
        blocking_a = action["Blocking"] == true ? ", blocking: true" : ""
        translations_a = translations.size > 1 ? ", translations: #{ruby(translations)}" : ""
        parameters_a = parameters.empty? ? "" : ", parameters: #{ruby(parameters)}"
        "#{pad}show_message #{ruby(text)}#{type_a}#{blocking_a}#{translations_a}#{parameters_a}"
      when "Microflows$LogMessageAction"
        template = action["MessageTemplate"] || {}
        parameters = bson_items(template["Parameters"]).map { _1["Expression"] }
        level_a = action["Level"].to_s.empty? ? "" : ", level: :#{underscore(action["Level"])}"
        node_a = action["Node"].to_s.empty? ? "" : ", node: #{ruby(action["Node"])}"
        stack_a = action["IncludeLatestStackTrace"] == true ? ", include_stack: true" : ""
        parameters_a = parameters.empty? ? "" : ", parameters: #{ruby(parameters)}"
        "#{pad}log_message #{ruby(template["Text"].to_s)}#{level_a}#{node_a}#{stack_a}#{parameters_a}"
      when "Microflows$ShowFormAction"
        settings = action["FormSettings"] || {}
        args = [ruby(settings["Form"])]
        variable = action["FormObjectVariable"].to_s
        args << "object: :#{variable}" unless variable.empty?
        location = settings["Location"].to_s
        args << "location: :#{underscore(location)}" unless location.empty?
        mappings = bson_items(settings["ParameterMappings"]).map do |mapping|
          "#{ruby(mapping["Parameter"])} => #{ruby_val(mapping["Argument"])}"
        end
        args << "pass: { #{mappings.join(', ')} }" unless mappings.empty?
        close_pages = action["NumberOfPagesToClose"].to_s
        args << "close_pages: #{close_pages.to_i}" unless close_pages.empty?
        title = settings["FormTitle"] || settings["TitleOverride"]
        translations = translated_items(title&.fetch("Text", title)).to_h do |translation|
          [translation["LanguageCode"].to_s, translation["Text"].to_s]
        end
        args << "title: #{ruby(translations)}" unless translations.empty?
        "#{pad}show_page #{args.join(', ')}"
      when "Microflows$CloseFormAction"
        count = action["NumberOfPagesToClose"].to_s
        count.empty? ? "#{pad}close_page" : "#{pad}close_page count: #{count.to_i}"
      when "Microflows$JavaActionCallAction"
        call_action_line(
          pad, "call_java", action["JavaAction"], action["ResultVariableName"],
          bson_items(action["ParameterMappings"]).map {
            [_1["Parameter"], code_action_parameter_value(_1["Value"])]
          },
          action["UseReturnVariable"]
        )
      when "Microflows$JavaScriptActionCallAction"
        call_action_line(
          pad, "call_javascript", action["JavaScriptAction"], action["OutputVariableName"],
          bson_items(action["ParameterMappings"]).map {
            [_1["Parameter"], code_action_parameter_value(_1["ParameterValue"])]
          },
          action["UseReturnVariable"]
        )
      when "Microflows$NanoflowCallAction"
        call = action["NanoflowCall"] || {}
        call_action_line(
          pad, "call_nanoflow", call["Nanoflow"], action["OutputVariableName"],
          bson_items(call["ParameterMappings"]).map { [_1["Parameter"], _1["Argument"]] },
          action["UseReturnVariable"]
        )
      when "Microflows$AppServiceCallAction"
        call_action_line(
          pad, "call_app_service", action["AppServiceAction"], action["ResultVariableName"],
          bson_items(action["ParameterMappings"]).map { [_1["Parameter"], _1["Argument"]] },
          action["UseReturnVariable"]
        )
      when "Microflows$AggregateAction"
        args = [
          ":#{action["AggregateVariableName"]}",
          "function: :#{underscore(action["AggregateFunction"])}",
          "as: :#{action["VariableName"]}"
        ]
        args << "attribute: #{ruby(action["Attribute"])}" unless action["Attribute"].to_s.empty?
        "#{pad}aggregate #{args.join(', ')}"
      when "Microflows$RollbackAction"
        refresh = action["RefreshInClient"] == true ? ", refresh: true" : ""
        "#{pad}rollback :#{action["RollbackVariableName"]}#{refresh}"
      when "Microflows$CastAction"
        "#{pad}cast :#{action["VariableName"]}"
      when "Microflows$CreateListAction"
        "#{pad}create_list #{ruby(action["Entity"])}, as: :#{action["VariableName"]}"
      when "Microflows$ListOperationsAction"
        operation = action["NewOperation"] || {}
        op = operation["$Type"].to_s.delete_prefix("Microflows$")
        args = [":#{underscore(op)}", ":#{operation['ListName']}"]
        second = operation["SecondListOrObjectName"].to_s
        expression = operation["Expression"]
        args << "with: :#{second}" unless second.empty?
        args << "expression: #{ruby(expression)}" unless expression.nil?
        args << "as: :#{action['ResultVariableName']}"
        "#{pad}list_operation #{args.join(', ')}"
      when "Microflows$ChangeListAction"
        "#{pad}change_list :#{action["ChangeVariableName"]}, " \
          "action: :#{underscore(action["Type"])}, value: #{ruby_val(action["Value"])}"
      when "Microflows$ValidationFeedbackAction"
        template = action["FeedbackTemplate"] || {}
        translations = translated_items(template["Text"]).to_h do |translation|
          [translation["LanguageCode"].to_s, translation["Text"].to_s]
        end
        parameters = bson_items(template["Parameters"]).map { _1["Expression"] }
        args = [":#{action["ValidationVariableName"]}"]
        args << "attribute: #{ruby(action["Attribute"])}" unless action["Attribute"].to_s.empty?
        args << "association: #{ruby(action["Association"])}" unless action["Association"].to_s.empty?
        args << "translations: #{ruby(translations)}"
        args << "parameters: #{ruby(parameters)}" unless parameters.empty?
        error = underscore(action["ErrorHandlingType"])
        args << "error: :#{error}" unless error == "rollback"
        "#{pad}validation_feedback #{args.join(', ')}"
      when "Microflows$RestCallAction"
        rest_call_line(pad, action)
      end
    end

    def rest_call_line(pad, action)
      http = action["HttpConfiguration"] || {}
      location = http["CustomLocationTemplate"] || {}
      headers = bson_items(http["HttpHeaderEntries"]).to_h do |header|
        [header["Key"].to_s, header["Value"].to_s]
      end
      request = action["RequestHandling"] || {}
      result = action["ResultHandling"] || {}
      import_call = result["ImportMappingCall"] || {}
      args = [
        "method: :#{underscore(http["HttpMethod"])}",
        "location: #{ruby(location["Text"].to_s)}"
      ]
      parameters = bson_items(location["Parameters"]).map { _1["Expression"] }
      args << "location_parameters: #{ruby(parameters)}" unless parameters.empty?
      args << "headers: #{ruby(headers)}" unless headers.empty?
      args << "request_mapping: #{ruby(request["MappingId"])}" if request["MappingId"]
      args << "request_variable: :#{request["MappingVariableName"]}" if request["MappingVariableName"]
      args << "result_mapping: #{ruby(import_call["ReturnValueMapping"])}" if import_call["ReturnValueMapping"]
      args << "as: :#{result["ResultVariableName"]}" unless result["ResultVariableName"].to_s.empty?
      args << "result_entity: #{ruby(result.dig("VariableType", "Entity"))}" if result.dig("VariableType", "Entity")
      args << "timeout: #{ruby(action["TimeOutExpression"])}" if action["UseRequestTimeOut"] == true
      args << "commit: :#{underscore(import_call["Commit"])}" unless import_call["Commit"].to_s.empty?
      args << "error_result: :#{underscore(action["ErrorResultHandlingType"])}"
      args << "error: :#{underscore(action["ErrorHandlingType"])}"
      "#{pad}call_rest #{args.join(', ')}"
    end

    def call_action_line(pad, method, target, output, mappings, use_return)
      args = [ruby(target)]
      if use_return == true && !output.to_s.empty?
        args << "as: :#{output}"
      elsif !output.to_s.empty?
        args << "result_name: #{symbol(output)}"
        args << "use_return: false"
      elsif use_return == true
        args << "use_return: true"
      end
      unless mappings.empty?
        args << "pass: #{pass_source(mappings)}"
      end
      "#{pad}#{method} #{args.join(', ')}"
    end

    def pass_source(mappings)
      duplicate = mappings.map { _1.first.to_s }.tally.values.any? { _1 > 1 }
      rendered = mappings.map do |parameter, value|
        key = ruby(parameter)
        val = ruby_val(value)
        duplicate ? "[#{key}, #{val}]" : "#{key} => #{val}"
      end
      duplicate ? "[#{rendered.join(', ')}]" : "{ #{rendered.join(', ')} }"
    end

    def code_action_parameter_value(value)
      value ||= {}
      type = value["$Type"].to_s
      return value["Argument"] if type.include?("$Basic")

      field, kind = case type
      when /EntityType/     then ["Entity", :entity]
      when /MicroflowJava/  then ["Microflow", :microflow]
      when /ImportMapping/  then ["ImportMapping", :import_mapping]
      when /ExportMapping/  then ["ExportMapping", :export_mapping]
      else
        [nil, :native]
      end
      { kind: kind, value: field ? value[field] : value }
    end

    def translated_text(text_doc)
      return "" unless text_doc

      translations = text_doc["Translations"] || text_doc["Items"]
      bson_items(translations).first&.fetch("Text", "") || ""
    end

    def translated_items(text_doc)
      return [] unless text_doc

      bson_items(text_doc["Translations"] || text_doc["Items"])
    end

    def member_specs(members_bson)
      bson_items(members_bson).filter_map do |m|
        attr = m["Attribute"].to_s
        association = m["Association"].to_s
        raw_value = m["Value"]
        val = raw_value.is_a?(Hash) ? raw_value["Value"].to_s : raw_value.to_s
        next if attr.empty? && association.empty?

        {
          attribute: attr, association: association, value: val,
          operation: m.fetch("Type", "Set")
        }
      end
    end

    def members_dsl(members)
      members.map { "#{symbol(_1[:attribute])} => #{ruby_val(_1[:value])}" }.join(", ")
    end

    def member_block(command, members, indent)
      pad = " " * (indent + 2)
      lines = ["#{command} do"]
      members.each do |member|
        if member[:association].to_s.empty?
          lines << "#{pad}set #{symbol(member[:attribute])}, to: #{ruby_val(member[:value])}"
        else
          operation = underscore(member[:operation])
          operation_a = operation == "set" ? "" : ", operation: :#{operation}"
          lines << "#{pad}set_association #{ruby(member[:association])}, " \
                   "to: #{ruby_val(member[:value])}#{operation_a}"
        end
      end
      lines << "#{' ' * indent}end"
      lines.join("\n")
    end

    def ruby_val(val)
      return "nil" if val.nil? || val.to_s.empty?
      return ruby(val) if val.is_a?(Hash) || val.is_a?(Array)
      s = val.to_s
      return s if s.match?(/\A-?\d+(?:\.\d+)?\z/) || %w[true false nil].include?(s)

      ruby(s)
    end

    def bson_items(bson)
      IO::BsonCodec.parse_array(bson)[:items]
    rescue StandardError
      []
    end

    def ruby(value)
      value.inspect
    end

    def architecture_module(name)
      @architecture&.fetch(:modules, [])&.find { _1[:name] == name }
    end

    def infer_public_artifacts(modules)
      modules.each_with_object({}) do |mod, public_artifacts|
        mod.pages.each do |page|
          source = page.data_source
          next unless source

          target_module, target_name = source.fetch(:name).to_s.split(".", 2)
          next if target_name.to_s.empty? || target_module == mod.name

          public_artifacts[[target_module, source.fetch(:kind).to_sym, target_name]] = true
        end
      end
    end

    def flow_metadata(module_name, kind, name, metadata)
      result = metadata ? metadata.dup : {}
      if @inferred_public_artifacts&.include?([module_name, kind, name])
        result[:public] = true
      end
      result.empty? ? nil : result
    end

    def reference(value)
      value.to_s.include?(".") ? ruby(value.to_s) : symbol(value)
    end

    def symbol(value)
      value.to_s.to_sym.inspect
    end

    def write(path, contents)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end
  end
end
