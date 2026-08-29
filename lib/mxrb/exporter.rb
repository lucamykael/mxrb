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
      DatabaseConnector$ExecuteDatabaseQueryAction
      Microflows$ImportXmlAction
      Microflows$DownloadFileAction
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
      export_presentation_documents(root, mod)
      export_asset_documents(root, mod)
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
        JSON.pretty_generate(
          "format_version" => project.format_version.to_s,
          "source_filename" => File.basename(@mpr_path),
          "units" => units
        )
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
        id = role.fetch(:id, '').to_s
        args << "id: #{ruby(id)}" unless id.empty?
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
          source = "#{source.rstrip}\n\n#{integration_document_declaration(document)}"
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
      append_to_aggregator(
        File.join(infrastructure, "infrastructure.rb"), paths,
        managed_types: documents.map { _1.fetch(:type) }
      )
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

    def export_presentation_documents(root, mod)
      documents = mod.presentation_documents
      return if documents.empty?

      presentation = File.join(root, 'presentation')
      used = {}
      paths = documents.map do |document|
        relative = unique_relative_path(
          document.fetch(:route), underscore(document.fetch(:name)), used
        )
        write(File.join(presentation, relative), mapping_document_source(document))
        relative
      end
      append_to_aggregator(
        File.join(presentation, 'presentation.rb'), paths,
        managed_types: documents.map { _1.fetch(:type) }
      )
    end

    def export_asset_documents(root, mod)
      documents = mod.asset_documents
      return if documents.empty?

      presentation = File.join(root, 'presentation')
      used = {}
      paths = documents.map do |document|
        relative = unique_relative_path(
          document.fetch(:route), underscore(document.fetch(:name)), used
        )
        write(File.join(presentation, relative), mapping_document_source(document))
        relative
      end
      append_to_aggregator(
        File.join(presentation, 'presentation.rb'), paths,
        managed_types: documents.map { _1.fetch(:type) }
      )
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

        #{integration_document_declaration(document)}
      RUBY
    end

    def integration_document_declaration(document)
      doc = document.fetch(:doc)
      case document.fetch(:type)
      when "JsonStructures$JsonStructure"
        return json_structure_declaration(document) if doc.key?("JsonSnippet")
      when "ImportMappings$ImportMapping"
        return mapping_declaration(document, :import) if doc.key?("JsonStructure")
      when "ExportMappings$ExportMapping"
        return mapping_declaration(document, :export) if doc.key?("JsonStructure")
      when "Rest$PublishedRestService"
        return published_rest_declaration(document) if semantic_rest_service?(doc)
      when "Enumerations$Enumeration"
        return enumeration_declaration(document) if semantic_enumeration?(doc)
      when "Constants$Constant"
        return constant_declaration(document) if doc["Type"].is_a?(Hash)
      when "DomainModels$ViewEntitySourceDocument"
        return oql_source_declaration(document) if doc.key?("Oql")
      when "DatabaseConnector$DatabaseConnection"
        return database_connection_declaration(document) if semantic_database_connection?(doc)
      when "JavaActions$JavaAction"
        return code_action_declaration(document, :java) if semantic_code_action?(doc)
      when "JavaScriptActions$JavaScriptAction"
        return code_action_declaration(document, :javascript) if semantic_code_action?(doc)
      when "Forms$Layout"
        return layout_document_declaration(document)
      when "Forms$PageTemplate"
        return page_template_document_declaration(document)
      when "Forms$BuildingBlock"
        return building_block_document_declaration(document)
      when "Forms$Snippet"
        return snippet_document_declaration(document)
      when "Images$ImageCollection"
        return image_collection_declaration(document)
      when "CustomIcons$CustomIconCollection"
        return custom_icon_collection_declaration(document)
      end
      native_document_declaration(document)
    end

    def image_collection_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:image_collection, document, {
        images: bson_items(doc['Images']).map do |image|
          {
            id: document_id(image), name: image.fetch('Name'),
            format: image.fetch('ImageFormat', ''),
            data: code_action_binary_spec(image.fetch('Image'))
          }
        end,
        documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
        export_level: doc.fetch('ExportLevel', 'Hidden'),
        images_marker: bson_marker(doc['Images'], 2)
      })
    end

    def custom_icon_collection_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:custom_icon_collection, document, {
        collection_class: doc.fetch('CollectionClass', ''), prefix: doc.fetch('Prefix', ''),
        font: code_action_binary_spec(doc.fetch('FontData')),
        icons: bson_items(doc['Icons']).map do |icon|
          {
            id: document_id(icon), name: icon.fetch('Name'),
            character_code: icon.fetch('CharacterCode', 0),
            tags: bson_items(icon['Tags']), tags_marker: bson_marker(icon['Tags'], 2)
          }
        end,
        documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
        export_level: doc.fetch('ExportLevel', 'Hidden'),
        icons_marker: bson_marker(doc['Icons'], 2)
      })
    end

    def layout_document_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:layout_document, document, {
        appearance: presentation_value_spec(doc['Appearance']),
        canvas_height: doc.fetch('CanvasHeight', 0), canvas_width: doc.fetch('CanvasWidth', 0),
        content: presentation_value_spec(doc['Content']),
        documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
        export_level: doc.fetch('ExportLevel', 'Hidden')
      })
    end

    def page_template_document_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:page_template_document, document, {
        appearance: presentation_value_spec(doc['Appearance']),
        canvas_height: doc.fetch('CanvasHeight', 0), canvas_width: doc.fetch('CanvasWidth', 0),
        display_name: doc.fetch('DisplayName', ''), documentation: doc.fetch('Documentation', ''),
        documentation_url: doc.fetch('DocumentationUrl', ''), excluded: doc['Excluded'] == true,
        export_level: doc.fetch('ExportLevel', 'Hidden'),
        image: presentation_value_spec(doc['ImageData']),
        layout_call: presentation_value_spec(doc['LayoutCall']),
        template_category: doc.fetch('TemplateCategory', ''),
        template_category_weight: doc.fetch('TemplateCategoryWeight', 0),
        template_type: presentation_value_spec(doc['TemplateType'])
      })
    end

    def building_block_document_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:building_block_document, document, {
        canvas_height: doc.fetch('CanvasHeight', 0), canvas_width: doc.fetch('CanvasWidth', 0),
        display_name: doc.fetch('DisplayName', ''), documentation: doc.fetch('Documentation', ''),
        documentation_url: doc.fetch('DocumentationUrl', ''), excluded: doc['Excluded'] == true,
        export_level: doc.fetch('ExportLevel', 'Hidden'),
        image: presentation_value_spec(doc['ImageData']), platform: doc.fetch('Platform', ''),
        template_category: doc.fetch('TemplateCategory', ''),
        template_category_weight: doc.fetch('TemplateCategoryWeight', 0),
        widgets: presentation_value_spec(doc['Widgets'])
      })
    end

    def snippet_document_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:snippet_document, document, {
        canvas_height: doc.fetch('CanvasHeight', 0), canvas_width: doc.fetch('CanvasWidth', 0),
        documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
        export_level: doc.fetch('ExportLevel', 'Hidden'),
        parameters: presentation_value_spec(doc['Parameters']),
        snippet_type: doc.fetch('Type', ''), variables: presentation_value_spec(doc['Variables']),
        widgets: presentation_value_spec(doc['Widgets'])
      })
    end

    def presentation_value_spec(value)
      case value
      when BSON::Binary
        { binary: Base64.strict_encode64(value.data), subtype: value.type.to_sym }
      when Array
        presentation_array_spec(value)
      when Hash
        presentation_hash_spec(value)
      else
        value
      end
    end

    def presentation_array_spec(value)
      return value.map { presentation_value_spec(_1) } unless value.first.is_a?(Integer)

      parsed = IO::BsonCodec.parse_array(value)
      {
        collection: parsed.fetch(:items).map { presentation_value_spec(_1) },
        marker: parsed.fetch(:marker)
      }
    end

    def presentation_hash_spec(value)
      if value['$Type']
        fields = value.reject { |key, _| %w[$ID $Type].include?(key) }
                      .transform_values { presentation_value_spec(_1) }
        return { node_type: value.fetch('$Type'), id: document_id(value), fields: }
      end

      { map: value.transform_values { presentation_value_spec(_1) } }
    end

    def code_action_declaration(document, language)
      doc = document.fetch(:doc)
      options = {
        parameters: bson_items(doc['Parameters']).map { code_action_parameter_spec(_1) },
        return_type: code_action_type_spec(doc.fetch('JavaReturnType')),
        type_parameters: bson_items(doc['TypeParameters']).map { code_action_type_parameter_spec(_1) },
        action_default_return_name: doc.fetch('ActionDefaultReturnName', ''),
        documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
        export_level: doc.fetch('ExportLevel', 'Hidden'),
        microflow_info: code_action_info_spec(doc['MicroflowActionInfo']),
        parameters_marker: bson_marker(doc['Parameters'], 2),
        type_parameters_marker: bson_marker(doc['TypeParameters'], 2)
      }
      options[:platform] = doc.fetch('Platform', '') if language == :javascript
      semantic_call_source("#{language}_action", document, options)
    end

    def code_action_parameter_spec(parameter)
      {
        id: document_id(parameter), name: parameter.fetch('Name'),
        category: parameter.fetch('Category', ''),
        description: parameter.fetch('Description', ''),
        required: parameter['IsRequired'] == true,
        type: code_action_parameter_type_spec(parameter.fetch('ParameterType'))
      }
    end

    def code_action_parameter_type_spec(parameter_type)
      kind = parameter_type.fetch('$Type')
      common = { id: document_id(parameter_type) }
      case kind
      when 'CodeActions$BasicParameterType'
        common.merge(kind: :basic, type: code_action_type_spec(parameter_type.fetch('Type')))
      when 'CodeActions$StringTemplateParameterType'
        common.merge(kind: :string_template, grammar: parameter_type.fetch('Grammar', ''))
      when 'CodeActions$EntityTypeParameterType'
        common.merge(
          kind: :entity_type_parameter,
          pointer: document_id_value(parameter_type['TypeParameterPointer'])
        )
      when 'JavaActions$MicroflowJavaActionParameterType'
        common.merge(kind: :microflow)
      else
        raise KeyError, "unsupported code action parameter type #{kind}"
      end
    end

    def code_action_type_spec(type)
      kind = type.fetch('$Type')
      common = { id: document_id(type) }
      primitive = {
        'CodeActions$BooleanType' => :boolean,
        'CodeActions$DateTimeType' => :datetime,
        'CodeActions$DecimalType' => :decimal,
        'CodeActions$IntegerType' => :integer,
        'CodeActions$StringType' => :string,
        'CodeActions$VoidType' => :void
      }[kind]
      return common.merge(kind: primitive) if primitive

      case kind
      when 'CodeActions$ConcreteEntityType'
        common.merge(kind: :concrete_entity, entity: type.fetch('Entity', ''))
      when 'CodeActions$EnumerationType'
        common.merge(kind: :enumeration, enumeration: type.fetch('Enumeration', ''))
      when 'CodeActions$ParameterizedEntityType'
        common.merge(
          kind: :parameterized_entity,
          pointer: document_id_value(type['TypeParameterPointer'])
        )
      when 'CodeActions$ListType'
        common.merge(kind: :list, parameter: code_action_type_spec(type.fetch('Parameter')))
      else
        raise KeyError, "unsupported code action type #{kind}"
      end
    end

    def code_action_type_parameter_spec(parameter)
      { id: document_id(parameter), name: parameter.fetch('Name') }
    end

    def code_action_info_spec(info)
      return nil unless info.is_a?(Hash)

      spec = {
        id: document_id(info), caption: info.fetch('Caption', ''),
        category: info.fetch('Category', '')
      }
      {
        'IconData' => :icon, 'IconDataDark' => :icon_dark,
        'ImageData' => :image, 'ImageDataDark' => :image_dark
      }.each do |field, key|
        spec[key] = code_action_binary_spec(info[field]) if info.key?(field)
      end
      spec
    end

    def code_action_binary_spec(value)
      return { data: '', subtype: :generic } if value.nil?
      raise KeyError, "unsupported code action binary #{value.class}" unless value.is_a?(BSON::Binary)

      { data: Base64.strict_encode64(value.data), subtype: value.type.to_sym }
    end

    def document_id_value(value)
      IO::BsonCodec.extract_id(value).to_s
    end

    def semantic_code_action?(doc)
      code_action_type_spec(doc.fetch('JavaReturnType'))
      bson_items(doc['Parameters']).each do |parameter|
        code_action_parameter_type_spec(parameter.fetch('ParameterType'))
      end
      bson_items(doc['TypeParameters']).each { code_action_type_parameter_spec(_1) }
      code_action_info_spec(doc['MicroflowActionInfo'])
      true
    rescue KeyError, TypeError, NoMethodError
      false
    end

    def enumeration_declaration(document)
      doc = document.fetch(:doc)
      options = {
        id: document_id(doc), unit_id: document.fetch(:id),
        documentation: doc.fetch("Documentation", ""), excluded: doc["Excluded"] == true,
        export_level: doc.fetch("ExportLevel", "Hidden"), remote_source: doc["RemoteSource"],
        values_marker: bson_marker(doc["Values"], 3)
      }
      lines = domain_call_lines(:enumeration, document.fetch(:name), options)
      lines[-1] = "#{lines[-1]} do"
      bson_items(doc["Values"]).each do |value|
        caption = value.fetch("Caption")
        translations = bson_items(caption["Items"])
        value_options = {
          id: document_id(value), caption_id: document_id(caption),
          captions: translations.to_h { [_1.fetch("LanguageCode"), _1.fetch("Text", "")] },
          caption_ids: translations.to_h { [_1.fetch("LanguageCode"), document_id(_1)] },
          image: value.fetch("Image", ""), remote_value: value["RemoteValue"],
          translations_marker: bson_marker(caption["Items"], 3)
        }
        value_options[:export_level] = value["ExportLevel"] if value.key?("ExportLevel")
        lines.concat(domain_call_lines(:value, value.fetch("Name"), value_options, indent: 2))
      end
      lines << "end"
      lines.join("\n")
    end

    def constant_declaration(document)
      doc = document.fetch(:doc)
      domain_call_lines(:constant, document.fetch(:name), {
        type: data_type_spec(doc.fetch("Type")), value: doc.fetch("DefaultValue", ""),
        id: document_id(doc), type_id: document_id(doc.fetch("Type")),
        unit_id: document.fetch(:id), documentation: doc.fetch("Documentation", ""),
        excluded: doc["Excluded"] == true, export_level: doc.fetch("ExportLevel", "Hidden"),
        exposed_to_client: doc["ExposedToClient"] == true
      }).join("\n")
    end

    def oql_source_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:oql_source_document, document, {
        query: doc.fetch("Oql", ""), documentation: doc.fetch("Documentation", ""),
        excluded: doc["Excluded"] == true, export_level: doc.fetch("ExportLevel", "Hidden")
      })
    end

    def database_connection_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:database_connection, document, {
        database_type: doc.fetch("DatabaseType", ""),
        connection_string: doc.fetch("ConnectionString", ""),
        username: doc.fetch("UserName", ""), password: doc.fetch("Password", ""),
        connection: database_connection_parts_spec(doc.fetch("ConnectionInput")),
        properties: bson_items(doc["AdditionalProperties"]).map { database_property_spec(_1) },
        properties_marker: bson_marker(doc["AdditionalProperties"], 2),
        queries: bson_items(doc["Queries"]).map { database_query_spec(_1) },
        queries_marker: bson_marker(doc["Queries"], 3),
        documentation: doc.fetch("Documentation", ""), excluded: doc["Excluded"] == true,
        export_level: doc.fetch("ExportLevel", "Hidden")
      })
    end

    def database_connection_parts_spec(parts)
      {
        id: document_id(parts), host: parts.fetch("Host", ""),
        port: parts.fetch("Port", 0), database: parts.fetch("DatabaseName", "")
      }
    end

    def database_property_spec(property)
      value = property.fetch("Value")
      {
        id: document_id(property), key: property.fetch("Key"),
        value_id: document_id(value), value: value.fetch("Value", "")
      }
    end

    def database_query_spec(query)
      {
        id: document_id(query), name: query.fetch("Name"),
        kind: { 1 => :select, 2 => :execute }.fetch(query.fetch("QueryType"), query.fetch("QueryType")),
        query: query.fetch("Query", ""),
        parameters: bson_items(query["Parameters"]).map { database_parameter_spec(_1) },
        parameters_marker: bson_marker(query["Parameters"], 2),
        tables: bson_items(query["TableMappings"]).map { database_table_spec(_1) },
        tables_marker: bson_marker(query["TableMappings"], 2)
      }
    end

    def database_parameter_spec(parameter)
      {
        id: document_id(parameter), name: parameter.fetch("ParameterName"),
        database_name: parameter.fetch("DatabaseParameterName", ""),
        type: data_type_spec(parameter["DataType"]), type_id: document_id(parameter["DataType"]),
        default: parameter.fetch("DefaultValue", ""),
        empty_as_null: parameter["EmptyValueBecomesNull"] == true,
        mode: underscore(parameter.fetch("Mode", "Unknown")).to_sym,
        sql_type: database_sql_type_spec(parameter.fetch("SqlDataType")),
        table_mapping: parameter["TableMapping"]
      }
    end

    def database_table_spec(table)
      {
        id: document_id(table), entity: table.fetch("Entity", ""),
        table: table.fetch("TableName", ""),
        columns: bson_items(table["Columns"]).map { database_column_spec(_1) },
        columns_marker: bson_marker(table["Columns"], 2)
      }
    end

    def database_column_spec(column)
      {
        id: document_id(column), attribute: column.fetch("Attribute", ""),
        column: column.fetch("ColumnName", ""),
        sql_type: database_sql_type_spec(column.fetch("SqlDataType"))
      }
    end

    def database_sql_type_spec(sql_type)
      limited = sql_type["$Type"] == "DatabaseConnector$LimitedLengthSqlDataType"
      spec = {
        id: document_id(sql_type), kind: limited ? :limited : :simple,
        name: sql_type.fetch("DataTypeName", "")
      }
      spec[:length] = sql_type.fetch("Length") if limited
      spec
    end

    def semantic_database_connection?(doc)
      return false unless doc["ConnectionInput"].is_a?(Hash)
      return false unless doc["ConnectionInput"]["$Type"] == "DatabaseConnector$ConnectionParts"

      properties = bson_items(doc["AdditionalProperties"])
      queries = bson_items(doc["Queries"])
      properties.all? do |property|
        property["$Type"] == "DatabaseConnector$AdditionalProperty" &&
          property.dig("Value", "$Type") == "DatabaseConnector$ValueAsString"
      end && queries.all? { database_query_semantic?(_1) }
    end

    def database_query_semantic?(query)
      return false unless query["$Type"] == "DatabaseConnector$DatabaseQuery"

      parameters = bson_items(query["Parameters"])
      tables = bson_items(query["TableMappings"])
      parameters.all? do |parameter|
        parameter["$Type"] == "DatabaseConnector$QueryParameter" &&
          semantic_sql_type?(parameter["SqlDataType"])
      end && tables.all? do |table|
        table["$Type"] == "DatabaseConnector$TableMapping" &&
          bson_items(table["Columns"]).all? do |column|
            column["$Type"] == "DatabaseConnector$ColumnMapping" &&
              semantic_sql_type?(column["SqlDataType"])
          end
      end
    end

    def semantic_sql_type?(sql_type)
      %w[
        DatabaseConnector$SimpleSqlDataType DatabaseConnector$LimitedLengthSqlDataType
      ].include?(sql_type.to_h["$Type"])
    end

    def domain_call_lines(method, name, options, indent: 0)
      pad = " " * indent
      entries = options.to_a
      lines = ["#{pad}#{method} #{symbol(name)},"]
      entries.each_with_index do |(key, value), index|
        comma = index == entries.size - 1 ? "" : ","
        lines << "#{pad}            #{key}: #{native_ruby(value, indent + 12)}#{comma}"
      end
      lines
    end

    def semantic_enumeration?(doc)
      return false unless doc.key?("Values")

      bson_items(doc["Values"]).all? do |value|
        caption = value["Caption"]
        caption.is_a?(Hash) && bson_items(caption["Items"]).all? do |translation|
          translation.is_a?(Hash) && translation["$Type"] == "Texts$Translation" &&
            translation.key?("LanguageCode")
        end
      end
    end

    def bson_marker(bson, fallback)
      IO::BsonCodec.parse_array(bson)[:marker]
    rescue StandardError
      fallback
    end

    def json_structure_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:json_structure, document, {
        snippet: doc.fetch("JsonSnippet", ""),
        documentation: doc.fetch("Documentation", ""),
        excluded: doc["Excluded"] == true,
        export_level: doc.fetch("ExportLevel", "Hidden"),
        elements: bson_items(doc["Elements"]).map { json_element_spec(_1) }
      })
    end

    def mapping_declaration(document, direction)
      doc = document.fetch(:doc)
      options = {
        json_structure: doc.fetch("JsonStructure", ""),
        documentation: doc.fetch("Documentation", ""),
        excluded: doc["Excluded"] == true,
        export_level: doc.fetch("ExportLevel", "Hidden"),
        elements: bson_items(doc["Elements"]).map { mapping_element_spec(_1) },
        message_definition: doc.fetch("MessageDefinition", ""),
        message_definition2: doc.fetch("MessageDefinition2", ""),
        operation_name: doc.fetch("OperationName", ""),
        public_name: doc.fetch("PublicName", ""),
        service_name: doc.fetch("ServiceName", ""),
        wsdl_file: doc.fetch("WsdlFile", ""),
        xml_schema: doc.fetch("XmlSchema", ""),
        xsd_root_element_name: doc.fetch("XsdRootElementName", "")
      }
      if direction == :import
        options[:parameter_type] = data_type_spec(doc["ParameterType"])
        options[:parameter_type_id] = document_id(doc["ParameterType"])
        options[:use_subtransactions] = doc["UseSubtransactionsForMicroflows"] == true
      else
        options[:null_value] = doc.fetch("NullValueOption", "LeaveOutElement")
        options[:header_parameter] = doc["IsHeaderParameter"] == true
        options[:parameter_name] = doc.fetch("ParameterName", "")
      end
      semantic_call_source("#{direction}_mapping", document, options)
    end

    def published_rest_declaration(document)
      doc = document.fetch(:doc)
      semantic_call_source(:published_rest_service, document, {
        path: doc.fetch("Path", ""),
        version: doc.fetch("Version", ""),
        service_name: doc.fetch("ServiceName", document.fetch(:name)),
        allowed_roles: bson_items(doc["AllowedRoles"]),
        authentication_types: bson_items(doc["AuthenticationTypes"]).map { underscore(_1) },
        authentication_microflow: doc.fetch("AuthenticationMicroflow", ""),
        documentation: doc.fetch("Documentation", ""),
        public_documentation: doc.fetch("PublicDocumentation", ""),
        excluded: doc["Excluded"] == true,
        export_level: doc.fetch("ExportLevel", "Hidden"),
        enable_cors: doc["EnableCors"],
        requires_authentication: doc["RequiresAuthentication"],
        resources: bson_items(doc["Resources"]).map { rest_resource_spec(_1) }
      }.reject { |key, _| %i[enable_cors requires_authentication].include?(key) && !doc.key?(camelize_key(key)) })
    end

    def semantic_call_source(method, document, options)
      identity = {
        unit_id: document.fetch(:id),
        container_id: document.fetch(:container_id)
      }
      values = identity.merge(options)
      lines = ["#{method} #{symbol(document.fetch(:name))},"]
      values.each_with_index do |(key, value), index|
        rendered = native_ruby(value, 16)
        comma = index == values.size - 1 ? "" : ","
        lines << "                #{key}: #{rendered}#{comma}"
      end
      lines.join("\n")
    end

    def json_element_spec(element)
      {
        id: document_id(element), kind: underscore(element["ElementType"]).to_sym,
        name: element.fetch("ExposedName", ""), item_name: element.fetch("ExposedItemName", ""),
        path: element.fetch("Path", ""), primitive: underscore(element["PrimitiveType"]).to_sym,
        original: element.fetch("OriginalValue", ""), min_occurs: element.fetch("MinOccurs", 0),
        max_occurs: element.fetch("MaxOccurs", 1), nillable: element["Nillable"] == true,
        max_length: element.fetch("MaxLength", -1), total_digits: element.fetch("TotalDigits", -1),
        fraction_digits: element.fetch("FractionDigits", -1),
        default_type: element["IsDefaultType"] == true,
        error: element.fetch("ErrorMessage", ""), warning: element.fetch("WarningMessage", ""),
        children: bson_items(element["Children"]).map { json_element_spec(_1) }
      }
    end

    def mapping_element_spec(element)
      object = element["$Type"].to_s.include?("ObjectMappingElement")
      common = {
        id: document_id(element), kind: object ? :object : :value,
        name: element.fetch("ExposedName", ""),
        documentation: element.fetch("Documentation", ""),
        json_path: element.fetch("JsonPath", ""), xml_path: element.fetch("XmlPath", ""),
        min_occurs: element.fetch("MinOccurs", 0), max_occurs: element.fetch("MaxOccurs", 1),
        nillable: element["Nillable"] == true,
        children: bson_items(element["Children"]).map { mapping_element_spec(_1) }
      }
      if object
        return common.merge(
          association: element.fetch("Association", ""), entity: element.fetch("Entity", ""),
          default_type: element["IsDefaultType"] == true,
          object_handling: underscore(element.fetch("ObjectHandling", "Create")).to_sym,
          backup_handling: underscore(element.fetch("ObjectHandlingBackup", "Create")).to_sym,
          allow_override: element["ObjectHandlingBackupAllowOverride"] == true
        )
      end

      common.merge(
        attribute: element.fetch("Attribute", ""), converter: element.fetch("Converter", ""),
        type: data_type_spec(element["Type"]), type_id: document_id(element["Type"]),
        primitive: underscore(element.fetch("XmlPrimitiveType", "Unknown")).to_sym,
        fraction_digits: element.fetch("FractionDigits", -1),
        max_length: element.fetch("MaxLength", -1), total_digits: element.fetch("TotalDigits", -1),
        content: element["IsContent"] == true, key: element["IsKey"] == true,
        xml_attribute: element["IsXmlAttribute"] == true,
        original: element.fetch("OriginalValue", "")
      )
    end

    def rest_resource_spec(resource)
      {
        id: document_id(resource), name: resource.fetch("Name"),
        documentation: resource.fetch("Documentation", ""),
        operations: bson_items(resource["Operations"]).map { rest_operation_spec(_1) }
      }
    end

    def rest_operation_spec(operation)
      {
        id: document_id(operation), method: underscore(operation.fetch("HttpMethod", "Get")).to_sym,
        path: operation.fetch("Path", ""), microflow: operation.fetch("Microflow", ""),
        import_mapping: operation.fetch("ImportMapping", ""),
        export_mapping: operation.fetch("ExportMapping", ""),
        commit: underscore(operation.fetch("Commit", "No")).to_sym,
        object_handling: underscore(operation.fetch("ObjectHandlingBackup", "Create")).to_sym,
        deprecated: operation["Deprecated"] == true,
        documentation: operation.fetch("Documentation", ""),
        summary: operation.fetch("Summary", "")
      }
    end

    def semantic_rest_service?(doc)
      return false unless doc.key?("Resources") && doc.key?("Path")
      return false unless bson_items(doc["Parameters"]).empty?

      bson_items(doc["Resources"]).all? do |resource|
        bson_items(resource["Operations"]).all? do |operation|
          bson_items(operation["Parameters"]).empty?
        end
      end
    end

    def data_type_spec(type_doc)
      type = type_doc.to_h.fetch("$Type", "DataTypes$UnknownType")
      underscore(type.delete_prefix("DataTypes$").delete_suffix("Type")).to_sym
    end

    def document_id(document)
      IO::BsonCodec.extract_id(document.to_h["$ID"]).to_s
    end

    def camelize_key(key)
      key.to_s.split("_").map!(&:capitalize).join
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

    def append_to_aggregator(path, relative_paths, managed_types: [])
      existing = File.exist?(path) ? File.read(path).lines : []
      management = Array(managed_types).uniq.sort.map do |type|
        "manage_native_documents #{ruby(type)}\n"
      end
      additions = relative_paths.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(", ")
        "evaluate File.join(__dir__, #{segments})\n"
      end
      write(path, (existing + management + additions).uniq.join)
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

        require "mxrb" unless defined?(Mxrb::Dsl)

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
        args = [symbol(role.fetch("Name"))]
        id = IO::BsonCodec.extract_id(role["$ID"])
        guid = IO::BsonCodec.extract_id(role["GUID"])
        manageable = IO::BsonCodec.parse_array(role["ManageableRoles"]).fetch(:items)
        args << "id: #{ruby(id)}" unless id.to_s.empty?
        args << "guid: #{ruby(guid)}" unless guid.to_s.empty?
        args << "description: #{ruby(role['Description'].to_s)}" unless role['Description'].to_s.empty?
        args << "check_security: false" unless role["CheckSecurity"] == true
        args << "manageable_roles: #{ruby(manageable)}" unless manageable.empty?
        args << "module_roles: #{ruby(module_roles)}" unless module_roles.empty?
        args << "admin: true" if role["ManageAllRoles"] == true
        args << "manage_users_without_roles: true" if role["ManageUsersWithoutRoles"] == true
        "  user_role #{args.join(', ')}"
      end
      options = []
      security_id = IO::BsonCodec.extract_id(doc["$ID"])
      options << "  mendix_id #{ruby(security_id)}" unless security_id.to_s.empty?
      options << "  admin_user_role #{ruby(doc["AdminUserRole"])}" unless doc["AdminUserRole"].to_s.empty?
      options << "  demo_users #{doc["EnableDemoUsers"] == true}"
      demo_users = doc["DemoUsers"] || IO::BsonCodec.build_array([])
      IO::BsonCodec.parse_array(demo_users).fetch(:items).each do |user|
        assigned_roles = IO::BsonCodec.parse_array(user["UserRoles"]).fetch(:items)
        options << "  demo_user #{ruby(user["UserName"])}, id: #{ruby(IO::BsonCodec.extract_id(user['$ID']))}, " \
                   "entity: #{ruby(user["Entity"])}, " \
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
        options << "  password_policy(id: #{ruby(IO::BsonCodec.extract_id(password['$ID']))}, " \
                   "**#{ruby(policy)})"
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
      if generalization
        generalization_id = IO::BsonCodec.extract_id(entity.generalization&.fetch('$ID', nil))
        flags << "  generalizes #{ruby(generalization)}, id: #{ruby(generalization_id)}"
      end
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
        index_id = IO::BsonCodec.extract_id(index['$ID'])
        guid = IO::BsonCodec.extract_id(index['GUID'])
        options << "id: #{ruby(index_id)}" if index_id
        options << "guid: #{ruby(guid)}" if guid
        options << "ascending: #{ruby(directions)}" unless directions.all?
        include_offline = index['includeInOffline'] || index['IncludeInOffline']
        options << 'include_offline: true' if include_offline
        member_declarations = indexed.map do |member|
          {
            id: IO::BsonCodec.extract_id(member['$ID']),
            name: (member['attribute'] || member['Attribute']).to_s.split('.').last,
            ascending: member.fetch('ascending', member.fetch('Ascending', true)),
            type: (member['type'] || member['Type'] || 'Normal').to_sym
          }
        end
        options << "members: #{native_ruby(member_declarations)}"
        flags << "  index #{members.map { symbol(_1) }.join(', ')}#{options.empty? ? '' : ", #{options.join(', ')}"}"
      end
      lifecycle = if entity.respond_to?(:lifecycle)
                    entity.lifecycle
                  else
                    metadata&.fetch(:lifecycle, [])
                  end
      lifecycle.to_a.each do |callback|
        flags << "  #{callback.fetch(:event)} microflow: #{ruby(callback.fetch(:handler))}, " \
                 "id: #{ruby(callback.fetch(:id, nil))}, " \
                 "pass_event_object: #{callback.fetch(:pass_event_object, true)}, " \
                 "raise_error_on_false: #{callback.fetch(:raise_error_on_false, false)}"
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
      opts << "id: #{ruby(rule.fetch(:id))}" unless rule.fetch(:id, '').to_s.empty?
      documentation = rule.fetch(:documentation, '').to_s
      opts << "documentation: #{ruby(documentation)}" unless documentation.empty?
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
      xpath_caption = rule.fetch(:xpath_caption, nil)
      opts << "xpath_caption: #{ruby(xpath_caption)}" unless xpath_caption.nil?
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
        type_source = if type.is_a?(Hash)
                        "flow_type(#{native_ruby(flow_type_spec(type))})"
                      else
                        symbol(type)
                      end
        "  parameter #{symbol(name)}, type: #{type_source}" if name && type
      end
      body = parameters
      return_type = if flow.respond_to?(:return_type_document) && flow.return_type_document
                      "return_type(flow_type(#{native_ruby(flow_type_spec(flow.return_type_document))}))"
                    elsif flow.return_type.is_a?(String)
                      "return_type #{symbol(flow.return_type)}"
                    end
      body << "  #{return_type}" if return_type
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

    def flow_type_spec(type)
      name = type.fetch('$Type').to_s.delete_prefix('DataTypes$').delete_suffix('Type')
      spec = { id: document_id(type), kind: underscore(name).to_sym }
      spec[:entity] = type.fetch('Entity', '') if %w[Object List].include?(name)
      spec
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
      if deep
        body << "  form_structure(#{native_ruby(presentation_value_spec(deep), 2)})"
      end
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
        body.unshift(
          "  form_structure(#{native_ruby(presentation_value_spec(deep), 2)})"
        )
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

      if type == :page_title
        return ["#{pad}page_title #{symbol(widget.fetch(:name))}"]
      end

      if type == :static_image
        args = [symbol(widget.fetch(:name)), "image: #{ruby(options.fetch(:image))}"]
        args << "alternative_text: #{ruby(options[:alternative_text])}" unless options[:alternative_text].to_s.empty?
        args << "width: #{options[:width]}" if options[:width].to_i.positive?
        args << "height: #{options[:height]}" if options[:height].to_i.positive?
        args << "width_unit: #{symbol(options[:width_unit])}" if options[:width_unit]
        args << "height_unit: #{symbol(options[:height_unit])}" if options[:height_unit]
        args << "responsive: false" if options[:responsive] == false
        return ["#{pad}static_image #{args.join(', ')}"]
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
      args << "horizontal: true" if type == :radio_button_group && options[:horizontal]
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
            Microflows$MicroflowParameterValue
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
        request_supported = case request["$Type"]
                            when "Microflows$MappingRequestHandling"
                              !request["MappingId"].to_s.empty?
                            when "Microflows$CustomRequestHandling"
                              template = request["Template"] || {}
                              bson_items(template["Parameters"]).all? { _1["Expression"] }
                            else
                              false
                            end
        result = action["ResultHandling"] || {}
        result_mapping = result["ImportMappingCall"] || {}
        result_supported = case action["ResultHandlingType"]
                           when "Mapping"
                             !result_mapping["ReturnValueMapping"].to_s.empty? &&
                               result_mapping.dig("Range", "$Type") ==
                                 "Microflows$ConstantRange"
                           when "HttpResponse"
                             result["Bind"] == true &&
                               result["ImportMappingCall"].nil? &&
                               !result["ResultVariableName"].to_s.empty? &&
                               !result.dig("VariableType", "Entity").to_s.empty?
                           else
                             false
                           end
        !http["HttpMethod"].to_s.empty? &&
          bson_items(http["HttpHeaderEntries"]).all? { _1["Key"] && _1["Value"] } &&
          bson_items(http.dig("CustomLocationTemplate", "Parameters")).all? {
            _1["Expression"]
          } &&
          request_supported && result_supported
      when "DatabaseConnector$ExecuteDatabaseQueryAction"
        (!action["Query"].to_s.empty? || !action["DynamicQuery"].to_s.empty?) &&
          bson_items(action["ParameterMappings"]).all? { |mapping|
            mapping["ParameterName"] && mapping["Value"]
          } &&
          bson_items(action["ConnectionParameterMappings"]).all? { |mapping|
            mapping["ParameterName"] && mapping["Value"]
          }
      when "Microflows$ImportXmlAction"
        result = action["ResultHandling"] || {}
        mapping = result["ImportMappingCall"] || {}
        !action["XmlDocumentVariableName"].to_s.empty? &&
          result["Bind"] == true && !result["ResultVariableName"].to_s.empty? &&
          !result.dig("VariableType", "Entity").to_s.empty? &&
          !mapping["ReturnValueMapping"].to_s.empty? &&
          mapping.dig("Range", "$Type") == "Microflows$ConstantRange"
      when "Microflows$DownloadFileAction"
        !action["FileDocumentVariableName"].to_s.empty?
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
      when "DatabaseConnector$ExecuteDatabaseQueryAction"
        database_query_line(pad, action)
      when "Microflows$ImportXmlAction"
        import_xml_line(pad, action)
      when "Microflows$DownloadFileAction"
        args = [":#{action['FileDocumentVariableName']}"]
        args << "show_in_browser: true" if action["ShowFileInBrowser"] == true
        error = underscore(action["ErrorHandlingType"])
        args << "error: :#{error}" unless error == "rollback"
        "#{pad}download_file #{args.join(', ')}"
      end
    end

    def database_query_line(pad, action)
      args = []
      query = action["Query"].to_s
      args << ruby(query.empty? ? nil : query)
      dynamic_query = action["DynamicQuery"].to_s
      args << "dynamic_query: #{ruby_val(dynamic_query)}" unless dynamic_query.empty?
      output = action["OutputVariableName"].to_s
      args << "as: :#{output}" unless output.empty?
      parameters = bson_items(action["ParameterMappings"]).map do |mapping|
        [mapping["ParameterName"], mapping["Value"]]
      end
      connection_parameters = bson_items(action["ConnectionParameterMappings"]).map do |mapping|
        [mapping["ParameterName"], mapping["Value"]]
      end
      args << "parameters: #{pass_source(parameters)}" unless parameters.empty?
      unless connection_parameters.empty?
        args << "connection_parameters: #{pass_source(connection_parameters)}"
      end
      error = underscore(action["ErrorHandlingType"])
      args << "error: :#{error}" unless error == "rollback"
      "#{pad}execute_database_query #{args.join(', ')}"
    end

    def import_xml_line(pad, action)
      result = action["ResultHandling"] || {}
      mapping = result["ImportMappingCall"] || {}
      range = mapping["Range"] || {}
      args = [":#{action['XmlDocumentVariableName']}"]
      args << "mapping: #{ruby(mapping['ReturnValueMapping'])}"
      args << "as: :#{result['ResultVariableName']}"
      args << "result_entity: #{ruby(result.dig('VariableType', 'Entity'))}"
      args << "validate: true" if action["IsValidationRequired"] == true
      content_type = underscore(mapping["ContentType"])
      args << "content_type: :#{content_type}" unless content_type == "xml"
      commit = underscore(mapping["Commit"])
      args << "commit: :#{commit}" unless commit == "yes_without_events"
      args << "force_single: true" if mapping["ForceSingleOccurrence"] == true
      args << "single: true" if range["SingleObject"] == true
      handling = underscore(mapping["ObjectHandlingBackup"])
      args << "object_handling: :#{handling}" unless handling == "create"
      parameter = mapping["ParameterVariableName"].to_s
      args << "parameter_variable: :#{parameter}" unless parameter.empty?
      error = underscore(action["ErrorHandlingType"])
      args << "error: :#{error}" unless error == "rollback"
      "#{pad}import_xml #{args.join(', ')}"
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
      if request["$Type"] == "Microflows$CustomRequestHandling"
        template = request["Template"] || {}
        args << "request_body: #{ruby(template['Text'].to_s)}"
        request_parameters = bson_items(template["Parameters"]).map { _1["Expression"] }
        unless request_parameters.empty?
          args << "request_parameters: #{ruby(request_parameters)}"
        end
      else
        args << "request_mapping: #{ruby(request["MappingId"])}" if request["MappingId"]
        args << "request_variable: :#{request["MappingVariableName"]}" if request["MappingVariableName"]
      end
      args << "result_mapping: #{ruby(import_call["ReturnValueMapping"])}" if import_call["ReturnValueMapping"]
      if action["ResultHandlingType"] == "HttpResponse"
        args << "result_handling: :http_response"
      end
      args << "as: :#{result["ResultVariableName"]}" unless result["ResultVariableName"].to_s.empty?
      args << "result_entity: #{ruby(result.dig("VariableType", "Entity"))}" if result.dig("VariableType", "Entity")
      args << "timeout: #{ruby(action["TimeOutExpression"])}" if action["UseRequestTimeOut"] == true
      args << "commit: :#{underscore(import_call["Commit"])}" unless import_call["Commit"].to_s.empty?
      content_type = underscore(import_call["ContentType"])
      args << "result_content_type: :#{content_type}" unless content_type.empty? || content_type == "json"
      args << "force_single: true" if import_call["ForceSingleOccurrence"] == true
      args << "single: true" if import_call.dig("Range", "SingleObject") == true
      object_handling = underscore(import_call["ObjectHandlingBackup"])
      unless object_handling.empty? || object_handling == "create"
        args << "object_handling: :#{object_handling}"
      end
      parameter = import_call["ParameterVariableName"].to_s
      args << "parameter_variable: :#{parameter}" unless parameter.empty?
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
      when /Microflow(?:Java)?/ then ["Microflow", :microflow]
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
