# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'pp'
require 'time'
require 'tmpdir'
require_relative '../native_fragment_store'
require_relative 'legacy_service_source_migration'
require_relative 'legacy_widget_source_migration'
require_relative 'exporter/domain_behaviors'
require_relative 'exporter/module_exports'
require_relative 'exporter/domain_manifests'
require_relative 'exporter/nanoflow_typescript'
require_relative 'exporter/frontend_pages'
require_relative 'exporter/document_exports'
require_relative 'exporter/widget_manifests'
require_relative 'exporter/model_sources'
require_relative 'exporter/widget_sources'
require_relative 'exporter/data_widget_sources'
require_relative 'exporter/support_files'
require_relative 'exporter/project_files'
require_relative 'exporter/frontend_types'
require_relative 'known_javascript_actions'
require_relative 'known_feedback_widget'
require_relative 'project_widget_bundle'
require_relative 'project_javascript_actions'

module Mxrb
  module RubyApp
    # Projects a Mendix model into conventional executable Ruby source while
    # retaining the complete Mendix-mode tree as the reversible sidecar.
    # rubocop:disable Metrics
    class Exporter
      include DomainBehaviors
      include ModuleExports
      include DomainManifests
      include NanoflowTypescript
      include FrontendPages
      include DocumentExports
      include WidgetManifests
      include ModelSources
      include WidgetSources
      include DataWidgetSources
      include SupportFiles
      include ProjectFiles
      include FrontendTypes

      FRONTEND_TEMPLATE_DIR = File.expand_path('frontend_template', __dir__)
      RUBY_KEYWORDS = %w[
        alias and begin break case class def defined do else elsif end ensure false
        for if in module next nil not or redo rescue retry return self super then
        true undef unless until when while yield
      ].freeze
      RECORD_RESERVED = %w[attributes id initialize mendix_id mendix_name to_h type].freeze
      LEGACY_PUBLIC_PROJECTION_PATH = %r{\Aapp/(?:
        constants|dtos|enumerations|models|pages|scheduled_events|security|services
      )/.+\.rb\z}x
      LEGACY_PUBLIC_IDENTITY = /^\s*(?:
        mendix_name\s+['"][^'"]+['"],\s+id: |
        mendix_id\s+['"]
      )/x

      def initialize(mpr_path, output_dir, mendix_sidecar:)
        @mpr_path = File.expand_path(mpr_path)
        @output_dir = File.expand_path(output_dir)
        @mendix_sidecar = File.expand_path(mendix_sidecar)
      end

      def export!
        FileUtils.mkdir_p(@output_dir)
        @native_fragment_store = NativeFragmentStore.new(
          File.join(@output_dir, '.mxrb', 'native_fragments')
        )
        @rest_response_metadata = read_rest_response_metadata
        runtime_mpr = copy_runtime_mpr
        embedded_sources = read_embedded_sources
        @embedded_sources = embedded_sources
        @embedded_source_paths = embedded_sources.to_h { [_1.fetch(:path), true] }
        @embedded_identities = SourceIdentity.read_bundle(embedded_sources).to_h do |identity|
          [[identity.fetch('kind'), identity.fetch('id')], identity]
        end
        require_relative 'presentation_exporter'
        Mxrb.open(@mpr_path) do |project|
          @project = project
          @known_entity_names = project.modules.flat_map do |mod|
            mod.entities.map { "#{mod.name}.#{_1.name}" }
          end.freeze
          @coverage = []
          @nanoflow_entries = []
          @page_entries = []
          @rendered_widget_ids = Set.new
          @called_javascript_actions = Set.new
          modules = PluggableProperties.with_mpr(project.mpr) do |context|
            result = project.modules.map { export_module(_1) }
            PresentationExporter.new(self, project).export!
            context.export_schemas(@output_dir)
            result
          end
          @security_manifest = export_project_security(project)
          @module_manifests = modules
          write_support_files
          copy_round_trip_metadata
          write_design_classes(project)
          @widget_ids = WidgetStyles.widget_ids(project)
          copy_frontend_theme
          restore_embedded_sources(embedded_sources)
          refresh_native_frontend_sources(project, modules, embedded_sources)
          write_manifest(project, modules, runtime_mpr)
        end
        @output_dir
      ensure
        @project = nil
        @embedded_sources = nil
        @embedded_source_paths = nil
        @embedded_identities = nil
        @module_manifests = nil
        @security_manifest = nil
        @known_entity_names = nil
        @native_fragment_store = nil
        @rest_response_metadata = nil
      end

      private

      # Shared presentation always emits typed Forms declarations. Its decoding
      # fragments are intermediate values, not dependencies of the exported app.
      def with_presentation_fragments
        previous = @native_fragment_store
        Dir.mktmpdir('mxrb-presentation-fragments-') do |directory|
          @native_fragment_store = NativeFragmentStore.new(directory)
          yield
        end
      ensure
        @native_fragment_store = previous
      end

      def read_embedded_sources
        mpr = IO::MprFile.open(@mpr_path, readonly: true)
        mpr.ruby_app_sources
      ensure
        mpr&.close
      end

      def read_rest_response_metadata
        path = File.join(@mendix_sidecar, '.mxrb', 'rest_metadata.json')
        return [] unless File.file?(path)

        JSON.parse(File.read(path)).fetch('operations')
      rescue JSON::ParserError, KeyError => e
        raise SerializationError, "invalid REST metadata sidecar #{path}: #{e.message}"
      end

      def embedded_identity(kind, id)
        identity = @embedded_identities&.fetch([kind.to_s, id.to_s], nil)
        identity if identity && @embedded_source_paths&.key?(identity.fetch('path'))
      end

      def embedded_identity_path(kind, id)
        embedded_identity(kind, id)&.fetch('path')
      end

      def embedded_identity_class(kind, id, fallback)
        name = embedded_identity(kind, id)&.fetch('ruby_class', nil).to_s
        name.empty? ? fallback : name
      end

      def restore_embedded_sources(files)
        files.each do |file|
          next if file.fetch(:path).start_with?('frontend/src/generated/')

          contents = file.fetch(:contents)
          checksum = Digest::SHA256.hexdigest(contents)
          raise SerializationError, "embedded Ruby source checksum mismatch: #{file.fetch(:path)}" \
            unless checksum == file.fetch(:sha256)

          contents = LegacyServiceSourceMigration.new(
            path: file.fetch(:path), source: contents
          ).migrate

          path = RubyApp.safe_source_path(@output_dir, file.fetch(:path))
          FileUtils.mkdir_p(File.dirname(path))
          if regenerate_legacy_public_projection?(file.fetch(:path), contents, path)
            File.chmod(RubyApp.safe_source_mode(file[:mode], file.fetch(:path)), path)
            next
          end
          if regenerate_legacy_widget_page?(file, path)
            File.chmod(RubyApp.safe_source_mode(file[:mode], file.fetch(:path)), path)
            next
          end

          File.binwrite(path, contents)
          File.chmod(RubyApp.safe_source_mode(file[:mode], file.fetch(:path)), path)
        end
      end

      def regenerate_legacy_public_projection?(relative, embedded, generated)
        return false unless LEGACY_PUBLIC_PROJECTION_PATH.match?(relative)
        return false unless File.file?(generated) && embedded.match?(LEGACY_PUBLIC_IDENTITY)

        definitions = embedded.scan(/^\s*def\s+(?:self\.)?([^\s(]+)/).flatten
        return true if definitions.empty?
        return false unless relative.start_with?('app/services/') && definitions == ['call']

        embedded.match?(
          /def\s+call\(\*\*arguments\)\s+(?:native_call|execute_flow)\(arguments\)\s+end/m
        )
      end

      def regenerate_legacy_widget_page?(file, generated_path)
        return false unless File.file?(generated_path)

        LegacyWidgetSourceMigration.new(
          path: file.fetch(:path), embedded_source: file.fetch(:contents),
          generated_source: File.binread(generated_path)
        ).regenerate?
      end

      # Generated frontend projections normally remain user-editable and are
      # restored byte-for-byte. A Ruby class with an explicit `native`
      # declaration is authoritative, though, so its page/nanoflow projection
      # must be refreshed from the just-compiled MPR instead of reviving stale
      # TypeScript from the previous round trip.
      def refresh_native_frontend_sources(project, modules, embedded_sources)
        names = embedded_native_document_names(embedded_sources)
        return if names.empty?

        modules.each do |mod|
          root = underscore(mod.fetch('name'))
          mod.fetch('pages').each do |page|
            next unless names.include?(page.fetch('name'))

            page_name = page.fetch('name').split('.', 2).last
            export_frontend_page(page, root, page_name)
            @page_entries.pop
          end
        end
        project.modules.each do |mod|
          root = underscore(mod.name)
          mod.nanoflows.each do |flow|
            qualified = "#{mod.name}.#{flow.name}"
            next unless names.include?(qualified)

            relative = File.join(
              'frontend', 'src', 'generated', 'nanoflows', root, "#{underscore(flow.name)}.ts"
            )
            write(relative, nanoflow_typescript(flow, qualified))
          end
        end
        write_generated_frontend_contract
      end

      def embedded_native_document_names(files)
        files.filter_map do |file|
          next unless file.fetch(:path).match?(%r{\Aapp/(?:pages|services)/.+\.rb\z})

          source = file.fetch(:contents).to_s
          next unless source.match?(/^\s*native(?:\s|\()/)

          match = source.match(/^\s*mendix_name\s+(['"])([^'"]+)\1/)
          match && match[2]
        end.uniq
      end

      def copy_runtime_mpr
        directory = File.join(@output_dir, '.mxrb', 'runtime')
        FileUtils.mkdir_p(directory)
        destination = File.join(directory, File.basename(@mpr_path))
        FileUtils.cp(@mpr_path, destination)
        source_contents = File.join(File.dirname(@mpr_path), 'mprcontents')
        FileUtils.cp_r(source_contents, directory, remove_destination: true) if File.directory?(source_contents)
        copy_runtime_project_assets(directory)
        destination
      end

      def copy_runtime_project_assets(runtime_directory)
        source_root = File.dirname(@mpr_path)
        destination_root = File.join(runtime_directory, 'project')
        directories = Model::DesignSystem::ASSET_DIRECTORIES + Mxrb::Exporter::PROJECT_FILES +
                      Mxrb::Exporter::MARKETPLACE_PROVENANCE
        directories.each do |relative_path|
          source = File.join(source_root, relative_path)
          next unless File.exist?(source) && !File.symlink?(source)

          target = File.join(destination_root, relative_path)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp_r(source, target, remove_destination: true)
        end
      end

      # Widgets whose design is declared in Ruby resolve it when served; the
      # recorded classes cover only typed native fragments without declarations.
      def write_design_classes(project)
        classes = DesignClasses.collect(project, File.dirname(@mpr_path)).filter_map do |document, widgets|
          remaining = widgets.except(*declared_designs.fetch(document, []))
          [document, remaining] unless remaining.empty?
        end.to_h
        write(DesignClasses::PATH, "#{JSON.pretty_generate(classes)}\n") unless classes.empty?
      end

      def record_declared_designs(document, keys)
        declared_designs[document] = declared_designs.fetch(document, []) + keys
      end

      def declared_designs = (@declared_designs ||= {})

      def copy_round_trip_metadata
        source = File.join(@mendix_sidecar, '.mxrb', 'semantic_metadata.json')
        return unless File.file?(source)

        destination = File.join(@output_dir, '.mxrb', 'semantic_metadata.json')
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination)
      end

      DSL_SINK_OPTIONS = {
        sidebar_toggle: %w[caption class style dynamic_class visible button_style tooltip icon],
        button: %w[caption parameters class style dynamic_class visible visibility button_style icon render_type],
        check_box: %w[attribute caption class style dynamic_class visible],
        container: %w[class style dynamic_class visible],
        date_picker: %w[attribute caption class style dynamic_class visible],
        drop_down: %w[attribute caption class style dynamic_class visible],
        file_manager: %w[
          allowed_extensions editable max_file_size show_file_in_browser mode tab_index
          class style dynamic_class visible
        ],
        gallery: %w[class style dynamic_class visible entity xpath association context_variable sort],
        image_uploader: %w[
          allowed_extensions caption editable max_file_size thumbnail_width thumbnail_height
          tab_index class style dynamic_class visible
        ],
        image_viewer: %w[
          entity source alternative_text default_image force_full_objects width height width_unit
          height_unit responsive show_as_thumbnail on_click_enlarge tab_index
          class style dynamic_class visible
        ],
        menu_bar: %w[menu navigation_profile tab_index class style dynamic_class visible],
        navigation_list: %w[tab_index class style dynamic_class visible],
        navigation_tree: %w[menu navigation_profile tab_index class style dynamic_class visible],
        number_input: %w[attribute caption class style dynamic_class visible],
        page_title: %w[class style dynamic_class visible],
        placeholder: %w[parameter],
        pluggable_widget: %w[
          widget_id widget_name properties class style dynamic_class visible platform
        ],
        radio_button_group: %w[attribute caption horizontal class style dynamic_class visible],
        reference_selector: %w[attribute caption display_attribute class style dynamic_class visible],
        reference_set_selector: %w[
          association target_entity display_attribute association_steps association_path caption editable
          selection number_of_rows selectable_xpath control_bar select_first show_empty_rows
          paging tab_index width_unit class style dynamic_class visible
        ],
        scroll_container: %w[
          alignment layout_mode hide_scrollbars scroll_behavior tab_index width width_mode region_options native_layout
          class style dynamic_class visible
        ],
        snippet: %w[snippet arguments class style dynamic_class visible],
        static_image: %w[
          image alternative_text width height width_unit height_unit responsive
          class style dynamic_class visible
        ],
        text: %w[caption parameters class style dynamic_class visible visibility render_mode],
        text_area: %w[attribute caption lines class style dynamic_class visible],
        text_box: %w[attribute caption class style dynamic_class visible]
      }.freeze
      DSL_SINK_BLOCK_METHODS = (DSL_SINK_OPTIONS.keys - %i[snippet placeholder]).freeze

      # The widget types the runtime renders and the options it reads, with
      # their TypeScript types. Generated declarations outside this contract
      # use the explicit ExtensionWidgetDefinition.
      TYPESCRIPT_WIDGET_TYPES = %w[
        button check_box container data_grid data_view date_picker drop_down file_manager gallery
        image_uploader image_viewer layout layout_grid menu_bar native_widget navigation_list
        navigation_tree number_input page_title placeholder pluggable_widget radio_button_group
        reference_selector reference_set_selector scroll_container sidebar_toggle snippet
        static_image tab_control table text text_area text_box
      ].freeze
      TYPESCRIPT_WIDGET_OPTIONS = {
        'alignment' => 'string', 'allowed_extensions' => 'string', 'alternative_text' => 'string',
        'arguments' => 'Record<string, RuntimeValue>', 'aria_label' => 'string', 'aria_required' => 'boolean',
        'association' => 'string', 'association_path' => 'Array<{ association?: string; entity?: string }>',
        'association_steps' => 'number', 'attribute' => 'string', 'autocomplete' => 'string',
        'button_style' => 'string', 'caption' => 'string', 'class' => 'string', 'columns' => 'WidgetColumn[]',
        'columns_draggable' => 'boolean', 'columns_hidable' => 'boolean', 'columns_resizable' => 'boolean',
        'context_variable' => 'string', 'control_bar' => 'boolean', 'default_image' => 'string',
        'design' => 'Record<string, DesignValue>', 'design_class' => 'string',
        'design_properties' => 'RuntimeValue[]', 'desktop' => 'number | string',
        'display_attribute' => 'string', 'dynamic_class' => 'string',
        'editability' => 'RuntimeValue', 'editable' => 'string | boolean', 'entity' => 'string',
        'filter_attributes' => 'string[]', 'force_full_objects' => 'boolean',
        'gutters' => 'boolean', 'height' => 'number',
        'height_unit' => 'string', 'hide_scrollbars' => 'boolean', 'horizontal' => 'boolean',
        'horizontal_alignment' => 'string', 'icon' => 'string', 'image' => 'string',
        'items' => 'RuntimeValue[] | Record<string, RuntimeValue>', 'label_width' => 'number',
        'layout' => 'string', 'layout_mode' => 'string', 'lines' => 'number', 'locale' => 'string',
        'max_file_size' => 'number',
        'max_length' => 'number', 'menu' => 'string', 'mode' => 'string',
        'native_fragment' => '{ digest: string }', 'native_layout' => 'boolean', 'native_type' => 'string',
        'navigation_profile' => 'string', 'no_entity_message' => 'string', 'number_of_rows' => 'number',
        'on_click_enlarge' => 'boolean', 'on_click_trigger' => "'single' | 'double'",
        'options' => 'RuntimeValue[] | Record<string, RuntimeValue>', 'pageSize' => 'number',
        'page_size' => 'number', 'paging' => 'string', 'parameter' => 'string', 'parameters' => 'string[]',
        'password' => 'boolean', 'phone' => 'number | string', 'placeholder' => 'string',
        'platform' => 'string', 'presentation' => 'string',
        'properties' => 'Record<string, unknown>', 'read_only' => 'boolean', 'read_only_style' => 'string',
        'region_options' => 'Record<string, Record<string, RuntimeValue>>', 'render_mode' => 'string',
        'render_type' => 'string', 'responsive' => 'boolean', 'rows' => 'RuntimeValue[]',
        'scroll_behavior' => 'string', 'select_first' => 'boolean', 'selectable_xpath' => 'string',
        'selection' => 'string', 'server_side' => 'boolean', 'show_as_thumbnail' => 'boolean',
        'show_empty_rows' => 'boolean', 'show_file_in_browser' => 'boolean', 'show_footer' => 'boolean',
        'snippet' => 'string', 'sort' => 'Array<{ attribute: string; direction?: string }>',
        'source' => 'DataViewSource', 'source_variable' => 'RuntimeValue', 'style' => 'string',
        'tab_index' => 'number', 'tablet' => 'number | string', 'tabs' => 'WidgetTab[]',
        'target_entity' => 'string',
        'thumbnail_height' => 'number', 'thumbnail_width' => 'number',
        'toolbar' => '{ buttons?: Array<{ type: string }> }', 'tooltip' => 'string',
        'values' => 'RuntimeValue[] | Record<string, RuntimeValue>', 'vertical_alignment' => 'string',
        'visibility' => 'RuntimeValue',
        'visible' => 'string | boolean', 'widget_id' => 'string', 'widget_name' => 'string',
        'width' => 'number | string', 'width_mode' => 'string', 'width_unit' => 'string', 'xpath' => 'string'
      }.freeze

      def ruby_constant(value, suffix: nil)
        parts = value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
                     .split(/[^A-Za-z0-9]+/).reject(&:empty?)
        constant = parts.map { _1[0].upcase + _1[1..].to_s.downcase }.join
        constant = "Artifact#{constant}" if constant.empty? || constant.match?(/\A\d/)
        constant = "#{constant}#{suffix}" if suffix && !constant.end_with?(suffix)
        constant
      end

      # Flows whose names coincide after normalization to a file stem or a
      # Ruby constant receive their unit identity as a disambiguating suffix.
      def duplicate_flow_ids(flows)
        flows = Array(flows)
        duplicate_groups = [flows.group_by { underscore(_1.name) }, flows.group_by { ruby_constant(_1.name) }]
                           .flat_map(&:values).select { _1.size > 1 }.to_h { [_1.first.name.to_s, _1] }
        duplicate_groups.each do |name, group|
          ids = group.map { _1.id.to_s }
          if ids.any?(&:empty?) || ids.uniq.size != ids.size
            raise SerializationError,
                  "duplicate flow #{name} requires distinct explicit unit ids"
          end
        end
        duplicate_groups.values.flatten.map { _1.id.to_s }.uniq.freeze
      end

      def flow_file_stem(flow, duplicate_name:)
        base = underscore(flow.name)
        return base unless duplicate_name

        "#{base}_#{flow_identity_suffix(flow)}"
      end

      def flow_ruby_constant(flow, duplicate_name:)
        return ruby_constant(flow.name) unless duplicate_name

        ruby_constant("#{flow.name}_#{flow_identity_suffix(flow)}")
      end

      def flow_identity_suffix(flow)
        identifier = underscore(flow.id)
        raise SerializationError, "duplicate flow #{flow.name} has no unit id" if identifier.empty?

        identifier
      end

      def ruby_method_name(value)
        name = underscore(value)
        name = "field_#{name}" if name.match?(/\A\d/) || RUBY_KEYWORDS.include?(name) || RECORD_RESERVED.include?(name)
        name.empty? ? 'field' : name
      end

      def underscore(value)
        value.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
             .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
             .gsub(/[^A-Za-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').downcase
      end

      def relative(path)
        Pathname.new(path).relative_path_from(Pathname.new(@output_dir)).to_s
      end

      def write(relative_path, contents)
        path = File.join(@output_dir, relative_path)
        claim_declaration_path(relative_path, contents)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end

      DECLARATION_ROOTS = %w[app/ frontend/src/generated/pages/ frontend/src/generated/nanoflows/].freeze

      # Declaration files are named from normalized Mendix names, so two
      # documents may map to one path. Infrastructure files are rewritten
      # freely, and files the developer wrote are restored from embedded sources.
      def claim_declaration_path(relative_path, contents)
        return unless DECLARATION_ROOTS.any? { relative_path.to_s.start_with?(_1) }
        return if @embedded_source_paths&.key?(relative_path.to_s)

        @declaration_contents ||= {}
        previous = @declaration_contents[relative_path]
        if previous && previous != contents
          raise SerializationError,
                "two declarations generate #{relative_path}; rename one whose name normalizes to the same file"
        end

        @declaration_contents[relative_path] = contents
      end

      def readme
        <<~MARKDOWN
          # #{@project.name}

          Executable Ruby application exported by MXRB.

          ## Run

          ```sh
          bundle install
          npm ci --prefix frontend
          bundle exec mxrb run .
          ```

          `mxrb run` supervises the Ruby API and React + TypeScript + Vite development server
          together. Vite proxies `/api` to Ruby, so both processes behave as one
          application. Use `--server-port` for Ruby and `--client-port` for Vite;
          `--api-port` and `--port` remain compatibility aliases. Generated models,
          DTOs, services, and pages live under `app/`.
          The generated `frontend/src/generated/types.ts` covers domain records, pages, widgets,
          contexts, effects, and API payloads; `npm run typecheck` validates it strictly.
          Service bodies are ordinary Ruby; their default implementation delegates to
          MXRB's pure-Ruby interpreter.

          The frontend follows a conventional application layout. Add product code under
          `frontend/src/features`, `components`, `hooks`, `layouts`, `core`, or `styles`.
          MXRB owns only `frontend/src/generated`, which contains the reversible bridge,
          projected pages/flows, and schema types. Application-owned files are embedded in
          the MPR and restored byte-for-byte; generated files are rebuilt on every export.

          ```sh
          npm ci --prefix frontend
          npm run check --prefix frontend
          ```

          The complete gate runs Prettier, ESLint, Vitest/Testing Library, strict TypeScript,
          and the production Vite build using the committed frontend lockfile.

          Browser CRUD uses the same authenticated entity API as microflows. Configure
          users and bearer tokens through ignored environment files. External app/web
          services, mappings, XML imports, and documents are explicit Ruby integrations
          registered in `config/adapters.rb`; keep credentials out of that committed file.

          ## Recompile to Mendix

          ```sh
          bundle exec mxrb generate project.rb build/#{File.basename(@mpr_path)}
          ```

          The complete bidirectional Mendix source remains under `.mxrb/mendix`. The
          `.mxrb/ruby-app.json` coverage manifest maps stable Mendix IDs to Ruby files and
          records artifacts that remain preserved natively.
        MARKDOWN
      end

      def escape_html(value)
        value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end
    end
    # rubocop:enable Metrics
  end
end
