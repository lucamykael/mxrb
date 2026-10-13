# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'digest'
require_relative 'native_fragment_store'
require_relative 'forms/mpr_codec'
require_relative 'pluggable/schema_source_emitter'
require_relative 'settings/mpr_codec'
require_relative 'settings/source_emitter'
require_relative 'exporter/data_sources'
require_relative 'exporter/integration_declarations'
require_relative 'exporter/presentation_declarations'
require_relative 'exporter/code_action_declarations'
require_relative 'exporter/workflow_declarations'
require_relative 'exporter/domain_document_declarations'
require_relative 'exporter/rest_declarations'
require_relative 'exporter/project_sources'
require_relative 'exporter/model_sources'
require_relative 'exporter/page_sources'
require_relative 'exporter/flow_linearization'
require_relative 'exporter/flow_action_sources'

module Mxrb
  # Exports an MPR into an editable, layered Ruby source tree.
  class Exporter
    include DataSources
    include IntegrationDeclarations
    include PresentationDeclarations
    include CodeActionDeclarations
    include WorkflowDeclarations
    include DomainDocumentDeclarations
    include RestDeclarations
    include ProjectSources
    include ModelSources
    include PageSources
    include FlowLinearization
    include FlowActionSources

    MODES = %i[mendix ruby].freeze
    LAYERS = %w[domain application presentation infrastructure].freeze
    MODULE_PROGRESS_WEIGHT = 10
    MARKETPLACE_PROVENANCE = [
      '.mxrb/marketplace.lock.json',
      '.mxrb/marketplace',
      '.mxrb/marketplace-originals'
    ].freeze
    GLOBAL_EDITABLE_DOCUMENT_TYPES = %w[
      Settings$ProjectSettings Texts$SystemTextCollection
    ].freeze
    TYPED_FORMS_DOCUMENT_TYPES = %w[
      Forms$Layout Forms$PageTemplate Forms$BuildingBlock Forms$Snippet
    ].freeze
    RUBY_PROJECTED_DOCUMENT_TYPES = (
      Model::Module::EDITABLE_DOCUMENT_TYPES + GLOBAL_EDITABLE_DOCUMENT_TYPES + %w[
        DomainModels$DomainModel Forms$Page Menus$MenuDocument
        Microflows$Microflow Microflows$Nanoflow Navigation$NavigationDocument
        Projects$Folder Projects$ModuleGuidMapping Projects$ModuleImpl
        Projects$ModuleSettings Projects$Project Projects$ProjectConversion
        Security$ModuleSecurity Security$ProjectSecurity
      ]
    ).freeze

    def self.ruby_projected_document_type?(type)
      RUBY_PROJECTED_DOCUMENT_TYPES.include?(type.to_s)
    end

    attr_reader :mode

    def initialize(mpr_path, output_dir, mode: :mendix)
      @mpr_path = File.expand_path(mpr_path)
      @output_dir = File.expand_path(output_dir)
      @mode = mode.to_sym
      raise ArgumentError, 'export mode must be mendix or ruby' unless MODES.include?(@mode)
    end

    def export!(parallel: true)
      return export_ruby!(parallel:) if mode == :ruby

      Progress.with("Exporting #{File.basename(@mpr_path)}") do |progress|
        FileUtils.mkdir_p(@output_dir)
        @native_fragment_store = NativeFragmentStore.new(
          File.join(@output_dir, '.mxrb', 'native_fragments')
        )
        Mxrb.open(@mpr_path) do |project|
          @architecture = project.architecture_definition
          units = project.all_units
          modules = project.modules
          prepare_typed_forms(project, units, modules)
          @inferred_public_artifacts = infer_public_artifacts(modules)
          assets = project_asset_files
          progress.update(
            current: 0,
            total: 4 + assets.size + (units.size * 2) + (modules.size * MODULE_PROGRESS_WEIGHT),
            detail: 'preparing Ruby project'
          )
          export_app_structure
          export_pluggable_schemas
          progress.advance(detail: 'project structure')
          export_project_assets(assets, progress)
          export_native_units(project, units, progress)
          export_global_documents(project)
          ruby_sources = export_ruby_app_sources(project)
          export_security(project)
          progress.advance(detail: 'project security')
          export_architecture_contracts(project)
          progress.advance(detail: 'navigation and design system')
          export_semantic_metadata(modules)
          export_rest_metadata(modules)
          export_modules(modules, progress, parallel:)
          write_project(project, ruby_sources:)
          progress.advance(detail: 'project.rb')
        end
      end
      @output_dir
    end

    private

    def export_ruby!(parallel:)
      sidecar = File.join(@output_dir, '.mxrb', 'mendix')
      self.class.new(@mpr_path, sidecar, mode: :mendix).export!(parallel:)
      RubyApp::Exporter.new(@mpr_path, @output_dir, mendix_sidecar: sidecar).export!
    end

    def export_module(mod)
      root = File.join(@output_dir, 'modules', mod.name)
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
      write(File.join(root, 'module.rb'), module_source(mod))
    end

    def export_app_structure
      %w[
        app/security app/navigation app/navigation/responsive app/design_system
        app/settings app/texts
        theme resources themesource widgets javasource javascriptsource
      ].each { write(File.join(@output_dir, _1, '.keep'), '') }
    end

    def prepare_typed_forms(project, units, modules)
      @pluggable_catalog = Pluggable::Catalog.new
      @forms_codec = Forms::MprCodec.new(pluggable_catalog: @pluggable_catalog)
      @typed_forms_documents = {}
      @typed_pages = {}
      return unless project.mendix_version.to_s.split('.').first.to_i == 11

      units.each do |unit|
        register_embedded_widget_types(project.parse_bson(unit))
      end
      @typed_forms_documents = units.each_with_object({}) do |unit, typed|
        document = project.parse_bson(unit)
        next unless TYPED_FORMS_DOCUMENT_TYPES.include?(document['$Type'])

        typed[unit.fetch('UnitID')] = @forms_codec.decode(document)
      rescue Forms::MprCodecError, Pluggable::CodecError, KeyError, TypeError => e
        name = document&.fetch('Name', unit['UnitID'])
        raise SerializationError, "typed Forms export failed for #{name}: #{e.message}"
      end
      @typed_pages = modules.flat_map(&:pages).each_with_object({}) do |page, typed|
        typed[page.id] = @forms_codec.decode(page.raw_document)
      rescue Forms::MprCodecError, Pluggable::CodecError, KeyError, TypeError => e
        # Older MXRB releases generated transitional widgets with concise,
        # semantic fields outside their embedded schema. Their existing page
        # projection is typed and can canonicalize them without a raw fragment.
        next if semantic_page_baseline?(page.widgets)

        raise SerializationError, "typed Forms export failed for page #{page.name}: #{e.message}"
      end
    end

    def register_embedded_widget_types(value)
      case value
      when Hash
        if value['$Type'] == 'CustomWidgets$CustomWidget'
          type = value['Type']
          @forms_codec.register_pluggable_type(type) if type.is_a?(Hash)
        end
        value.each_value { register_embedded_widget_types(_1) }
      when Array
        value.each { register_embedded_widget_types(_1) unless _1.is_a?(Integer) }
      end
    end

    def export_pluggable_schemas
      source = Pluggable::SchemaSourceEmitter.new.emit(@pluggable_catalog.schema_definitions)
      write(File.join(@output_dir, '.mxrb', 'widget_types.rb'), source)
    end

    def project_asset_files
      source_root = File.dirname(@mpr_path)
      (Model::DesignSystem::ASSET_DIRECTORIES + MARKETPLACE_PROVENANCE).flat_map do |directory|
        root = File.join(source_root, directory)
        next [root] if File.file?(root) && !File.symlink?(root)
        next [] unless File.directory?(root) && !File.symlink?(root)

        Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH)
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
          'path' => relative,
          'size' => File.size(source),
          'sha256' => Digest::SHA256.file(source).hexdigest
        }
        progress.advance(detail: "asset #{relative}")
        result
      end
      write(
        File.join(@output_dir, '.mxrb', 'assets.json'),
        JSON.pretty_generate('version' => 1, 'files' => entries)
      )
    end

    def export_native_units(project, project_units, progress)
      units = project_units.filter_map do |unit|
        doc = project.parse_bson(unit)
        type = doc['$Type']
        next if type.to_s.empty? || type == 'Projects$Project'

        {
          'unit_id' => unit['UnitID'],
          'container_id' => unit['ContainerID'],
          'module' => module_name_for(project, unit),
          'containment' => unit['ContainmentName'],
          'name' => doc['Name'] || doc['name'] || '',
          'type' => type,
          'contents' => Base64.strict_encode64(IO::BsonCodec.serialize(doc))
        }
      ensure
        progress.advance(detail: 'native baseline')
      end
      write(
        File.join(@output_dir, '.mxrb', 'native_units.json'),
        JSON.pretty_generate(
          'format_version' => project.format_version.to_s,
          'source_filename' => File.basename(@mpr_path),
          'source_version' => project.mendix_version,
          'units' => units
        )
      )
      source = project_units.filter_map do |unit|
        doc = project.parse_bson(unit)
        next if doc['$Type'].to_s.empty? || doc['$Type'] == 'Projects$Project'
        next if editable_document_type?(doc['$Type'])

        native_unit_source(project, unit, doc)
      ensure
        progress.advance(detail: 'editable native units')
      end
      write(
        File.join(@output_dir, '.mxrb', 'native_units.rb'),
        "# frozen_string_literal: true\n\n#{source.join("\n")}"
      )
    end

    def export_semantic_metadata(modules)
      values = modules.to_h do |mod|
        typed_flows = [
          *Array(mod.rules).map { ['Microflows$Rule', _1] },
          *Array(mod.microflows).map { ['Microflows$Microflow', _1] },
          *Array(mod.nanoflows).map { ['Microflows$Nanoflow', _1] }
        ]
        flow_entries = typed_flows.map do |native_type, flow|
          parameters = Array(flow.parameters).filter_map do |parameter|
            next unless parameter.is_a?(Hash)

            type = parameter['VariableType'] || parameter['Type'] || parameter['type']
            {
              'name' => parameter['Name'] || parameter['name'],
              'id' => document_id(parameter),
              'relative_middle_point' => parameter['RelativeMiddlePoint'],
              'size' => parameter['Size'],
              'type_id' => type.is_a?(Hash) ? document_id(type) : nil
            }.compact
          end
          objects = Array(flow.objects)
          graph = Array(flow.flows)
          fingerprint = if editable_flow_body?(objects, graph)
                          lines = body_dsl_lines(objects, graph, 2)
                          flow_body_fingerprint(lines, flow)
                        end
          return_type = flow.respond_to?(:return_type_document) && flow.return_type_document
          metadata = {
            'native_type' => native_type,
            'unit_id' => flow.respond_to?(:id) ? flow.id.to_s : nil,
            'parameters' => parameters,
            'return_type_id' => return_type.is_a?(Hash) ? document_id(return_type) : nil,
            'body_fingerprint' => fingerprint
          }.compact
          [flow.name.to_s, metadata]
        end
        flows = flow_entries.group_by(&:first).transform_values do |entries|
          metadata = entries.map(&:last)
          metadata.one? ? metadata.first : metadata
        end
        [mod.name.to_s, { 'flows' => flows }]
      end
      write(
        File.join(@output_dir, '.mxrb', 'semantic_metadata.json'),
        JSON.pretty_generate('version' => 1, 'modules' => values)
      )
    end

    def editable_document_type?(type)
      self.class.ruby_projected_document_type?(type)
    end

    def export_global_documents(project)
      documents = project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [unit, document] if GLOBAL_EDITABLE_DOCUMENT_TYPES.include?(document['$Type'])
      end
      settings = documents.filter_map do |unit, document|
        next unless document['$Type'] == 'Settings$ProjectSettings'

        if (5..11).cover?(project.mendix_version.to_s.split('.').first.to_i)
          typed_project_settings_declaration(document)
        else
          project_document_declaration(:project_settings_document, unit, document, 'Settings')
        end
      end
      texts = system_text_declarations(project, documents)
      write(File.join(@output_dir, 'app', 'settings', 'settings.rb'), ruby_file(settings))
      write(File.join(@output_dir, 'app', 'texts', 'system_texts.rb'), ruby_file(texts))
    end

    def typed_project_settings_declaration(document)
      model = Settings::MprCodec.new.decode(document)
      externalize_settings_binary_assets(model)
      Settings::SourceEmitter.new.emit(model).rstrip
    rescue Settings::Error, KeyError, TypeError => e
      raise SerializationError, "typed project settings export failed: #{e.message}"
    end

    def externalize_settings_binary_assets(model)
      index = 0
      visit_settings_values(model) do |asset|
        next asset if asset.bytes.empty?

        index += 1
        filename = "certificate-#{index}.bin"
        path = File.join(@output_dir, 'app', 'settings', filename)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, asset.bytes)
        asset.at(filename)
      end
    end

    def visit_settings_values(value, &block)
      case value
      when Settings::Node
        value.fields.each { |field, child| value.set(field, visit_settings_values(child, &block)) }
        value
      when Settings::Collection
        Settings::Collection.new(items: value.items.map { visit_settings_values(_1, &block) },
                                 marker: value.marker)
      when Settings::BinaryAsset
        yield(value)
      else
        value
      end
    end

    def system_text_declarations(project, documents)
      documents.filter_map do |unit, document|
        next unless document['$Type'] == 'Texts$SystemTextCollection'

        if project.mendix_version.to_s.split('.').first.to_i == 11
          typed_system_text_declaration(document)
        else
          project_document_declaration(:system_text_collection, unit, document, 'SystemTexts')
        end
      end
    end

    def typed_system_text_declaration(document)
      model = SystemTexts::MprCodec.new.decode(document)
      SystemTexts::SourceEmitter.new.emit(model).rstrip
    rescue SystemTexts::CodecError, KeyError, TypeError => e
      raise SerializationError, "typed system-text export failed: #{e.message}"
    end

    def project_document_declaration(method, unit, document, field)
      options = {
        unit_id: unit.fetch('UnitID'), container_id: unit.fetch('ContainerID'),
        containment: unit.fetch('ContainmentName'), id: document_id(document),
        (field == 'Settings' ? :settings : :system_texts) => presentation_value_spec(document[field])
      }
      lines = ["#{method}("]
      options.each_with_index do |(key, value), index|
        comma = index == options.size - 1 ? '' : ','
        lines << "  #{key}: #{native_ruby(value, 2)}#{comma}"
      end
      lines << ')'
      lines.join("\n")
    end

    def ruby_file(declarations)
      "# frozen_string_literal: true\n\n#{declarations.join("\n\n")}\n"
    end

    def export_ruby_app_sources(project)
      files = project.mpr.ruby_app_sources
      return false if files.empty?

      payload = files.map do |file|
        contents = file.fetch(:contents)
        {
          'path' => file.fetch(:path), 'sha256' => file.fetch(:sha256),
          'contents' => Base64.strict_encode64(contents), 'mode' => file.fetch(:mode, 0o644)
        }
      end
      write(
        File.join(@output_dir, '.mxrb', 'ruby_sources.json'),
        JSON.pretty_generate('version' => 1, 'files' => payload)
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
        native_unit #{ruby(unit.fetch('UnitID'))},
                    container_id: #{ruby(unit.fetch('ContainerID'))},
                    containment: #{ruby(unit.fetch('ContainmentName'))},
                    module_name: #{ruby(module_name_for(project, unit))},
                    deep_structure: #{native_fragment_ruby(doc)}
      RUBY
    end

    def module_name_for(project, unit)
      container = unit['ContainerID']
      project.modules.find { _1.id == container }&.name ||
        project.modules.find { |mod| native_descendant_of?(project, container, mod.id) }&.name
    end

    def native_descendant_of?(project, child_id, ancestor_id)
      current = project.raw_unit(child_id)
      until current.nil? || current['UnitID'] == current['ContainerID']
        return true if current['ContainerID'] == ancestor_id

        current = project.raw_unit(current['ContainerID'])
      end
      false
    end

    def export_security(project)
      doc = project_security_doc(project)
      source = doc ? security_source(doc) : "# frozen_string_literal: true\n"
      write(File.join(@output_dir, 'app', 'security', 'security.rb'), source)
    end

    def export_architecture_contracts(project)
      navigation = @architecture&.fetch(:navigation, nil)
      navigation ||= project.navigation.to_h unless project.navigation.empty?
      design_system = @architecture&.fetch(:design_system, nil)
      write(
        File.join(@output_dir, 'app', 'navigation', 'navigation.rb'),
        navigation_source(navigation)
      )
      write(
        File.join(@output_dir, 'app', 'design_system', 'design_system.rb'),
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
      ].each { write(File.join(root, _1, '.keep'), '') }

      security_path = File.join(root, 'security', 'security.rb')
      write(security_path, "# frozen_string_literal: true\n") unless File.exist?(security_path)
    end

    def export_module_security(root, mod)
      roles = mod.module_roles.map do |role|
        args = [symbol(role.fetch(:name))]
        id = role.fetch(:id, '').to_s
        args << "id: #{ruby(id)}" unless id.empty?
        description = role.fetch(:description, '')
        args << "description: #{ruby(description)}" unless description.empty?
        "module_role #{args.join(', ')}"
      end
      source = (['# frozen_string_literal: true', ''] + roles).join("\n") + "\n"
      write(File.join(root, 'security', 'security.rb'), source)
    end

    def export_domain(root, mod)
      domain = File.join(root, 'domain')
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
      rule_files = unique_filenames(mod.rules)
      mod.rules.each do |rule|
        relative = File.join('rules', rule_files.fetch(rule.id))
        write(File.join(domain, relative), rule_source(rule))
        paths[rule.id] = relative
      end
      loads = paths.values.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(', ')
        %(evaluate File.join(__dir__, #{segments}))
      end
      write(File.join(domain, 'model.rb'), "#{loads.join("\n")}\n")
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
      by_layer = { 'application' => [], 'infrastructure' => [] }
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
        relative = File.join('ports', 'repositories.rb')
        write(File.join(root, 'application', relative), repositories_source(repositories))
        by_layer['application'] << relative
      end
      by_layer.each do |layer, paths|
        write_path_aggregator(File.join(root, layer, "#{layer}.rb"), paths)
      end
    end

    def export_pages(root, mod)
      presentation = File.join(root, 'presentation')
      documents = File.join(presentation, 'pages')
      FileUtils.mkdir_p(documents)
      files = unique_filenames(mod.pages)
      architecture = architecture_module(mod.name)
      paths = []
      mod.pages.each do |page|
        relative = File.join('pages', files.fetch(page.id))
        metadata = artifact_metadata(
          mod.name, :page, page.name,
          architecture&.fetch(:pages, [])&.find { _1[:name] == page.name }
        )
        write(
          File.join(presentation, relative),
          page_source(page, metadata, module_unit_id: mod.id)
        )
        paths << relative
      end
      append_to_aggregator(File.join(presentation, 'presentation.rb'), paths)
    end

    def export_infrastructure_documents(root, mod)
      documents = mod.infrastructure_documents
      return if documents.empty?

      infrastructure = File.join(root, 'infrastructure')
      used = {}
      paths = documents.map do |document|
        base = underscore(document.fetch(:name))
        relative = unique_relative_path(document.fetch(:route), base, used)
        write(File.join(infrastructure, relative), mapping_document_source(document, mod:))
        relative
      end
      append_to_aggregator(
        File.join(infrastructure, 'infrastructure.rb'), paths,
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
        output_path = File.join(presentation, relative)
        write(output_path, mapping_document_source(document, output_path:))
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

    def mapping_document_source(document, mod: nil, output_path: nil)
      <<~RUBY
        # frozen_string_literal: true

        #{integration_document_declaration(document, mod:, output_path:)}
      RUBY
    end

    def integration_document_declaration(document, mod: nil, output_path: nil)
      doc = document.fetch(:doc)
      if (forms_model = @typed_forms_documents&.fetch(document.fetch(:id), nil))
        return typed_forms_document_declaration(document, forms_model, output_path:)
      end

      case document.fetch(:type)
      when 'JsonStructures$JsonStructure'
        return json_structure_declaration(document) if doc.key?('JsonSnippet')
      when 'XmlSchemas$XmlSchema'
        return xml_schema_declaration(document) if semantic_xml_schema?(doc)
      when 'ImportMappings$ImportMapping'
        return mapping_declaration(document, :import) if doc.key?('JsonStructure')
      when 'ExportMappings$ExportMapping'
        return mapping_declaration(document, :export) if doc.key?('JsonStructure')
      when 'Rest$PublishedRestService'
        return published_rest_declaration(document, mod:) if semantic_rest_service?(doc, mod:)
      when 'ODataPublish$PublishedODataService2'
        return published_odata_service_declaration(document) if semantic_published_odata_service?(doc)
      when 'Rest$ConsumedODataService'
        return consumed_odata_service_declaration(document) if semantic_consumed_odata_service?(doc)
      when 'Authentication$Authentication'
        return authentication_declaration(document) if semantic_authentication?(doc)
      when 'AppServices$ConsumedAppService'
        return consumed_app_service_declaration(document) if semantic_consumed_app_service?(doc)
      when 'WebServices$PublishedService'
        return published_web_service_declaration(document) if semantic_published_web_service?(doc)
      when 'WebServices$ImportedServiceImpl'
        return imported_web_service_declaration(document) if semantic_imported_web_service?(doc)
      when 'MessageDefinitions$MessageDefinitionCollection'
        return message_definition_collection_declaration(document) \
          if semantic_message_definition_collection?(doc)
      when 'Enumerations$Enumeration'
        return enumeration_declaration(document) if semantic_enumeration?(doc)
      when 'Constants$Constant'
        return constant_declaration(document) if doc['Type'].is_a?(Hash)
      when 'DomainModels$ViewEntitySourceDocument'
        return oql_source_declaration(document) if doc.key?('Oql')
      when 'DatabaseConnector$DatabaseConnection'
        return database_connection_declaration(document) if semantic_database_connection?(doc)
      when 'DataSets$DataSet'
        return dataset_declaration(document) if semantic_dataset?(doc)
      when 'Queues$Queue'
        return task_queue_declaration(document) if semantic_task_queue?(doc)
      when 'ScheduledEvents$ScheduledEvent'
        return scheduled_event_declaration(document) if semantic_scheduled_event?(doc)
      when 'RegularExpressions$RegularExpression'
        return regular_expression_declaration(document)
      when 'JavaActions$JavaAction'
        return code_action_declaration(document, :java) if semantic_code_action?(doc)
      when 'JavaScriptActions$JavaScriptAction'
        return code_action_declaration(document, :javascript) if semantic_code_action?(doc)
      when 'Workflows$Workflow'
        return workflow_declaration(document) if semantic_workflow?(doc)
      when 'Forms$Layout'
        return layout_document_declaration(document)
      when 'Forms$PageTemplate'
        return page_template_document_declaration(document)
      when 'Forms$BuildingBlock'
        return building_block_document_declaration(document)
      when 'Forms$Snippet'
        return snippet_document_declaration(document)
      when 'Images$ImageCollection'
        return image_collection_declaration(document)
      when 'CustomIcons$CustomIconCollection'
        return custom_icon_collection_declaration(document)
      end
      native_document_declaration(document)
    end

    TYPED_FORMS_DECLARATIONS = {
      'Forms$Layout' => :layout_document,
      'Forms$PageTemplate' => :page_template_document,
      'Forms$BuildingBlock' => :building_block_document,
      'Forms$Snippet' => :snippet_document
    }.freeze

    def typed_forms_document_declaration(document, model, output_path:)
      externalize_forms_binary_assets(model, output_path:) if output_path
      declaration = "#{TYPED_FORMS_DECLARATIONS.fetch(document.fetch(:type))} " \
                    "#{symbol(document.fetch(:name))}"
      Forms::SourceEmitter.new.emit_as(model, declaration).rstrip
    end

    def externalize_forms_binary_assets(model, output_path:)
      property = model.schema_type.property(:image_data)
      return unless property && (asset = model.fetch(property.name)).is_a?(Forms::BinaryAsset)
      return if asset.bytes.empty?

      extension = forms_binary_extension(asset.bytes)
      filename = "#{File.basename(output_path, '.rb')}.preview#{extension}"
      FileUtils.mkdir_p(File.dirname(output_path))
      File.binwrite(File.join(File.dirname(output_path), filename), asset.bytes)
      model.set(property.name, asset.at(filename))
    end

    def forms_binary_extension(bytes)
      return '.png' if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      return '.jpg' if bytes.start_with?("\xFF\xD8\xFF".b)
      return '.gif' if bytes.start_with?('GIF87a', 'GIF89a')
      return '.webp' if bytes.start_with?('RIFF') && bytes.byteslice(8, 4) == 'WEBP'

      '.bin'
    end

    OAUTH_AUTHENTICATION_FIELDS = %w[
      $ID $Type Audience ClientId ClientSecret GrantType ProviderName Scopes TenantId
      TokenEndPoint WellKnownEndPoint
    ].freeze
    OAUTH_AUTH_CODE_FIELDS = (
      OAUTH_AUTHENTICATION_FIELDS + %w[AuthorizationEndpoint CallbackUrl ResponseMode ResponseType]
    ).freeze

    MESSAGE_EXPOSED_ENTITY_FIELDS = %w[
      $ID $Type Children Documentation ElementType Entity ErrorMessage Example ExposedItemName
      ExposedName FractionDigits IsDefaultType MaxLength MaxOccurs MinOccurs Nillable OriginalName
      Path PrimitiveType TotalDigits WarningMessage
    ].freeze
    MESSAGE_EXPOSED_ATTRIBUTE_FIELDS = (
      MESSAGE_EXPOSED_ENTITY_FIELDS - %w[Entity] + %w[Attribute]
    ).freeze

    def semantic_block_call_lines(method, name, options, indent:)
      lines = semantic_call_lines(method, name, options, indent:)
      lines[-1] = "#{lines[-1]} do"
      lines
    end

    def semantic_call_lines(method, name, options, indent:)
      pad = ' ' * indent
      return ["#{pad}#{method} #{symbol(name)}"] if options.empty?

      continuation = ' ' * (indent + 16)
      lines = ["#{pad}#{method} #{symbol(name)},"]
      options.each_with_index do |(key, value), index|
        comma = index == options.size - 1 ? '' : ','
        lines << "#{continuation}#{key}: #{native_ruby(value, indent + 16)}#{comma}"
      end
      lines
    end

    WORKFLOW_ACTIVITY_FIELDS = %w[
      $ID $Type Annotation Caption Name PersistentId RelativeMiddlePoint Size
    ].freeze
    WORKFLOW_USER_TASK_FIELDS = (WORKFLOW_ACTIVITY_FIELDS + %w[
      AutoAssignSingleTargetUser BoundaryEvents DueDate OnCreatedEvent Outcomes
      TaskDescription TaskName TaskPage UserTargeting
    ]).freeze
    WORKFLOW_MULTI_USER_TASK_FIELDS = (WORKFLOW_USER_TASK_FIELDS + %w[
      AwaitAllUsers CompletionCriteria TargetUserInput
    ]).freeze
    WORKFLOW_WAIT_TIMER_FIELDS = (WORKFLOW_ACTIVITY_FIELDS + %w[Delay]).freeze
    WORKFLOW_CALL_MICROFLOW_FIELDS = (WORKFLOW_ACTIVITY_FIELDS + %w[
      BoundaryEvents Microflow Outcomes ParameterMappings
    ]).freeze
    WORKFLOW_CALL_WORKFLOW_FIELDS = (WORKFLOW_ACTIVITY_FIELDS + %w[
      BoundaryEvents ExecuteAsync ParameterMappings Workflow
    ]).freeze

    def bson_marker(bson, fallback)
      IO::BsonCodec.parse_array(bson)[:marker]
    rescue StandardError
      fallback
    end

    def document_id(document)
      IO::BsonCodec.extract_id(document.to_h['$ID']).to_s
    end

    def camelize_key(key)
      key.to_s.split('_').map!(&:capitalize).join
    end

    def native_document_declaration(document)
      <<~RUBY.rstrip
        native_document #{symbol(document.fetch(:name))},
                        type: #{ruby(document.fetch(:type))},
                        unit_id: #{ruby(document.fetch(:id))},
                        container_id: #{ruby(document.fetch(:container_id))},
                        containment: #{ruby(document.fetch(:containment))},
                        # Native BSON, including bson_binary(...) values, is content-addressed.
                        deep_structure: #{native_fragment_ruby(document.fetch(:doc))}
      RUBY
    end

    def append_to_aggregator(path, relative_paths, managed_types: [])
      existing = File.exist?(path) ? File.read(path).lines : []
      management = Array(managed_types).uniq.sort.map do |type|
        "manage_native_documents #{ruby(type)}\n"
      end
      additions = relative_paths.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(', ')
        "evaluate File.join(__dir__, #{segments})\n"
      end
      write(path, (existing + management + additions).uniq.join)
    end

    def export_menus(root, mod)
      menus = mod.menus
      return if menus.empty?

      presentation = File.join(root, 'presentation')
      files = unique_filenames(menus)
      paths = []
      menus.each do |menu|
        relative = File.join('menus', files.fetch(menu.id))
        write(File.join(presentation, relative), menu_source(menu))
        paths << relative
      end
      append_to_aggregator(
        File.join(presentation, 'presentation.rb'), paths,
        managed_types: ['Menus$MenuDocument']
      )
    end

    def export_nanoflows(root, mod)
      flows = mod.nanoflows
      return if flows.empty?

      presentation = File.join(root, 'presentation')
      files = unique_filenames(flows)
      paths = []
      architecture = architecture_module(mod.name)
      flows.each do |flow|
        relative = File.join('client_actions', files.fetch(flow.id))
        metadata = flow_metadata(
          mod.name, :nanoflow, flow.name,
          architecture&.fetch(:nanoflows, [])&.find { _1[:name] == flow.name }
        )
        write(File.join(presentation, relative), nanoflow_source(flow, metadata))
        paths << relative
      end
      existing = File.read(File.join(presentation, 'presentation.rb')).lines
      additions = paths.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(', ')
        "evaluate File.join(__dir__, #{segments})\n"
      end
      write(File.join(presentation, 'presentation.rb'), (existing + additions).join)
    end

    def write_path_aggregator(path, relative_paths)
      loads = relative_paths.sort.map do |relative|
        segments = relative.split(File::SEPARATOR).map { ruby(_1) }.join(', ')
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

    # ── Microflow / nanoflow body export ─────────────────────────────────────

    def ruby_val(val)
      # Native expressions are source text, not Ruby literals to interpret.
      # Leading zeros, decimal precision and words such as "nil" are data.
      return ruby(val) if val.is_a?(String)
      return 'nil' if val.nil? || val.to_s.empty?
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
          infer_public_reference(public_artifacts, mod.name, page.data_source)
          each_page_widget(page.widgets) do |widget|
            infer_public_reference(public_artifacts, mod.name, widget.dig(:options, :source)) if
              widget[:type].to_sym == :data_view
          end
          each_widget_event(page.widgets) do |event|
            infer_public_reference(
              public_artifacts, mod.name,
              { kind: event.fetch(:kind), name: event.fetch(:handler) }
            )
          end
        end
      end
    end

    def each_widget_event(widgets, &block)
      Array(widgets).each do |widget|
        Array(widget[:events]).each(&block)
        each_widget_event(direct_widget_children(widget), &block)
        Array(widget.dig(:options, :tabs)).each do |tab|
          each_widget_event(tab[:widgets], &block)
        end
        Array(widget.dig(:options, :rows)).each do |row|
          Array(row[:columns]).each { each_widget_event(_1[:widgets], &block) }
          Array(row[:cells]).each { each_widget_event(_1[:widgets], &block) }
        end
      end
    end

    def each_page_widget(widgets, &block)
      Array(widgets).each do |widget|
        yield widget
        each_page_widget(direct_widget_children(widget), &block)
        Array(widget.dig(:options, :tabs)).each { each_page_widget(_1[:widgets], &block) }
        Array(widget.dig(:options, :rows)).each do |row|
          Array(row[:columns]).each { each_page_widget(_1[:widgets], &block) }
          Array(row[:cells]).each { each_page_widget(_1[:widgets], &block) }
        end
      end
    end

    def direct_widget_children(widget)
      regions = widget[:regions]
      region_widgets = regions.is_a?(Hash) ? regions.values.flat_map { Array(_1) } : []

      (
        Array(widget[:children]) +
        Array(widget[:slots]).flat_map { Array(_1[:widgets]) } +
        Array(widget[:body]) +
        Array(widget[:footer]) +
        region_widgets
      ).uniq
    end

    def infer_public_reference(public_artifacts, current_module, reference)
      return unless reference
      return if reference.fetch(:kind).to_sym == :action
      return if reference[:name].to_s.empty?

      target_module, target_name = reference.fetch(:name).to_s.split('.', 2)
      return if target_name.to_s.empty? || target_module == current_module

      public_artifacts[[target_module, reference.fetch(:kind).to_sym, target_name]] = true
    end

    def artifact_metadata(module_name, kind, name, metadata)
      result = metadata ? metadata.dup : {}
      result[:public] = true if @inferred_public_artifacts&.include?([module_name, kind, name])
      result.empty? ? nil : result
    end

    def flow_metadata(module_name, kind, name, metadata)
      artifact_metadata(module_name, kind, name, metadata)
    end

    def reference(value)
      value.to_s.include?('.') ? ruby(value.to_s) : symbol(value)
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
