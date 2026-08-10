# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

module Mxrb
  module RubyApp
    # Projects a Mendix model into conventional executable Ruby source while
    # retaining the complete Mendix-mode tree as the reversible sidecar.
    # rubocop:disable Metrics
    class Exporter
      REST_STATUS_CODES = {
        'ok' => 200, 'created' => 201, 'accepted' => 202,
        'nocontent' => 204, 'movedpermanently' => 301, 'found' => 302,
        'badrequest' => 400, 'unauthorized' => 401, 'forbidden' => 403,
        'notfound' => 404, 'conflict' => 409, 'internalservererror' => 500
      }.freeze
      RUBY_KEYWORDS = %w[
        alias and begin break case class def defined do else elsif end ensure false
        for if in module next nil not or redo rescue retry return self super then
        true undef unless until when while yield
      ].freeze
      RECORD_RESERVED = %w[attributes id initialize mendix_id mendix_name to_h type].freeze

      def initialize(mpr_path, output_dir, mendix_sidecar:)
        @mpr_path = File.expand_path(mpr_path)
        @output_dir = File.expand_path(output_dir)
        @mendix_sidecar = File.expand_path(mendix_sidecar)
      end

      def export!
        FileUtils.mkdir_p(@output_dir)
        runtime_mpr = copy_runtime_mpr
        embedded_sources = read_embedded_sources
        Mxrb.open(@mpr_path) do |project|
          @project = project
          @coverage = []
          @nanoflow_entries = []
          modules = project.modules.map { export_module(_1) }
          write_support_files
          copy_frontend_theme
          restore_embedded_sources(embedded_sources)
          write_manifest(project, modules, runtime_mpr)
        end
        @output_dir
      ensure
        @project = nil
      end

      private

      def read_embedded_sources
        mpr = IO::MprFile.open(@mpr_path, readonly: true)
        mpr.ruby_app_sources
      ensure
        mpr&.close
      end

      def restore_embedded_sources(files)
        files.each do |file|
          contents = file.fetch(:contents)
          checksum = Digest::SHA256.hexdigest(contents)
          raise SerializationError, "embedded Ruby source checksum mismatch: #{file.fetch(:path)}" \
            unless checksum == file.fetch(:sha256)

          path = RubyApp.safe_source_path(@output_dir, file.fetch(:path))
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, contents)
          File.chmod(RubyApp.safe_source_mode(file[:mode], file.fetch(:path)), path)
        end
      end

      def copy_runtime_mpr
        directory = File.join(@output_dir, '.mxrb', 'runtime')
        FileUtils.mkdir_p(directory)
        destination = File.join(directory, File.basename(@mpr_path))
        FileUtils.cp(@mpr_path, destination)
        source_contents = File.join(File.dirname(@mpr_path), 'mprcontents')
        FileUtils.cp_r(source_contents, directory, remove_destination: true) if File.directory?(source_contents)
        destination
      end

      def export_module(mod)
        namespace = ruby_constant(mod.name)
        root = underscore(mod.name)
        entities = mod.entities.map { export_entity(_1, mod, namespace, root) }
        microflows = mod.microflows.map { export_service(_1, mod, namespace, root, :microflow) }
        nanoflows = mod.nanoflows.map { export_nanoflow(_1, mod, root) }
        pages = mod.pages.map { export_page(_1, mod, namespace, root) }
        endpoints = export_endpoints(mod)
        {
          'name' => mod.name, 'ruby_namespace' => namespace,
          'module_roles' => runtime_value(mod.module_roles),
          'models' => entities.reject { _1['dto'] },
          'dtos' => entities.select { _1['dto'] },
          'services' => microflows, 'nanoflows' => nanoflows, 'pages' => pages,
          'endpoints' => endpoints,
          'enumerations' => mod.enumerations.map { enumeration_manifest(mod, _1) },
          'associations' => mod.associations.map { association_manifest(mod, _1) },
          'scheduled_events' => mod.scheduled_events.map { runtime_value(_1) }
        }
      end

      def export_entity(entity, mod, namespace, root)
        dto = !entity.persistable && !entity.oql_view?
        class_name = ruby_constant(entity.name, suffix: dto ? 'Dto' : nil)
        base_name = underscore(entity.name)
        base_name = "#{base_name}_dto" if dto && !base_name.end_with?('_dto')
        category = dto ? 'dtos' : 'models'
        relative = File.join('app', category, root, "#{base_name}.rb")
        qualified = "#{mod.name}.#{entity.name}"
        attributes = entity.attributes.map { attribute_manifest(_1) }
        write(
          relative,
          entity_source(
            namespace, class_name, qualified, entity.id, attributes,
            dto:, persistable: entity.persistable == true
          )
        )
        add_coverage(entity.id, qualified, dto ? 'dto' : 'model', relative, 'executable_bidirectional')
        {
          'name' => qualified, 'id' => entity.id, 'ruby_class' => "#{namespace}::#{class_name}",
          'path' => relative, 'dto' => dto, 'persistable' => entity.persistable == true,
          'attributes' => attributes,
          'system_members' => runtime_value(entity.system_members || {}),
          'access_rules' => runtime_value(entity.access_rules || []),
          'lifecycle' => runtime_value(entity.respond_to?(:lifecycle) ? entity.lifecycle : [])
        }
      end

      def association_manifest(mod, association)
        entities = @project.modules.flat_map do |project_module|
          project_module.entities.map do |entity|
            [entity.id.to_s, "#{project_module.name}.#{entity.name}"]
          end
        end.to_h
        {
          'name' => "#{mod.name}.#{association.name}", 'id' => association.id,
          'type' => association.association_type.to_s,
          'from_entity' => entities[association.from_entity_id.to_s] || association.from_entity_id.to_s,
          'to_entity' => entities[association.to_entity_id.to_s] || association.to_entity_id.to_s
        }
      end

      def export_service(flow, mod, namespace, root, kind)
        class_name = ruby_constant(flow.name)
        relative = File.join('app', 'services', root, "#{underscore(flow.name)}.rb")
        qualified = "#{mod.name}.#{flow.name}"
        write(relative, service_source(namespace, class_name, qualified, flow.id))
        add_coverage(flow.id, qualified, kind.to_s, relative, 'runtime_source_preserved')
        {
          'name' => qualified, 'id' => flow.id,
          'ruby_class' => "#{namespace}::#{class_name}", 'path' => relative,
          'kind' => kind.to_s, 'parameters' => flow.parameters.map { flow_parameter_manifest(_1) },
          'allowed_module_roles' => flow.allowed_module_roles.map(&:to_s)
        }
      end

      def flow_parameter_manifest(parameter)
        variable_type = parameter['VariableType'] || parameter['Type'] || {}
        {
          'name' => parameter['Name'].to_s,
          'type' => variable_type['$Type'].to_s,
          'entity' => variable_type['Entity'],
          'required' => parameter['IsRequired'] != false
        }.compact
      end

      def export_endpoints(mod)
        mod.infrastructure_documents.filter_map do |document|
          next unless document[:type] == 'Rest$PublishedRestService'

          rest_service_manifest(mod, document)
        end
      end

      def rest_service_manifest(mod, document)
        source = document.fetch(:doc)
        operations = IO::BsonCodec.parse_array(source['Resources'])[:items].flat_map do |resource|
          IO::BsonCodec.parse_array(resource['Operations'])[:items].map do |operation|
            rest_operation_manifest(mod, source, resource, operation)
          end
        end
        add_coverage(
          document.fetch(:id), "#{mod.name}.#{document.fetch(:name)}", 'published_rest_service',
          relative(@mendix_sidecar), 'executable_backend_route'
        )
        {
          'name' => "#{mod.name}.#{document.fetch(:name)}", 'path' => source['Path'].to_s,
          'version' => source['Version'].to_s, 'enable_cors' => source['EnableCors'] == true,
          'requires_authentication' => source['RequiresAuthentication'] == true,
          'operations' => operations
        }
      end

      def rest_operation_manifest(mod, service, resource, operation)
        microflow = operation['Microflow'].to_s
        microflow = "#{mod.name}.#{microflow}" unless microflow.empty? || microflow.include?('.')
        service_path = service['Path'].to_s.sub(%r{\A/+}, '').sub(%r{/+\z}, '')
        operation_path = operation['Path'].to_s.sub(%r{\A/+}, '')
        {
          'name' => resource['Name'].to_s, 'method' => operation['HttpMethod'].to_s.upcase,
          'path' => "/#{[service_path, operation_path].reject(&:empty?).join('/')}",
          'microflow' => microflow, 'success_status' => rest_success_status(operation['SuccessStatusCode'])
        }
      end

      def rest_success_status(value)
        return 200 if value.nil? || value.to_s.empty?

        raw = value.is_a?(Hash) ? (value['Value'] || value['Name'] || value['$Type']) : value
        integer = raw.to_s[/\d{3}/]
        return integer.to_i if integer

        REST_STATUS_CODES.fetch(raw.to_s.gsub(/[^A-Za-z]/, '').downcase, 200)
      end

      def export_nanoflow(flow, mod, root)
        qualified = "#{mod.name}.#{flow.name}"
        relative = File.join('frontend', 'src', 'nanoflows', root, "#{underscore(flow.name)}.js")
        plan = nanoflow_plan(flow, qualified)
        write(relative, "export default #{JSON.pretty_generate(plan)};\n")
        entry = {
          'name' => qualified, 'id' => flow.id, 'path' => relative,
          'kind' => 'nanoflow', 'runtime' => 'frontend'
        }
        @nanoflow_entries << entry.merge('import_name' => "Nanoflow#{@nanoflow_entries.size}")
        add_coverage(flow.id, qualified, 'nanoflow', relative, 'frontend_executable')
        entry
      end

      def nanoflow_plan(flow, qualified)
        {
          'name' => qualified, 'id' => flow.id,
          'parameters' => flow.parameters.filter_map { _1['Name'] if _1.is_a?(Hash) },
          'objects' => flow.objects.filter_map { nanoflow_object(_1) },
          'flows' => flow.flows.reject { _1['IsErrorHandler'] == true }.map do |edge|
            {
              'origin' => native_identifier(edge['OriginPointer']),
              'destination' => native_identifier(edge['DestinationPointer']),
              'case' => nanoflow_case(edge)
            }
          end
        }
      end

      def nanoflow_object(object)
        return unless object.is_a?(Hash)

        type = object['$Type'].to_s.delete_prefix('Microflows$')
        result = { 'id' => native_identifier(object), 'type' => type }
        result['return'] = object['ReturnValue'].to_s if type == 'EndEvent'
        result['condition'] = object.dig('SplitCondition', 'Expression').to_s if type == 'ExclusiveSplit'
        result['action'] = nanoflow_action(object['Action']) if type == 'ActionActivity'
        result
      end

      def nanoflow_action(action)
        return {} unless action.is_a?(Hash)

        type = action['$Type'].to_s.delete_prefix('Microflows$').delete_suffix('Action')
        result = { 'type' => type }
        case type
        when 'CreateVariable'
          result.merge!('variable' => action['VariableName'].to_s, 'value' => action['InitialValue'].to_s)
        when 'ChangeVariable'
          result.merge!('variable' => action['ChangeVariableName'].to_s, 'value' => action['Value'].to_s)
        when 'Change'
          changes = native_items(action['Items']).map do |item|
            member = (item['Attribute'].to_s.empty? ? item['Association'] : item['Attribute']).to_s
            { 'member' => member.split(%r{[./]}).last, 'value' => item['Value'].to_s }
          end
          result.merge!('variable' => action['ChangeVariableName'].to_s, 'changes' => changes)
        when 'LogMessage'
          result['message'] = action.dig('MessageTemplate', 'Text').to_s
        end
        result
      end

      def nanoflow_case(edge)
        value = native_items(edge['CaseValues']).first || edge['NewCaseValue'] || {}
        value['$Type'] == 'Microflows$NoCase' ? '' : value['Value'].to_s
      end

      def native_items(value)
        IO::BsonCodec.parse_array(value)[:items]
      rescue StandardError
        Array(value).drop(value.is_a?(Array) && value.first.is_a?(Integer) ? 1 : 0)
      end

      def native_identifier(value)
        IO::BsonCodec.extract_id(value.is_a?(Hash) ? value['$ID'] : value).to_s
      end

      def export_page(page, mod, namespace, root)
        class_name = ruby_constant(page.name, suffix: 'Page')
        relative = File.join('app', 'pages', root, "#{underscore(page.name)}_page.rb")
        qualified = "#{mod.name}.#{page.name}"
        widgets = page.widgets.map { widget_manifest(_1) }
        write(
          relative,
          page_source(namespace, class_name, qualified, page.id, page.title, widgets,
                      appearance_class: page.appearance_class,
                      appearance_style: page.appearance_style,
                      data_source: page.data_source)
        )
        add_coverage(page.id, qualified, 'page', relative, 'native_projection_source_preserved')
        {
          'name' => qualified, 'id' => page.id, 'title' => page.title,
          'ruby_class' => "#{namespace}::#{class_name}", 'path' => relative,
          'appearance_class' => page.appearance_class,
          'appearance_style' => page.appearance_style,
          'data_source' => page.data_source,
          'allowed_module_roles' => page.allowed_module_roles.map(&:to_s),
          'widgets' => widgets
        }
      end

      def attribute_manifest(attribute)
        value = {
          'name' => attribute.name, 'ruby_name' => ruby_method_name(attribute.name),
          'type' => attribute.type.to_s, 'required' => attribute.required == true,
          'default' => attribute.default_value, 'id' => attribute.id
        }
        enumeration = native_identifier(attribute.respond_to?(:enumeration) ? attribute.enumeration : nil)
        value['enumeration'] = enumeration unless enumeration.empty?
        value
      end

      def enumeration_manifest(mod, enumeration)
        name = enumeration['Name'].to_s
        {
          'name' => "#{mod.name}.#{name}",
          'id' => native_identifier(enumeration['$ID']),
          'values' => native_items(enumeration['Values']).map do |value|
            value_name = value['Name'].to_s
            { 'name' => value_name, 'caption' => translated_caption(value['Caption'], value_name) }
          end
        }
      end

      def translated_caption(caption, fallback)
        translation = native_items(caption.is_a?(Hash) ? caption['Items'] : nil).first
        text = translation.is_a?(Hash) ? translation['Text'].to_s : ''
        text.empty? ? fallback : text
      end

      def widget_manifest(widget)
        options = runtime_value(widget.fetch(:options, {}))
        value = { 'type' => widget.fetch(:type).to_s, 'name' => widget.fetch(:name, '').to_s }
        value['options'] = options unless options.empty?
        caption = options['caption']
        value['caption'] = caption unless caption.to_s.empty?
        events = runtime_value(widget.fetch(:events, []))
        value['events'] = events unless events.empty?
        children = Array(widget[:children]).map { widget_manifest(_1) }
        value['children'] = children unless children.empty?
        value
      end

      def runtime_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            next if key.to_s == 'deep_structure'

            result[key.to_s] = runtime_value(child)
          end
        when Array then value.map { runtime_value(_1) }
        when Symbol then value.to_s
        when String, Numeric, TrueClass, FalseClass, NilClass then value
        else value.to_s
        end
      end

      def entity_source(namespace, class_name, qualified, id, attributes, dto:, persistable:)
        declarations = attributes.map do |attribute|
          "    attribute :#{attribute.fetch('ruby_name')}, type: :#{attribute.fetch('type')}, " \
            "mendix_name: #{attribute.fetch('name').inspect}, required: #{attribute.fetch('required')}, " \
            "default: #{attribute.fetch('default').inspect}"
        end
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::#{dto ? 'DTO' : 'Record'}
              mendix_name #{qualified.inspect}, id: #{id.inspect}
              persistence #{persistable}
          #{declarations.join("\n")}
            end
          end
        RUBY
      end

      def service_source(namespace, class_name, qualified, id)
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::Service
              mendix_name #{qualified.inspect}, id: #{id.inspect}

              def call(**arguments)
                native_call(arguments)
              end
            end
          end
        RUBY
      end

      def page_source(namespace, class_name, qualified, id, title, widgets,
                      appearance_class:, appearance_style:, data_source:)
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::Page
              mendix_name #{qualified.inspect}, id: #{id.inspect}
              configure title: #{title.inspect}, widgets: #{widgets.inspect},
                        appearance_class: #{appearance_class.inspect},
                        appearance_style: #{appearance_style.inspect},
                        data_source: #{data_source.inspect}
            end
          end
        RUBY
      end

      def write_support_files
        write('Gemfile', gemfile)
        write('.gitignore', ruby_gitignore)
        write('.env.example', ruby_env_example)
        %w[development qa staging production].each do |name|
          write(File.join('config', 'environments', "#{name}.env.example"), environment_example(name))
        end
        write('project.rb', project_source)
        write(File.join('config', 'application.rb'), application_source)
        write(File.join('config', 'adapters.rb'), adapters_source)
        write(File.join('bin', 'server'), server_source)
        File.chmod(0o755, File.join(@output_dir, 'bin', 'server'))
        write(File.join('frontend', 'package.json'), frontend_package)
        write(File.join('frontend', 'vite.config.js'), vite_config)
        write(File.join('frontend', 'index.html'), frontend_index)
        write(File.join('frontend', 'src', 'main.jsx'), frontend_main)
        write(File.join('frontend', 'src', 'nanoflows.js'), frontend_nanoflows)
        write(File.join('frontend', 'src', 'App.jsx'), frontend_app)
        write(File.join('frontend', 'src', 'app.css'), frontend_css)
        write('README.md', readme)
      end

      def copy_frontend_theme
        root = File.join(@output_dir, 'frontend', 'src', 'mendix')
        FileUtils.mkdir_p(root)
        %w[theme themesource].each do |directory|
          source = File.join(@mendix_sidecar, directory)
          next unless File.directory?(source)

          FileUtils.cp_r(source, File.join(root, directory), remove_destination: true)
        end
        fallback = File.join(root, 'theme', 'web', 'main.scss')
        write(relative(fallback), '') unless File.file?(fallback)
      end

      def write_manifest(project, modules, runtime_mpr)
        native_coverage(project)
        payload = {
          'format_version' => 1, 'mode' => 'ruby',
          'project' => { 'name' => project.name, 'mendix_version' => project.mendix_version },
          'navigation' => runtime_value(project.navigation.to_h),
          'source' => {
            'name' => File.basename(@mpr_path),
            'sha256' => Digest::SHA256.file(@mpr_path).hexdigest
          },
          'modules' => modules, 'coverage' => @coverage,
          'frontend' => {
            'framework' => 'react', 'bundler' => 'vite',
            'source' => 'frontend/src', 'build' => 'frontend/dist'
          },
          'round_trip' => {
            'compiler' => 'project.rb',
            'mendix_project' => relative(File.join(@mendix_sidecar, 'project.rb')),
            'runtime_mpr' => relative(runtime_mpr),
            'editable_mendix_source' => relative(@mendix_sidecar)
          }
        }
        preset = Preset.detect(@output_dir)
        payload['ruby_stack'] = Preset.manifest(preset) if preset
        write(MANIFEST_PATH, JSON.pretty_generate(payload) << "\n")
      end

      def native_coverage(project)
        known_ids = @coverage.to_h { [_1.fetch('id').to_s, true] }
        project.all_units.each do |unit|
          next if known_ids[unit.fetch('UnitID').to_s]

          document = project.parse_bson(unit)
          name = document['Name'] || document['name'] || document['$Type']
          add_coverage(
            unit['UnitID'], name.to_s, document['$Type'].to_s,
            relative(@mendix_sidecar), 'preserved_native'
          )
        end
      end

      def add_coverage(id, name, kind, path, status)
        @coverage << {
          'id' => id.to_s, 'name' => name.to_s, 'kind' => kind.to_s,
          'ruby_path' => path, 'status' => status
        }
      end

      def ruby_constant(value, suffix: nil)
        parts = value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
                     .split(/[^A-Za-z0-9]+/).reject(&:empty?)
        constant = parts.map { _1[0].upcase + _1[1..].to_s.downcase }.join
        constant = "Artifact#{constant}" if constant.empty? || constant.match?(/\A\d/)
        constant = "#{constant}#{suffix}" if suffix && !constant.end_with?(suffix)
        constant
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
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end

      def gemfile
        <<~RUBY
          # frozen_string_literal: true

          source 'https://rubygems.org'
          gem 'mxrb'
        RUBY
      end

      def ruby_gitignore
        <<~TEXT
          .env
          .env.*
          !.env.example
          config/environments/*.env
          !config/environments/*.env.example
          .mxrb/runtime/*.sqlite3
          frontend/node_modules/
          frontend/dist/
        TEXT
      end

      def ruby_env_example
        <<~TEXT
          # Base values; environment profiles override this file.
          MXRB_ENV=development
        TEXT
      end

      def environment_example(name)
        <<~TEXT
          # Copy to #{name}.env. Process ENV has highest precedence.
          MXRB_DATABASE_PATH=.mxrb/runtime/#{name}.sqlite3
          MXRB_SHARED_STORE_PATH=.mxrb/runtime/#{name}-shared.sqlite3
          MXRB_SESSION_TTL=3600
          MXRB_SCHEDULER_LEASE_TTL=300
          MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=false
          MXRB_AUTH_TOKENS=
          MXRB_USERS_JSON=
        TEXT
      end

      def project_source
        <<~RUBY
          # frozen_string_literal: true

          require 'mxrb'

          mendix_version = #{@project.mendix_version.inspect}
          Mxrb::RubyApp.compile(__dir__, mendix_version:)
        RUBY
      end

      def application_source
        <<~RUBY
          # frozen_string_literal: true

          require 'mxrb'

          MXRB_APPLICATION_ROOT = File.expand_path('..', __dir__)
        RUBY
      end

      def adapters_source
        <<~RUBY
          # frozen_string_literal: true

          # Register only the integrations this application uses. Credentials
          # belong in ignored environment files or a deployment secret manager.
          #
          # Mxrb::RubyApp::Registry.register_adapter(:app_service) do |name, document, variables|
          #   MyAppServiceClient.call(name, document:, variables:)
          # end
          #
          # Legacy Custom Actions use Ruby implementations only. Register every
          # permitted action explicitly by its qualified Mendix name.
          #
          # Mxrb::RubyApp::Registry.register_java_custom_action('MyModule.MyAction') do |arguments|
          #   MyRubyAction.call(arguments)
          # end
          #
          # Supported kinds: :app_service, :web_service, :import_xml,
          # :import_mapping, :export_mapping, and :document.
        RUBY
      end

      def server_source
        <<~RUBY
          #!/usr/bin/env ruby
          # frozen_string_literal: true

          require_relative '../config/application'

          host = ENV.fetch('HOST', '127.0.0.1')
          port = Integer(ENV.fetch('PORT', '9292'))
          frontend_port = Integer(ENV.fetch('FRONTEND_PORT', '5173'))
          supervisor = Mxrb::RubyApp::Supervisor.new(
            MXRB_APPLICATION_ROOT, host:, api_port: port, frontend_port:
          )
          puts "[mxrb] Ruby API: http://\#{host}:\#{port}"
          puts "[mxrb] React + Vite: http://\#{host}:\#{frontend_port}"
          trap('INT') { Thread.new { supervisor.shutdown } }
          supervisor.start
        RUBY
      end

      def frontend_package
        JSON.pretty_generate(
          'name' => underscore(@project.name), 'private' => true, 'version' => '0.0.0',
          'type' => 'module',
          'scripts' => { 'dev' => 'vite', 'build' => 'vite build', 'preview' => 'vite preview' },
          'dependencies' => { 'react' => '^19.1.1', 'react-dom' => '^19.1.1' },
          'devDependencies' => {
            '@vitejs/plugin-react' => '^4.7.0', 'sass' => '^1.90.0', 'vite' => '^7.1.1'
          }
        ) << "\n"
      end

      def vite_config
        <<~JS
          import { defineConfig } from 'vite';
          import react from '@vitejs/plugin-react';

          const apiPort = process.env.MXRB_API_PORT || '9292';

          export default defineConfig({
            plugins: [react()],
            server: { proxy: { '/api': `http://127.0.0.1:${apiPort}` } }
          });
        JS
      end

      def frontend_index
        <<~HTML
          <!doctype html>
          <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <title>#{escape_html(@project.name)} · MXRB Ruby</title>
            </head>
            <body>
              <div id="root"></div>
              <script type="module" src="/src/main.jsx"></script>
            </body>
          </html>
        HTML
      end

      def frontend_main
        <<~JS
          import React from 'react';
          import { createRoot } from 'react-dom/client';
          import App from './App.jsx';
          import './app.css';
          import './mendix/theme/web/main.scss';

          createRoot(document.getElementById('root')).render(
            <React.StrictMode><App /></React.StrictMode>
          );
        JS
      end

      def frontend_nanoflows
        imports = @nanoflow_entries.map do |entry|
          relative = entry.fetch('path').delete_prefix('frontend/src/')
          "import #{entry.fetch('import_name')} from './#{relative}';"
        end
        mappings = @nanoflow_entries.map do |entry|
          "  #{entry.fetch('name').inspect}: #{entry.fetch('import_name')}"
        end
        <<~JS
          #{imports.join("\n")}

          export default {
          #{mappings.join(",\n")}
          };
        JS
      end

      def frontend_app
        <<~'JS'
          import { useCallback, useEffect, useRef, useState } from 'react';
          import nanoflows from './nanoflows.js';

          const TOKEN_KEY = 'mxrb.session.token';
          const api = async (path, options = {}, token = null) => {
            const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
            if (token) headers.Authorization = `Bearer ${token}`;
            const response = await fetch(path, {
              ...options, headers
            });
            const payload = await response.json();
            if (!response.ok) {
              const error = new Error(payload.error?.message || `HTTP ${response.status}`);
              error.status = response.status;
              throw error;
            }
            return payload;
          };

          const classes = (...values) => values.filter(Boolean).join(' ');
          const attributes = object => object?.attributes || {};
          const memberName = value => (value || '').split(/[./]/).pop();
          const entityCollectionPath = (entity, association, context) => {
            const path = `/api/entities/${encodeURIComponent(entity)}`;
            if (!association || !context?.type || !context?.id) return path;
            const query = new URLSearchParams({
              association, context_type: context.type, context_id: context.id
            });
            return `${path}?${query}`;
          };
          const expressionValue = (source, context, variables = {}) => {
            const text = (source || '').trim();
            const wrapped = text.match(/^toString\((.*)\)$/);
            if (wrapped) return String(expressionValue(wrapped[1], context, variables) ?? '');
            if (text === '$currentObject') return context;
            const variable = text.match(/^\$([A-Za-z_]\w*)$/);
            if (variable) return variables[variable[1]] ?? context;
            const member = text.match(/^\$([A-Za-z_]\w*)\/([A-Za-z_][\w.]*)$/);
            if (member) return attributes(variables[member[1]] ?? context)[memberName(member[2])];
            if (text === 'empty') return null;
            if (text === 'true') return true;
            if (text === 'false') return false;
            if (/^'.*'$/.test(text)) return text.slice(1, -1).replaceAll("''", "'");
            return text;
          };
          const conditionValue = (source, context, variables = {}) => {
            const text = (source || '').trim().replace(/^\((.*)\)$/, '$1');
            const orParts = text.split(/\s+or\s+/);
            if (orParts.length > 1) return orParts.some(part => conditionValue(part, context, variables));
            const andParts = text.split(/\s+and\s+/);
            if (andParts.length > 1) return andParts.every(part => conditionValue(part, context, variables));
            const comparison = text.match(/^(.*?)\s*(=|!=|>=|<=|>|<)\s*(.*?)$/);
            if (!comparison) return Boolean(expressionValue(text, context, variables));
            const left = expressionValue(comparison[1], context, variables);
            const right = expressionValue(comparison[3], context, variables);
            return ({
              '=': left === right, '!=': left !== right, '>': left > right,
              '<': left < right, '>=': left >= right, '<=': left <= right
            })[comparison[2]];
          };
          const nanoflowValue = (source, context, variables = {}) => {
            const text = (source || '').trim();
            if (/\s(?:and|or)\s|(?:=|!=|>=|<=|>|<)/.test(text)) {
              return conditionValue(text, context, variables);
            }
            return expressionValue(text, context, variables);
          };
          const isVisible = (source, context) => {
            return !source || conditionValue(source, context);
          };
          const dynamicClass = (source, context) => {
            let text = source || '';
            text = text.replace(/\(?if\s+(.+?)\s+then\s+'([^']*)'\s+else\s+'([^']*)'\)?/g,
              (_, condition, yes, no) => conditionValue(condition, context) ? yes : no);
            text = text.replace(/toString\(\$[A-Za-z_]\w*\/([A-Za-z_][\w.]*)\)/g,
              (_, member) => String(attributes(context)[memberName(member)] ?? ''));
            text = text.replace(/\$[A-Za-z_]\w*\/([A-Za-z_][\w.]*)/g,
              (_, member) => attributes(context)[memberName(member)] ?? '');
            return text.replace(/[+()']/g, ' ').replace(/\s+/g, ' ').trim();
          };
          const caption = (widget, options, context) => {
            let value = options.caption || widget.caption || widget.name;
            (options.parameters || []).forEach((parameter, index) => {
              value = value.replaceAll(`{${index + 1}}`, expressionValue(parameter, context) ?? '');
            });
            return value;
          };
          const inlineStyle = value => Object.fromEntries((value || '').split(';').filter(Boolean).map(rule => {
            const [property, ...parts] = rule.split(':');
            const name = property.trim().replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
            return [name, parts.join(':').trim()];
          }));

          const eventArguments = (event, context) => Object.fromEntries(
            Object.entries(event?.arguments || {}).map(([name, expression]) => [name, expressionValue(expression, context)])
          );

          const recordValue = (record, attribute) => attributes(record)[memberName(attribute)];
          const displayValue = value => {
            if (value == null) return '';
            if (Array.isArray(value)) return value.map(displayValue).join(', ');
            if (value?.attributes) return Object.values(value.attributes).find(item =>
              ['string', 'number', 'boolean'].includes(typeof item)) ?? value.id;
            if (typeof value === 'object') return value.id || JSON.stringify(value);
            return String(value);
          };

          const sortRecords = (records, sortings = []) => {
            const result = records.slice();
            sortings.slice().reverse().forEach(sorting => {
              const member = memberName(sorting.attribute);
              const direction = sorting.direction === 'Descending' ? -1 : 1;
              result.sort((left, right) => direction * String(
                left.attributes?.[member] ?? ''
              ).localeCompare(String(right.attributes?.[member] ?? ''), undefined, { numeric: true }));
            });
            return result;
          };

          const executeNanoflow = async (plan, parameters) => {
            if (!plan) throw new Error('Nanoflow frontend not found');
            const variables = structuredClone(parameters || {});
            const objects = Object.fromEntries(plan.objects.map(object => [object.id, object]));
            const outgoing = {};
            plan.flows.forEach(flow => { (outgoing[flow.origin] ||= []).push(flow); });
            let current = plan.objects.find(object => object.type === 'StartEvent');
            for (let step = 0; step < 10000; step += 1) {
              if (!current) throw new Error(`Nanoflow ${plan.name} points to a missing object`);
              if (current.type === 'EndEvent') {
                return { result: expressionValue(current.return, null, variables), variables };
              }
              if (current.type === 'ActionActivity') {
                const action = current.action || {};
                if (action.type === 'LogMessage') console.info(`[nanoflow] ${action.message || plan.name}`);
              else if (action.type === 'CreateVariable' || action.type === 'ChangeVariable') {
                variables[action.variable] = nanoflowValue(action.value, null, variables);
              } else if (action.type === 'Change') {
                  const object = variables[action.variable];
                  if (!object?.attributes) throw new Error(`Nanoflow object $${action.variable} is missing`);
                (action.changes || []).forEach(change => {
                  object.attributes[change.member] = nanoflowValue(change.value, object, variables);
                });
                } else throw new Error(`Unsupported frontend nanoflow action: ${action.type}`);
              }
              const edges = outgoing[current.id] || [];
              let edge = edges[0];
              if (current.type === 'ExclusiveSplit') {
                const value = String(conditionValue(current.condition, null, variables));
                edge = edges.find(item => item.case === value) || edges.find(item => !item.case);
              }
              if (!edge) throw new Error(`Nanoflow ${plan.name} stops at ${current.type}`);
              current = objects[edge.destination];
            }
            throw new Error(`Nanoflow ${plan.name} exceeded 10000 steps`);
          };

          function BoundField({ widget, record, schema, request, saveRecord, onChanged, onError }) {
            const options = widget.options || {};
            const member = memberName(options.attribute || widget.name);
            const kind = widget.type;
            const value = recordValue(record, member);
            const [draft, setDraft] = useState(kind === 'check_box' ? Boolean(value) : (value ?? ''));
            const [references, setReferences] = useState([]);
            const associations = (schema?.modules || []).flatMap(module => module.associations || []);
            const association = associations.find(item =>
              item.name === options.attribute || memberName(item.name) === member
            );
            const referenceEntity = options.entity || options.target_entity || association?.to_entity;
            const entityDefinition = (schema?.modules || []).flatMap(module =>
              [...(module.models || []), ...(module.dtos || [])]
            ).find(entity => entity.name === record?.type);
            const attributeDefinition = (entityDefinition?.attributes || []).find(attribute =>
              attribute.name === member
            );
            const enumeration = (schema?.modules || []).flatMap(module =>
              module.enumerations || []
            ).find(item => item.id === attributeDefinition?.enumeration
              || item.name === attributeDefinition?.enumeration);

            useEffect(() => {
              setDraft(kind === 'check_box' ? Boolean(value) : (value?.id || value || ''));
            }, [kind, record?.id, value?.id, value]);

            useEffect(() => {
              if (kind !== 'reference_selector' || !referenceEntity) return;
              request(`/api/entities/${encodeURIComponent(referenceEntity)}`)
                .then(payload => setReferences(payload.records || [])).catch(onError);
            }, [kind, referenceEntity, request, onError]);

            const persist = next => {
              setDraft(next);
              if (!record?.type || !record?.id || !member) return Promise.resolve(record);
              let normalized = next;
              if (kind === 'number_input') normalized = next === '' ? null : Number(next);
              if (kind === 'reference_selector') {
                normalized = references.find(item => item.id === next) || null;
              }
              return saveRecord(record, { [member]: normalized }).then(updated => {
                if (!updated) return null;
                if (onChanged) return onChanged(updated);
                return updated;
              });
            };
            const disabled = !record?.id || !member || options.read_only === true;

            if (kind === 'text_area') {
              return <textarea rows={options.lines || 4} value={draft} disabled={disabled}
                onChange={event => setDraft(event.target.value)} onBlur={() => persist(draft)} />;
            }
            if (kind === 'check_box') {
              return <input type="checkbox" checked={Boolean(draft)} disabled={disabled}
                onChange={event => persist(event.target.checked)} />;
            }
            if (kind === 'drop_down' || kind === 'reference_selector') {
              const enumValues = (enumeration?.values || []).map(item => ({
                id: item.name, label: item.caption || item.name
              }));
              const configuredValue = options.values || options.items || options.options || enumValues;
              const configured = Array.isArray(configuredValue) ? configuredValue : Object.values(configuredValue);
              const choices = kind === 'reference_selector' ? references : configured.map(item =>
                typeof item === 'object' ? item : { id: item, label: item }
              );
              return <select value={draft} disabled={disabled} onChange={event => persist(event.target.value)}>
                <option value="">—</option>
                {draft && !choices.some(item => (item.id || item.value) === draft) ?
                  <option value={draft}>{displayValue(value)}</option> : null}
                {choices.map(item => <option key={item.id || item.value} value={item.id || item.value}>
                  {displayValue(item.label || item.caption || recordValue(item, options.display_attribute)
                    || item.id || item.value)}
                </option>)}
              </select>;
            }
            const inputType = kind === 'date_picker' ? 'date' : kind === 'number_input' ? 'number' : 'text';
            const inputValue = inputType === 'date' ? String(draft).slice(0, 10) : draft;
            return <input type={inputType} value={inputValue} disabled={disabled}
              onChange={event => setDraft(event.target.value)} onBlur={() => persist(draft)} />;
          }

          function DataGrid({ widget, request, pageContext, revision, onError, onMutation,
                              onRowAction, onSelectRecord }) {
            const options = widget.options || {};
            const [records, setRecords] = useState([]);
            const [pageNumber, setPageNumber] = useState(0);
            const [reload, setReload] = useState(0);
            const [selected, setSelected] = useState(null);
            const [loading, setLoading] = useState(false);
            const pageSize = Math.max(1, Number(options.page_size || options.pageSize || 20));

            useEffect(() => {
              if (!options.entity) return;
              setLoading(true);
              request(entityCollectionPath(options.entity, options.association, pageContext)).then(payload => {
                let values = payload.records || [];
                values = sortRecords(values, options.sort || []);
                setRecords(values);
                setPageNumber(current => Math.min(current, Math.max(0, Math.ceil(values.length / pageSize) - 1)));
              }).catch(onError).finally(() => setLoading(false));
            }, [options.entity, options.association, pageContext?.type, pageContext?.id,
                pageSize, reload, revision, request, onError]);

            const mutate = operation => operation.then(result => {
              setReload(value => value + 1);
              onMutation();
              return result;
            }).catch(onError);
            const createRecord = () => mutate(request(`/api/entities/${encodeURIComponent(options.entity)}`, {
              method: 'POST', body: '{}'
            })).then(record => {
              setSelected(record);
              if (record) onSelectRecord(record);
            });
            const deleteRecord = () => selected && mutate(request(
              `/api/entities/${encodeURIComponent(options.entity)}/${encodeURIComponent(selected.id)}`,
              { method: 'DELETE' }
            )).then(() => { setSelected(null); onSelectRecord(null); });
            const toolbar = options.toolbar?.buttons || [];
            const pageCount = Math.max(1, Math.ceil(records.length / pageSize));
            const visible = records.slice(pageNumber * pageSize, (pageNumber + 1) * pageSize);

            return <div className={classes('mxrb-data-grid-runtime', loading && 'is-loading')}
              data-entity={options.entity || ''}>
              <div className="mxrb-grid-toolbar">
                {toolbar.some(button => button.type === 'new') ? <button type="button" onClick={createRecord}>New</button> : null}
                {toolbar.some(button => button.type === 'delete') ? <button type="button" disabled={!selected} onClick={deleteRecord}>Delete</button> : null}
                <button type="button" onClick={() => setReload(value => value + 1)}>Reload</button>
              </div>
              <table><thead><tr>{(options.columns || []).map(column =>
                <th key={column.name || column.attribute}>{column.caption || column.name}</th>)}</tr></thead>
                <tbody>{visible.map(record => <tr key={record.id}
                  className={selected?.id === record.id ? 'is-selected' : ''}
                  onClick={() => { setSelected(record); onSelectRecord(record); onRowAction(record); }}>
                  {(options.columns || []).map(column => <td key={column.name || column.attribute}>
                    {displayValue(recordValue(record, column.attribute || column.name))}
                  </td>)}
                </tr>)}</tbody></table>
              <div className="mxrb-grid-pagination">
                <button type="button" disabled={pageNumber === 0}
                  onClick={() => setPageNumber(value => value - 1)}>Previous</button>
                <span>Page {pageNumber + 1} of {pageCount} · {records.length} rows</span>
                <button type="button" disabled={pageNumber + 1 >= pageCount}
                  onClick={() => setPageNumber(value => value + 1)}>Next</button>
              </div>
            </div>;
          }

          function Gallery({ widget, moduleName, invoke, invokeNanoflow, navigate, pageContext, revision,
                             schema, request, saveRecord, onError, onMutation, onSelectRecord }) {
            const options = widget.options || {};
            const [records, setRecords] = useState([]);
            useEffect(() => {
              if (!options.entity) return;
              request(entityCollectionPath(options.entity, options.association, pageContext)).then(payload => {
                setRecords(sortRecords(payload.records || [], options.sort || []));
              }).catch(onError);
            }, [options.entity, options.association, pageContext?.type, pageContext?.id,
                revision, request, onError]);
            return <div className={classes('mxrb-widget', 'mxrb-gallery', options.class)}>
              <div className="mxrb-gallery-items gallery-items">
                {records.map(record => <div className="mxrb-gallery-item gallery-item" key={record.id}>
                  {(widget.children || []).map((child, index) => <Widget key={`${child.name}-${index}`}
                    widget={child} moduleName={moduleName} invoke={invoke} invokeNanoflow={invokeNanoflow}
                    navigate={navigate} context={record} schema={schema} request={request}
                    saveRecord={saveRecord} onError={onError} onMutation={onMutation}
                    onSelectRecord={onSelectRecord}
                    pageContext={pageContext} revision={revision} />)}
                </div>)}
              </div>
            </div>;
          }

          function Widget({ widget, moduleName, invoke, invokeNanoflow, navigate,
                            context, pageContext, revision, schema, request, saveRecord,
                            onError, onMutation, onSelectRecord }) {
            const options = widget.options || {};
            if (!isVisible(options.visible, context || pageContext)) return null;
            const className = classes('mxrb-widget', `mxrb-${widget.type}`, options.class,
              dynamicClass(options.dynamic_class, context || pageContext));
            const children = (widget.children || []).map((child, index) =>
              <Widget key={`${child.name}-${index}`} widget={child} moduleName={moduleName} invoke={invoke}
                invokeNanoflow={invokeNanoflow} navigate={navigate}
                context={context} pageContext={pageContext} revision={revision} schema={schema}
                request={request} saveRecord={saveRecord} onError={onError} onMutation={onMutation}
                onSelectRecord={onSelectRecord} />);
            const click = (widget.events || []).find(event => event.event === 'on_click');
            const change = (widget.events || []).find(event => event.event === 'on_change');
            const runEvent = (event, eventContext = context || pageContext) => {
              if (!event) return Promise.resolve();
              const handler = event.handler.includes('.') ? event.handler : `${moduleName}.${event.handler}`;
              const parameters = eventArguments(event, eventContext);
              if (event.kind === 'nanoflow') return invokeNanoflow(handler, parameters, eventContext);
              if (event.kind === 'page') {
                const targetContext = Object.values(parameters)[0] || pageContext || context || null;
                return navigate(handler, targetContext);
              }
              return invoke(handler, parameters, eventContext);
            };
            const onClick = click ? () => runEvent(click) : undefined;
            const onChanged = updated => runEvent(change, updated);

            switch (widget.type) {
              case 'container':
                return <div className={className} style={inlineStyle(options.style)} onClick={onClick}
                  role={onClick ? 'button' : undefined} tabIndex={onClick ? 0 : undefined}>
                  {children}
                </div>;
              case 'text':
                return <span className={className}>{caption(widget, options, context || pageContext)}</span>;
              case 'button':
                return <button type="button" className={className} onClick={onClick}>
                  {caption(widget, options, context || pageContext)}
                </button>;
              case 'text_area':
                return <label className={className}>{caption(widget, options, context || pageContext)}
                  <BoundField widget={widget} record={context || pageContext} schema={schema}
                    request={request} saveRecord={saveRecord} onChanged={onChanged} onError={onError} />
                </label>;
              case 'text_box':
              case 'number_input':
                return <label className={className}>{caption(widget, options, context || pageContext)}
                  <BoundField widget={widget} record={context || pageContext} schema={schema}
                    request={request} saveRecord={saveRecord} onChanged={onChanged} onError={onError} />
                </label>;
              case 'check_box':
                return <label className={className}>
                  <BoundField widget={widget} record={context || pageContext} schema={schema}
                    request={request} saveRecord={saveRecord} onChanged={onChanged} onError={onError} />
                  {caption(widget, options, context || pageContext)}
                </label>;
              case 'date_picker':
                return <label className={className}>{caption(widget, options, context || pageContext)}
                  <BoundField widget={widget} record={context || pageContext} schema={schema}
                    request={request} saveRecord={saveRecord} onChanged={onChanged} onError={onError} />
                </label>;
              case 'drop_down':
              case 'reference_selector':
                return <label className={className}>{caption(widget, options, context || pageContext)}
                  <BoundField widget={widget} record={context || pageContext} schema={schema}
                    request={request} saveRecord={saveRecord} onChanged={onChanged} onError={onError} />
                </label>;
              case 'tab_control':
                return <div className={className}>{(options.tabs || []).map(tab =>
                  <section key={tab.name}><h3>{tab.caption || tab.name}</h3>
                    {(tab.widgets || []).map((child, index) =>
                      <Widget key={`${child.name}-${index}`} widget={child} moduleName={moduleName} invoke={invoke}
                        invokeNanoflow={invokeNanoflow} navigate={navigate}
                        context={context} pageContext={pageContext} revision={revision} schema={schema}
                        request={request} saveRecord={saveRecord} onError={onError} onMutation={onMutation}
                        onSelectRecord={onSelectRecord} />)}
                  </section>)}</div>;
              case 'data_grid':
                return <div className={className}><DataGrid widget={widget} request={request}
                  pageContext={pageContext} revision={revision} onError={onError}
                  onMutation={onMutation} onSelectRecord={onSelectRecord}
                  onRowAction={record => runEvent(change || click, record)} />
                </div>;
              case 'gallery':
                return <Gallery widget={widget} moduleName={moduleName} invoke={invoke}
                  invokeNanoflow={invokeNanoflow} navigate={navigate}
                  pageContext={pageContext} revision={revision} schema={schema} request={request}
                  saveRecord={saveRecord} onError={onError} onMutation={onMutation}
                  onSelectRecord={onSelectRecord} />;
              case 'native_widget':
                return <div className={classes(className, 'mxrb-native-widget')} data-native-type={options.native_type || ''}>
                  {children}
                </div>;
              default:
                return <div className={className}>{children}</div>;
            }
          }

          function navigationItems(items, openPage) {
            return (items || []).map((item, index) => <li key={`${item.page || item.caption?.en_US}-${index}`}>
              {item.page ? <button type="button" onClick={() => openPage(item.page)}>
                {item.caption?.en_US || item.page}
              </button> : <span>{item.caption?.en_US || ''}</span>}
              {item.items?.length ? <ul>{navigationItems(item.items, openPage)}</ul> : null}
            </li>);
          }

          function Login({ onLogin, error, busy }) {
            const [username, setUsername] = useState('');
            const [password, setPassword] = useState('');
            const submit = event => {
              event.preventDefault();
              onLogin(username, password).finally(() => setPassword(''));
            };
            return <main className="mxrb-login">
              <form onSubmit={submit}>
                <h1>Sign in</h1>
                <label>Username<input autoComplete="username" value={username}
                  onChange={event => setUsername(event.target.value)} /></label>
                <label>Password<input type="password" autoComplete="current-password" value={password}
                  onChange={event => setPassword(event.target.value)} /></label>
                <button type="submit" disabled={busy || !username || !password}>Sign in</button>
                {error ? <p role="alert">{error.message}</p> : null}
              </form>
            </main>;
          }

          export default function App() {
            const [schema, setSchema] = useState(null);
            const [page, setPage] = useState(null);
            const [pageContext, setPageContext] = useState(null);
            const [error, setError] = useState(null);
            const [busy, setBusy] = useState(false);
            const invocationInFlight = useRef(false);
            const [revision, setRevision] = useState(0);
            const [token, setToken] = useState(() => localStorage.getItem(TOKEN_KEY));
            const [session, setSession] = useState(null);
            const [authRequired, setAuthRequired] = useState(false);

            const handleError = useCallback(failure => {
              if (failure?.status === 401) setAuthRequired(true);
              setError(failure);
            }, []);
            const request = useCallback((path, options = {}) => api(path, options, token), [token]);

            const openPage = (name, context = null, activeToken = token) =>
              api(`/api/pages/${encodeURIComponent(name)}`, {}, activeToken)
                .then(value => { setPage(value); setPageContext(context); setError(null); })
                .catch(handleError);

            const loadApplication = async (activeToken = token) => {
              try {
                if (activeToken) {
                  const currentSession = await api('/api/session', {}, activeToken);
                  setSession(currentSession);
                }
                const value = await api('/api/schema', {}, activeToken);
                setSchema(value);
                setAuthRequired(false);
                setError(null);
                const profile = value.navigation?.profiles?.find(item => item.kind === 'Responsive')
                  || value.navigation?.profiles?.[0];
                const fallback = value.modules.flatMap(module => module.pages)[0]?.name;
                await openPage(profile?.home_page || fallback, null, activeToken);
              } catch (failure) {
                if (failure?.status === 401) {
                  localStorage.removeItem(TOKEN_KEY);
                  setToken(null);
                  setSession(null);
                  setAuthRequired(true);
                }
                setError(failure);
              }
            };

            useEffect(() => {
              loadApplication(token);
            }, []);

            const login = async (username, password) => {
              setBusy(true);
              try {
                const authenticated = await api('/api/login', {
                  method: 'POST', body: JSON.stringify({ username, password })
                });
                localStorage.setItem(TOKEN_KEY, authenticated.token);
                setToken(authenticated.token);
                await loadApplication(authenticated.token);
              } catch (failure) {
                setError(failure);
              } finally {
                setBusy(false);
              }
            };

            const logout = async () => {
              try {
                await api('/api/logout', { method: 'POST' }, token);
              } catch (failure) {
                if (failure?.status !== 401) setError(failure);
              } finally {
                localStorage.removeItem(TOKEN_KEY);
                setToken(null);
                setSession(null);
                setSchema(null);
                setPage(null);
                setAuthRequired(true);
              }
            };

            const refreshPageContext = () => {
              if (!pageContext?.type || !pageContext?.id) return Promise.resolve();
              return request(
                `/api/entities/${encodeURIComponent(pageContext.type)}/${encodeURIComponent(pageContext.id)}`
              ).then(setPageContext).catch(handleError);
            };

            const saveRecord = useCallback((record, changes) => {
              if (!record?.type || !record?.id) return Promise.resolve(record);
              return request(`/api/entities/${encodeURIComponent(record.type)}/${encodeURIComponent(record.id)}`, {
                method: 'PATCH', body: JSON.stringify(changes)
              }).then(updated => {
                setPageContext(current => current?.id === updated.id ? updated : current);
                setRevision(value => value + 1);
                setError(null);
                return updated;
              }).catch(failure => {
                handleError(failure);
                return null;
              });
            }, [request, handleError]);

            const markMutation = useCallback(() => setRevision(value => value + 1), []);
            const selectRecord = useCallback(record => setPageContext(record), []);

            const invoke = (name, parameters = {}, contextOverride = null) => {
              if (invocationInFlight.current) return Promise.resolve(null);
              invocationInFlight.current = true;
              setBusy(true);
              const activeContext = pageContext || contextOverride;
              return request(`/api/microflows/${encodeURIComponent(name)}`, {
                method: 'POST', body: JSON.stringify({
                  ...parameters, ...(activeContext ? { __mxrb_context: activeContext } : {})
                })
                })
                  .then(payload => {
                    setRevision(value => value + 1);
                    if (payload.context) setPageContext(payload.context);
                    const navigation = (payload.effects || []).find(effect => effect.type === 'open_page');
                    if (navigation?.page) {
                      const context = Object.values(navigation.arguments || {})[0]
                        || payload.context || payload.result || null;
                      return openPage(navigation.page, context);
                    }
                    return payload.context ? payload : refreshPageContext().then(() => payload);
                  }).catch(handleError).finally(() => {
                    invocationInFlight.current = false;
                    setBusy(false);
                  });
            };

            const invokeNanoflow = async (name, parameters = {}, contextOverride = null) => {
              setBusy(true);
              try {
                const plan = nanoflows[name];
                const resolvedParameters = { ...parameters };
                const activeContext = contextOverride || pageContext;
                if (plan?.parameters?.length === 1 && !(plan.parameters[0] in resolvedParameters)
                    && activeContext) {
                  resolvedParameters[plan.parameters[0]] = activeContext;
                }
                const execution = await executeNanoflow(plan, resolvedParameters);
                const changedContext = Object.values(execution.variables).find(value =>
                  value?.id && value.id === activeContext?.id
                );
                if (changedContext) await saveRecord(changedContext, changedContext.attributes || {});
                setError(null);
                return execution.result;
              } catch (failure) {
                setError(failure);
                return null;
              } finally {
                setBusy(false);
              }
            };

            if (authRequired) return <Login onLogin={login} error={error} busy={busy} />;
            if (!schema || !page) return <main className="mxrb-loading">Loading application…</main>;
            const profile = schema.navigation?.profiles?.find(item => item.kind === 'Responsive')
              || schema.navigation?.profiles?.[0];
            const moduleName = page.name.split('.')[0];

            return <div className={classes('mxrb-app-shell', 'mx-page', page.appearance_class)} style={inlineStyle(page.appearance_style)}>
              {profile?.items?.length || session ? <nav className="mxrb-navigation region-sidebar">
                {profile?.items?.length ? <ul>{navigationItems(profile.items, openPage)}</ul> : null}
                {session ? <button type="button" onClick={logout}>Sign out</button> : null}
              </nav> : null}
              <main className="mxrb-page region-content mx-scrollcontainer-wrapper" aria-busy={busy}>
                {(page.widgets || []).map((widget, index) =>
                  <Widget key={`${widget.name}-${index}`} widget={widget} moduleName={moduleName} invoke={invoke}
                    invokeNanoflow={invokeNanoflow} navigate={openPage}
                    context={pageContext} pageContext={pageContext} revision={revision} schema={schema}
                    request={request} saveRecord={saveRecord} onError={handleError}
                    onMutation={markMutation} onSelectRecord={selectRecord} />)}
              </main>
              {error ? <aside className="mxrb-runtime-error" role="alert">
                <button type="button" onClick={() => setError(null)}>×</button>{error.message}
              </aside> : null}
            </div>;
          }
        JS
      end

      def frontend_css
        <<~CSS
          :root { font: 16px/1.5 system-ui, sans-serif; }
          * { box-sizing: border-box; }
          html, body, #root { min-height: 100%; margin: 0; }
          button, input, textarea, select { font: inherit; }
          .mxrb-app-shell { min-height: 100vh; }
          .mxrb-page { min-height: 100vh; }
          .mxrb-page[aria-busy='true'] { cursor: progress; pointer-events: none; }
          .mxrb-navigation { position: fixed; z-index: 20; right: 1rem; top: 1rem; }
          .mxrb-navigation ul { display: flex; gap: .5rem; margin: 0; padding: 0; list-style: none; }
          .mxrb-navigation button { border: 1px solid currentColor; border-radius: .4rem; background: transparent; color: inherit; cursor: pointer; }
          .mxrb-text { display: block; }
          .mxrb-runtime-error { position: fixed; z-index: 50; right: 1rem; bottom: 1rem; max-width: 34rem; padding: 1rem; border-radius: .5rem; background: #7f1d1d; color: white; box-shadow: 0 .5rem 2rem #0008; }
          .mxrb-runtime-error button { float: right; border: 0; background: transparent; color: inherit; cursor: pointer; }
          .mxrb-loading { display: grid; min-height: 100vh; place-items: center; }
          .mxrb-login { display: grid; min-height: 100vh; place-items: center; padding: 1rem; }
          .mxrb-login form { display: grid; width: min(24rem, 100%); gap: 1rem; padding: 2rem; border: 1px solid #d1d5db; border-radius: .75rem; }
          .mxrb-login label { display: grid; gap: .25rem; }
          .mxrb-grid-toolbar, .mxrb-grid-pagination { display: flex; align-items: center; gap: .5rem; margin-block: .5rem; }
          .mxrb-data-grid-runtime table { width: 100%; border-collapse: collapse; }
          .mxrb-data-grid-runtime th, .mxrb-data-grid-runtime td { padding: .5rem; border-bottom: 1px solid #d1d5db; text-align: left; }
          .mxrb-data-grid-runtime tbody tr { cursor: pointer; }
          .mxrb-data-grid-runtime tbody tr.is-selected { background: #dbeafe; }
          .mxrb-native-widget:empty { min-height: 1px; }
        CSS
      end

      def readme
        <<~MARKDOWN
          # #{@project.name}

          Executable Ruby application exported by MXRB.

          ## Run

          ```sh
          bundle install
          npm install --prefix frontend
          bundle exec mxrb run .
          ```

          `mxrb run` supervises the Ruby API and React + Vite development server
          together. Vite proxies `/api` to Ruby, so both processes behave as one
          application. Use `--server-port` for Ruby and `--client-port` for Vite;
          `--api-port` and `--port` remain compatibility aliases. Generated models,
          DTOs, services, and pages live under `app/`.
          Service bodies are ordinary Ruby; their default implementation delegates to
          MXRB's pure-Ruby interpreter.

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
