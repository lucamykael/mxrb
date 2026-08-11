# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'monitor'
require 'uri'
require 'webrick'
require_relative 'ruby_app/session_manager'

module Mxrb
  # Runtime and reversible metadata contract for projects exported with
  # `mxrb export --mode ruby`.
  module RubyApp
    # rubocop:disable Metrics
    MANIFEST_PATH = File.join('.mxrb', 'ruby-app.json')
    SOURCE_GLOBS = [
      'app/**/*.rb', 'config/**/*', 'frontend/**/*', 'spec/**/*.rb',
      'db/migrate/**/*', 'bin/**/*', '.rspec', 'config.ru',
      'Gemfile', 'Rakefile', 'README.md', '.gitignore', '.env.example'
    ].freeze
    SOURCE_EXCLUSIONS = %w[frontend/node_modules/ frontend/dist/].freeze
    ARTIFACT_DIRECTORIES = %w[models dtos services pages].freeze

    def self.application_files(root)
      ARTIFACT_DIRECTORIES.flat_map do |directory|
        Dir.glob(File.join(root, 'app', directory, '**', '*.rb'))
      end.sort
    end

    def self.source_bundle(root)
      expanded = File.expand_path(root)
      candidates = SOURCE_GLOBS.flat_map { Dir.glob(File.join(expanded, _1), File::FNM_DOTMATCH) }
                               .select { File.file?(_1) }
      files = candidates.filter_map do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(expanded)).cleanpath.to_s
        next if SOURCE_EXCLUSIONS.any? { relative.start_with?(_1) }

        contents = File.binread(path)
        {
          path: relative, contents:, sha256: Digest::SHA256.hexdigest(contents),
          mode: File.stat(path).mode & 0o777
        }
      end
      files.uniq { _1.fetch(:path) }.sort_by { _1.fetch(:path) }
    end

    def self.safe_source_path(root, relative)
      clean = Pathname.new(relative.to_s).cleanpath
      raise ValidationError, "unsafe embedded Ruby source path: #{relative}" \
        if clean.absolute? || clean.to_s == '..' || clean.to_s.start_with?('../')

      File.join(File.expand_path(root), clean.to_s)
    end

    def self.safe_source_mode(value, relative)
      fallback = relative.to_s.start_with?('bin/') ? 0o755 : 0o644
      mode = Integer(value || fallback)
      raise ValidationError, "unsafe embedded Ruby source mode: #{mode}" unless mode.between?(0, 0o777)

      mode
    end

    def self.compile(root, target = nil, mendix_version: nil)
      manifest = Manifest.load(root)
      destination = File.expand_path(
        target || ENV.fetch('MXRB_OUTPUT_PATH', File.join(root, 'build', manifest.mpr_name))
      )
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = destination
      load manifest.absolute_path('mendix_project')
      transition(destination, mendix_version) if mendix_version
      Synchronizer.new(root, destination, manifest:).synchronize!
      destination
    ensure
      if previous
        ENV['MXRB_OUTPUT_PATH'] = previous
      else
        ENV.delete('MXRB_OUTPUT_PATH')
      end
    end

    def self.transition(path, version)
      project = Model::Project.open(path, readonly: false)
      project.migrate_to!(version) unless project.mendix_version == version.to_s
    ensure
      project&.close
    end

    # Reads and validates paths before runtime or reverse compilation uses them.
    class Manifest
      attr_reader :root, :data

      def self.load(root)
        expanded = File.expand_path(root)
        path = File.join(expanded, MANIFEST_PATH)
        raise ArgumentError, "not an MXRB Ruby application: #{expanded}" unless File.file?(path)

        new(expanded, JSON.parse(File.read(path)))
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid MXRB Ruby application manifest: #{e.message}"
      end

      def initialize(root, data)
        @root = root
        @data = data
        raise ArgumentError, 'MXRB Ruby application manifest must use mode ruby' unless data['mode'] == 'ruby'
      end

      def mpr_name = data.fetch('source').fetch('name')
      def modules = data.fetch('modules')
      def coverage = data.fetch('coverage')

      def absolute_path(key)
        relative = data.fetch('round_trip').fetch(key)
        clean = Pathname.new(relative).cleanpath
        if clean.absolute? || clean.to_s.start_with?('../')
          raise ArgumentError,
                "unsafe Ruby application path: #{relative}"
        end

        File.join(root, clean.to_s)
      end
    end

    # Per-process registry populated by conventional app/**/*.rb files.
    module Registry
      ADAPTER_KINDS = %i[
        app_service web_service import_xml import_mapping export_mapping document
      ].freeze

      module_function

      def reset!
        @records = {}
        @services = {}
        @pages = {}
        @adapters = {}
        @java_custom_actions = {}
      end

      def register(kind, name, implementation)
        collection(kind)[name] = implementation
      end

      def fetch(kind, name) = collection(kind)[name]
      def all(kind) = collection(kind).dup.freeze

      def register_adapter(kind, implementation = nil, &block)
        key = kind.to_sym
        raise ArgumentError, "unsupported Ruby adapter #{kind}" unless ADAPTER_KINDS.include?(key)

        callback = implementation || block
        raise ArgumentError, 'adapter must respond to call' unless callback.respond_to?(:call)

        register(:adapter, key, callback)
        callback
      end

      def adapters = all(:adapter)

      def register_java_custom_action(name, implementation = nil, &block)
        qualified_name = name.to_s
        unless qualified_name.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)
          raise ArgumentError, "Java Custom Action name must be qualified as Module.Action: #{name}"
        end

        callback = implementation || block
        raise ArgumentError, 'Java Custom Action adapter must respond to call' unless callback.respond_to?(:call)

        register(:java_custom_action, qualified_name, callback)
        callback
      end

      def java_custom_actions = all(:java_custom_action)

      def collection(kind)
        reset! unless defined?(@records) && @records
        {
          record: @records, service: @services, page: @pages, adapter: @adapters,
          java_custom_action: @java_custom_actions
        }.fetch(kind)
      end
    end

    # Base for generated persistent models.
    class Record
      LIFECYCLE_EVENTS = Runtime::Native::Store::LIFECYCLE_EVENTS

      class << self
        attr_reader :mendix_id, :attributes, :persistable, :lifecycle_callbacks

        def inherited(child)
          super
          child.instance_variable_set(:@attributes, [])
          child.instance_variable_set(:@lifecycle_callbacks, {})
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = id.to_s
          Registry.register(:record, @mendix_name, self)
        end

        def persistence(value) = (@persistable = value == true)

        def attribute(name, type:, mendix_name:, required: false, default: nil)
          @attributes ||= []
          @attributes << {
            name: name.to_sym, type: type.to_sym,
            mendix_name: mendix_name.to_s, required: required == true,
            default: default
          }
          attr_accessor name
        end

        def lifecycle(event, method_name = nil, &block)
          event = event.to_sym
          raise ArgumentError, "unknown lifecycle event #{event}" unless LIFECYCLE_EVENTS.include?(event)
          raise ArgumentError, 'callback method or block is required' unless method_name || block

          @lifecycle_callbacks ||= {}
          (@lifecycle_callbacks[event] ||= []) << (method_name || block)
        end

        LIFECYCLE_EVENTS.each do |event|
          define_method(event) { |method_name = nil, &block| lifecycle(event, method_name, &block) }
        end

        def from_native(value)
          values = attributes.to_a.to_h do |attribute|
            [attribute.fetch(:name), value.members[attribute.fetch(:mendix_name)]]
          end
          new(id: value.id, **values).tap { _1.instance_variable_set(:@native_value, value) }
        end
      end

      attr_reader :id

      def initialize(id: nil, **values)
        @id = id
        values.each { public_send("#{_1}=", _2) if respond_to?("#{_1}=") }
      end

      def to_h
        values = self.class.attributes.to_a.to_h { [_1.fetch(:name), public_send(_1.fetch(:name))] }
        { id:, type: self.class.mendix_name, attributes: values }
      end

      def sync_to_native!
        return self unless @native_value

        self.class.attributes.to_a.each do |attribute|
          @native_value.members[attribute.fetch(:mendix_name)] = public_send(attribute.fetch(:name))
        end
        self
      end

      def run_lifecycle_callback(callback)
        callback.is_a?(Proc) ? callback.call(self) : public_send(callback)
      ensure
        sync_to_native!
      end
    end

    # Explicit non-persistent model. Its generated filename and class always
    # end in `_dto` / `Dto`, avoiding ambiguous `_2` fallbacks.
    class DTO < Record; end

    # Base for generated services. The default body executes through MXRB's
    # pure-Ruby native interpreter and can be replaced with idiomatic Ruby.
    class Service
      class << self
        attr_reader :mendix_id

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = id.to_s
          Registry.register(:service, @mendix_name, self)
        end
      end

      def initialize(application, context: nil)
        @application = application
        @context = context
      end

      def call(**arguments) = native_call(arguments)

      private

      def native_call(arguments)
        @application.native_call(self.class.mendix_name, arguments, context: @context)
      end
    end

    # Page metadata remains ordinary Ruby while the browser receives its JSON
    # projection from the integrated backend.
    class Page
      class << self
        attr_reader :mendix_id, :title, :widgets, :appearance_class,
                    :appearance_style, :data_source

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = id.to_s
          Registry.register(:page, @mendix_name, self)
        end

        def configure(title:, widgets: [], appearance_class: '', appearance_style: '', data_source: nil)
          @title = title.to_s
          @widgets = widgets.freeze
          @appearance_class = appearance_class.to_s
          @appearance_style = appearance_style.to_s
          @data_source = data_source
        end
      end
    end

    # Loads generated Ruby classes and provides one shared in-memory backend.
    class Application
      attr_reader :root, :manifest, :environment

      def initialize(root, environment: nil, process: ENV)
        @root = File.expand_path(root)
        @runtime_monitor = Monitor.new
        @manifest = Manifest.load(@root)
        @environment = if environment.is_a?(Environment)
                         environment
                       else
                         Environment.load(
                           environment, root: @root, process:
                         )
                       end
        Registry.reset!
        load_adapters
        load_application_files
      end

      def schema(context: nil)
        result = {
          mode: 'ruby', environment: environment.name, project: manifest.data.fetch('project'),
          navigation: manifest.data.fetch('navigation', {}),
          modules: manifest.modules, coverage: manifest.coverage
        }
        context ? secure_schema(result, context) : result
      end

      def call_service(name, arguments = {}, synchronized_context: nil, context: nil)
        runtime_synchronize do
          implementation = Registry.fetch(:service, name.to_s)
          raise NativeRuntimeError, "microflow #{name} not found" unless implementation || microflow_exists?(name)

          authorize_document!(:microflow, name, :execute, context)
          normalized = arguments.to_h.transform_values { deserialize(_1, context:) }
          synchronize_context(synchronized_context, context:) if synchronized_context
          next native_call(name, normalized, context:) unless implementation

          keyword_arguments = normalized.transform_keys(&:to_sym)
          implementation.new(self, context:).call(**keyword_arguments)
        end
      end

      def invoke_service(name, arguments = nil, context: nil, **keyword_arguments)
        runtime_synchronize do
          arguments = keyword_arguments if arguments.nil?
          bridge.interpreter.clear_effects!
          invocation_arguments = arguments.to_h.dup
          synchronized_context = invocation_arguments.delete('__mxrb_context')
          active_context = synchronize_context(synchronized_context, context:) if synchronized_context
          result = call_service(name, invocation_arguments, context:)
          {
            result: serialize(result, context:), effects: serialize(bridge.interpreter.effects, context:),
            context: serialize(active_context, context:)
          }
        ensure
          release_runtime_cache
        end
      end

      def rest_routes
        @rest_routes ||= manifest.modules.flat_map do |mod|
          mod.fetch('endpoints', []).flat_map do |endpoint|
            endpoint.fetch('operations', []).map do |operation|
              operation.merge(
                'service' => endpoint.fetch('name'),
                'enable_cors' => endpoint.fetch('enable_cors', false),
                'requires_authentication' => endpoint.fetch('requires_authentication', false)
              )
            end
          end
        end
      end

      def invoke_rest(route, path_parameters: {}, query: {}, body: nil, context: nil)
        service = service_manifest(route.fetch('microflow'))
        arguments = request_arguments(service, path_parameters, query, body, context:)
        invoke_service(route.fetch('microflow'), arguments, context:).fetch(:result)
      end

      def native_call(name, arguments = {}, context: nil)
        runtime_synchronize do
          authorize_document!(:microflow, name, :execute, context)
          serialize(
            bridge.interpreter.call(name.to_s, arguments.to_h.transform_keys(&:to_s), context:), context:
          )
        end
      end

      def records(name, context: nil, association: nil, context_type: nil, context_id: nil)
        runtime_synchronize do
          filter = [association, context_type, context_id]
          if filter.any? && !filter.all? { !_1.to_s.empty? }
            raise ArgumentError,
                  'association filter requires association, context_type, and context_id'
          end
          store = bridge.interpreter.store
          values = if filter.all? { !_1.to_s.empty? }
                     parent = store.find(context_type.to_s, context_id.to_s)
                     parent ? store.retrieve_association(association.to_s, parent) : []
                   else
                     store.retrieve(name.to_s)
                   end
          values = values.select { _1.entity == name.to_s }
          values = access_control.filter_readable(name.to_s, values, context:) if context
          values.map { serialize(_1, context:) }
        ensure
          release_runtime_cache
        end
      end

      def record(name, id, context: nil)
        runtime_synchronize do
          value = bridge.interpreter.store.find(name.to_s, id.to_s)
          next unless value
          next unless !context || access_control.entity_allowed?(name, action: :read, context:, record: value)

          serialize(value, context:)
        end
      end

      def create_record(name, attributes = nil, context: nil, **keyword_attributes)
        runtime_synchronize do
          attributes = keyword_attributes if attributes.nil?
          authorize_entity!(name, :create, context)
          bridge.interpreter.store.transaction do
            value = bridge.interpreter.store.create(name.to_s)
            attributes.to_h.each do |member, member_value|
              authorize_entity!(name, :write, context, member: member, record: value)
              value.members[member.to_s] = member_value
            end
            bridge.interpreter.store.commit(value)
            serialize(value, context:)
          end
        end
      end

      def delete_record(name, id, context: nil)
        runtime_synchronize do
          value = bridge.interpreter.store.find(name.to_s, id.to_s)
          next false unless value

          authorize_entity!(name, :delete, context, record: value)
          bridge.interpreter.store.delete(value)
          true
        end
      end

      def update_record(name, id, attributes, context: nil)
        runtime_synchronize do
          value = bridge.interpreter.store.find(name.to_s, id.to_s)
          next unless value

          authorize_entity!(name, :write, context, record: value)
          bridge.interpreter.store.transaction do
            attributes.to_h.each do |member, member_value|
              authorize_entity!(name, :write, context, member: member, record: value)
              value.members[member.to_s] = deserialize(member_value)
            end
            bridge.interpreter.store.commit(value)
            serialize(value, context:)
          end
        end
      end

      def page(name, context: nil)
        implementation = Registry.fetch(:page, name.to_s)
        return unless implementation

        authorize_document!(:page, name, :read, context)

        {
          name: implementation.mendix_name, id: implementation.mendix_id,
          title: implementation.title, widgets: implementation.widgets,
          appearance_class: implementation.appearance_class,
          appearance_style: implementation.appearance_style,
          data_source: implementation.data_source
        }
      end

      def access_control = (@access_control ||= bridge.access_control)

      def session_manager
        @session_manager ||= SessionManager.new(
          access_control, users: environment['MXRB_USERS_JSON'],
                          tokens: environment['MXRB_AUTH_TOKENS'],
                          ttl: environment.fetch('MXRB_SESSION_TTL', '3600'),
                          store: shared_store
        )
      end

      def start_scheduler = bridge.start_scheduler

      def close
        @bridge&.close
        @shared_store&.close
        @bridge = nil
        @access_control = nil
        @session_manager = nil
        @shared_store = nil
      end

      private

      def runtime_synchronize(&block)
        (@runtime_monitor ||= Monitor.new).synchronize(&block)
      end

      def microflow_exists?(name)
        bridge.project.modules.any? do |mod|
          mod.microflows.any? { "#{mod.name}.#{_1.name}" == name.to_s }
        end
      end

      def authorize_document!(kind, name, action, context)
        return unless context

        access_control.authorize!(name.to_s, kind:, action:, context:)
      end

      def authorize_entity!(name, action, context, member: nil, record: nil)
        return unless context

        access_control.authorize!(name.to_s, kind: :entity, action:, context:, member:, record:)
      end

      def secure_schema(schema, context)
        secured = Marshal.load(Marshal.dump(schema))
        allowed_pages = []
        allowed_services = []
        secured[:modules].each do |mod|
          mod['services'] = mod.fetch('services', []).select do |service|
            access_control.microflow_allowed?(service.fetch('name'), context:)
          end
          allowed_services.concat(mod['services'].flat_map { [_1['name'], _1['id']] }.compact)
          mod['pages'] = mod.fetch('pages', []).select do |page|
            access_control.page_allowed?(page.fetch('name'), context:)
          end
          allowed_pages.concat(mod['pages'].flat_map { [_1['name'], _1['id']] }.compact)
          %w[models dtos].each do |key|
            mod[key] = mod.fetch(key, []).select do |entity|
              access_control.entity_allowed?(entity.fetch('name'), action: :read, context:)
            end
          end
        end
        secured[:navigation] = secure_navigation(secured[:navigation], allowed_pages, allowed_services)
        secured
      end

      def secure_navigation(navigation, pages, services)
        result = navigation.to_h.transform_keys(&:to_sym)
        result[:profiles] = Array(result[:profiles]).map do |profile|
          profile = profile.to_h.transform_keys(&:to_sym)
          profile[:home_page] = nil unless pages.include?(profile[:home_page])
          profile[:sign_in_page] = nil unless pages.include?(profile[:sign_in_page])
          profile[:home_microflow] = nil unless services.include?(profile[:home_microflow])
          profile[:role_homes] = Array(profile[:role_homes]).select do |home|
            page = home[:page] || home['page']
            flow = home[:microflow] || home['microflow']
            (!page || pages.include?(page)) && (!flow || services.include?(flow))
          end
          profile[:items] = secure_navigation_items(profile[:items], pages, services)
          profile
        end
        result
      end

      def secure_navigation_items(items, pages, services)
        Array(items).filter_map do |item|
          item = item.to_h.transform_keys(&:to_sym)
          children = secure_navigation_items(item[:items], pages, services)
          allowed = (!item[:page] || pages.include?(item[:page])) &&
                    (!item[:microflow] || services.include?(item[:microflow]))
          next unless allowed || children.any?

          item.merge(items: children)
        end
      end

      def service_manifest(name)
        manifest.modules.flat_map { _1.fetch('services', []) }.find { _1.fetch('name') == name } ||
          raise(NativeRuntimeError, "REST microflow #{name} not found")
      end

      def request_arguments(service, path_parameters, query, body, context: nil)
        supplied = path_parameters.to_h.merge(query.to_h).transform_keys(&:to_s)
        supplied.merge!(body.transform_keys(&:to_s)) if body.is_a?(Hash)
        parameters = service.fetch('parameters', [])
        unresolved = parameters.reject { |parameter| request_value(supplied, parameter.fetch('name')).first }
        if body && unresolved.one? && !body_matches_parameters?(body, parameters)
          supplied[unresolved.first.fetch('name')] = body
        end
        parameters.to_h do |parameter|
          found, value = request_value(supplied, parameter.fetch('name'))
          if !found && parameter['required']
            raise NativeRuntimeError, "missing REST argument #{parameter.fetch('name')}"
          end

          [parameter.fetch('name'), deserialize_rest_value(value, parameter, context:)]
        end
      end

      def request_value(values, name)
        key = values.keys.find { _1.casecmp?(name.to_s) }
        [!key.nil?, key && values[key]]
      end

      def body_matches_parameters?(body, parameters)
        body.is_a?(Hash) && body.keys.any? do |key|
          parameters.any? { _1.fetch('name').casecmp?(key.to_s) }
        end
      end

      def deserialize_rest_value(value, parameter, context: nil)
        entity = parameter['entity']
        return deserialize(value) unless entity && value.is_a?(Hash) && !(value['id'] && value['type'])

        authorize_entity!(entity, :create, context)
        object = Runtime::Native::ObjectValue.new(entity:, id: SecureRandom.uuid, members: {})
        value.each do |member, member_value|
          authorize_entity!(entity, :write, context, member:, record: object)
          object.members[member.to_s] = deserialize(member_value, context:)
        end
        object
      end

      def load_application_files
        RubyApp.application_files(root).each { load _1, true }
      end

      def load_adapters
        path = File.join(root, 'config', 'adapters.rb')
        load path, true if File.file?(path)
      end

      def bridge
        @bridge ||= NativeBridge.new(
          manifest.absolute_path('runtime_mpr'),
          database: runtime_database_path,
          record_hooks: Registry.all(:record), adapters: Registry.adapters,
          java_custom_actions: Registry.java_custom_actions,
          allow_destructive: environment['MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS'].to_s.casecmp?('true'),
          coordinator: shared_store,
          scheduler_lease_ttl: environment.fetch('MXRB_SCHEDULER_LEASE_TTL', '300')
        )
      end

      def shared_store
        @shared_store ||= begin
          configured = environment['MXRB_SHARED_STORE_PATH'].to_s.strip
          if %w[:memory: memory local].include?(configured.downcase)
            Runtime::MemorySharedStore.new
          else
            path = configured.empty? ? default_shared_store_path : File.expand_path(configured, root)
            Runtime::SQLiteSharedStore.new(path)
          end
        end
      end

      def default_shared_store_path
        File.join(root, '.mxrb', 'runtime', "#{environment.name}-shared.sqlite3")
      end

      def runtime_database_path
        configured = environment['MXRB_DATABASE_PATH'].to_s
        return File.join(root, '.mxrb', 'runtime', "#{environment.name}.sqlite3") if configured.empty?

        File.expand_path(configured, root)
      end

      def serialize(value, seen = {}, context: nil)
        case value
        when Runtime::Native::ObjectValue
          key = [value.entity, value.id]
          return { id: value.id, type: value.entity } if seen[key]

          branch = seen.merge(key => true)
          members = value.members
          if context
            members = members.select do |member, _member_value|
              access_control.member_allowed?(
                value.entity, member, action: :read, context:, record: value
              )
            end
          end
          { id: value.id, type: value.entity, attributes: serialize(members, branch, context:) }
        when Hash then value.to_h { [serialize(_1, seen, context:), serialize(_2, seen, context:)] }
        when Array then value.map { serialize(_1, seen, context:) }
        else value
        end
      end

      def deserialize(value = nil, context: nil, synchronize: false, **keyword_value)
        value = keyword_value if value.nil? && !keyword_value.empty?
        if value.is_a?(Hash) && value['id'] && value['type']
          object = bridge.interpreter.store.find(value['type'].to_s, value['id'].to_s)
          raise NativeRuntimeError, "object #{value['type']} #{value['id']} not found" unless object

          value.fetch('attributes', {}).each do |member, member_value|
            next unless synchronize

            authorize_entity!(object.entity, :write, context, member:, record: object)
            object.members[member.to_s] = deserialize(member_value, context:, synchronize:)
          end
          object
        elsif value.is_a?(Hash)
          value.to_h do
            [deserialize(_1, context:, synchronize:), deserialize(_2, context:, synchronize:)]
          end
        elsif value.is_a?(Array)
          value.map { deserialize(_1, context:, synchronize:) }
        else
          value
        end
      end

      def synchronize_context(value, context:)
        store = bridge.interpreter.store
        object = deserialize(value, context:)
        return object unless object.is_a?(Runtime::Native::ObjectValue) && value.is_a?(Hash)

        changes = value.fetch('attributes', {}).filter_map do |member, member_value|
          resolved = deserialize(member_value, context:)
          [member.to_s, resolved] unless context_values_equal?(object.members[member.to_s], resolved)
        end
        return object if changes.empty?

        apply = lambda do
          changes.each do |member, member_value|
            authorize_entity!(object.entity, :write, context, member:, record: object)
            object.members[member] = member_value
          end
          store.commit(object) if store.respond_to?(:commit)
          object
        end
        return apply.call unless store.respond_to?(:transaction)

        store.transaction { apply.call }
      end

      def context_values_equal?(current, incoming)
        if current.is_a?(Runtime::Native::ObjectValue) || incoming.is_a?(Runtime::Native::ObjectValue)
          return current.is_a?(Runtime::Native::ObjectValue) &&
                 incoming.is_a?(Runtime::Native::ObjectValue) &&
                 current.entity == incoming.entity && current.id == incoming.id
        end
        if current.is_a?(Array) || incoming.is_a?(Array)
          return false unless current.is_a?(Array) && incoming.is_a?(Array) && current.size == incoming.size

          return current.zip(incoming).all? { context_values_equal?(_1, _2) }
        end
        if current.respond_to?(:iso8601) && incoming.is_a?(String)
          return Time.parse(incoming).to_i == Time.parse(current.iso8601).to_i
        end

        current == incoming
      rescue ArgumentError
        false
      end

      def release_runtime_cache
        store = bridge.interpreter.store
        store.release_cache! if store.respond_to?(:release_cache!)
      end
    end

    # Owns the source MPR and its pure-Ruby interpreter for one application.
    class NativeBridge
      attr_reader :access_control, :interpreter, :project, :scheduler, :store

      def initialize(path, database:, record_hooks: {}, adapters: {}, java_custom_actions: {},
                     allow_destructive: false, coordinator: nil, scheduler_lease_ttl: 300)
        FileUtils.mkdir_p(File.dirname(database))
        @project = Model::Project.open(path)
        @store = Runtime::SQLiteStore.new(@project, path: database, allow_destructive:)
        @access_control = Runtime::AccessControl.new(@project)
        @interpreter = Runtime::Native::Interpreter.new(
          @project, store: @store, policy: @access_control, adapters:, java_custom_actions:
        )
        register_record_hooks(record_hooks)
        @scheduler = Runtime::Scheduler.new(
          @project,
          executor: ->(name, **_metadata) { @interpreter.call(name) }, coordinator:,
          lease_ttl: scheduler_lease_ttl
        )
      rescue StandardError
        close
        raise
      end

      def start_scheduler
        scheduler.start unless scheduler.jobs.empty?
        scheduler
      end

      def close
        scheduler&.shutdown
        store&.close
        project&.close
      end

      private

      def register_record_hooks(records)
        records.each do |entity, implementation|
          implementation.lifecycle_callbacks.to_h.each do |event, callbacks|
            callbacks.each do |callback|
              store.on(entity, event) do |value|
                implementation.from_native(value).run_lifecycle_callback(callback)
              end
            end
          end
        end
      end
    end

    # Applies the reversible Ruby domain contract to a generated MPR. Anything
    # outside this contract remains in the native sidecar and is never dropped.
    class Synchronizer
      def initialize(root, target, manifest: Manifest.load(root))
        @root = File.expand_path(root)
        @target = File.expand_path(target)
        @manifest = manifest
      end

      def synchronize!
        Registry.reset!
        RubyApp.application_files(@root).each { load _1, true }
        project = Model::Project.open(@target, readonly: false)
        synchronize_entities(project)
        project.close
        project = nil
        embed_sources!
        @target
      ensure
        project&.close
      end

      private

      def embed_sources!
        files = RubyApp.source_bundle(@root)
        mpr = IO::MprFile.open(@target, readonly: false)
        mpr.transaction { mpr.write_ruby_app_sources(files) }
      ensure
        mpr&.close
      end

      def synchronize_entities(project)
        source_entities = @manifest.modules.flat_map do |mod|
          mod.fetch('models') + mod.fetch('dtos')
        end
        source_names = source_entities.map { _1.fetch('name') }
        registered = Registry.all(:record)

        (source_names - registered.keys).each do |name|
          plan = project.plan_remove_entity(name)
          raise ValidationError, plan.changes.join('; ') unless plan.safe?

          plan.apply!
        end
        (registered.keys - source_names).each { add_entity(project, _1, registered.fetch(_1)) }
        (source_names & registered.keys).each { synchronize_entity(project, _1, registered.fetch(_1)) }
      end

      def add_entity(project, name, implementation)
        module_name, entity_name = qualified_parts(name)
        attributes = implementation.attributes.to_a.map do |attribute|
          reject_unsupported_required!(name, attribute)
          {
            name: attribute.fetch(:mendix_name), type: attribute.fetch(:type),
            default: attribute[:default]
          }
        end
        project.plan_add_entity(
          module_name, name: entity_name, attributes:,
                       non_persistent: implementation.persistable == false
        ).apply!
      end

      def synchronize_entity(project, name, implementation)
        artifact = project.find_artifact(name, kind: :entity)
        raise ValidationError, "entity #{name} is missing from generated MPR" unless artifact

        model = artifact.metadata.fetch(:model)
        expected_persistence = implementation.persistable != false
        if model.persistable != expected_persistence
          raise ValidationError,
                "changing persistence for #{name} is outside the reversible Ruby contract"
        end
        synchronize_attributes(project, name, model, implementation.attributes.to_a)
      end

      def synchronize_attributes(project, entity_name, entity, declarations)
        declared = declarations.to_h { [_1.fetch(:mendix_name), _1] }
        existing = entity.attributes.to_h { [_1.name, _1] }
        (existing.keys - declared.keys).each do |name|
          plan = project.plan_remove_attribute("#{entity_name}/#{name}")
          raise ValidationError, plan.changes.join('; ') unless plan.safe?

          plan.apply!
        end
        (declared.keys - existing.keys).each do |name|
          declaration = declared.fetch(name)
          reject_unsupported_required!(entity_name, declaration)
          project.plan_add_attribute(
            entity_name, name:, type: declaration.fetch(:type),
                         default: declaration[:default]
          ).apply!
        end
        (declared.keys & existing.keys).each do |name|
          synchronize_attribute(project, entity_name, existing.fetch(name), declared.fetch(name))
        end
      end

      def synchronize_attribute(project, entity_name, attribute, declaration)
        if (attribute.required == true) != declaration.fetch(:required)
          raise ValidationError,
                "changing required for #{entity_name}/#{attribute.name} is outside the reversible Ruby contract"
        end
        updates = {}
        declared_type = declaration.fetch(:type).to_sym
        updates[:type] = declared_type if attribute.type != declared_type
        current_default = attribute.default_value.to_s
        declared_default = declaration[:default].to_s
        updates[:default] = declaration[:default] if current_default != declared_default
        return if updates.empty?

        project.plan_change_attribute("#{entity_name}/#{attribute.name}", **updates).apply!
      end

      def reject_unsupported_required!(entity_name, declaration)
        return unless declaration.fetch(:required)

        raise ValidationError,
              "adding required attribute #{entity_name}/#{declaration.fetch(:mendix_name)} " \
              'is outside the reversible Ruby contract'
      end

      def qualified_parts(name)
        parts = name.to_s.split('.', 2)
        raise ValidationError, "Ruby model name must be Module.Entity: #{name}" unless parts.size == 2

        parts
      end
    end

    # Loopback HTTP server for the generated backend and browser frontend.
    class Server
      MAX_BODY_BYTES = 1_048_576
      LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

      attr_reader :host, :port, :application

      def initialize(root, host: '127.0.0.1', port: 9292, logger: nil, environment: nil)
        @host = host.to_s
        raise ArgumentError, 'the Ruby application server must bind to loopback' unless LOOPBACK_HOSTS.include?(@host)

        @port = Integer(port)
        @application = Application.new(root, environment:)
        @sessions = @application.session_manager
        @logger = logger || WEBrick::Log.new(File::NULL)
      end

      def start
        @server = WEBrick::HTTPServer.new(
          BindAddress: host, Port: port, Logger: @logger, AccessLog: []
        )
        @server.mount_proc('/') { dispatch(_1, _2) }
        application.start_scheduler
        yield(@server) if block_given?
        @server.start
      ensure
        application.close
      end

      def shutdown = @server&.shutdown

      private

      def dispatch(request, response)
        path = request.path
        method = request.request_method
        if method == 'GET' && path == '/api/health'
          return render_json(
            response, 200, ok: true, project: application.schema[:project],
                           environment: application.environment.name
          )
        end

        if method == 'POST' && path == '/api/login'
          credentials = request_json(request)
          session = @sessions.login(credentials['username'], credentials['password'])
          return render_json(response, 200, { ok: true }.merge(session))
        end

        context = @sessions.authenticate(request['Authorization'])
        if method == 'GET' && path == '/api/session'
          return render_json(
            response, 200,
            user: context.user, roles: context.user_roles, module_roles: context.module_roles
          )
        end
        if method == 'POST' && path == '/api/logout'
          return render_json(response, 200, ok: @sessions.logout(request['Authorization']))
        end
        return render_json(response, 200, application.schema(context:)) if method == 'GET' && path == '/api/schema'
        return render_json(response, 200, application.schema(context:)[:navigation]) \
          if method == 'GET' && path == '/api/navigation'
        if method == 'GET' && path == '/api/pages'
          return render_json(
            response, 200,
            pages: application.schema(context:)[:modules].flat_map { _1.fetch('pages') }
          )
        end

        if (name = route_name(path, '/api/pages/')) && method == 'GET'
          page = application.page(name, context:)
          return render_json(response, page ? 200 : 404, page || error('not_found', "page #{name} not found"))
        end
        if (name = route_name(path, '/api/microflows/')) && method == 'POST'
          invocation = application.invoke_service(name, request_json(request), context:)
          return render_json(response, 200, { ok: true }.merge(invocation))
        end

        if (tail = route_name(path, '/api/entities/'))
          name, id = tail.split('/', 2)
          if method == 'GET' && id.nil?
            query = request.query.to_h
            records = application.records(
              name, context:,
                    association: query['association'],
                    context_type: query['context_type'],
                    context_id: query['context_id']
            )
            return render_json(response, 200, records:)
          end

          if method == 'GET' && id
            record = application.record(name, id, context:)
            return render_json(
              response, record ? 200 : 404,
              record || error('not_found', "#{name} #{id} not found")
            )
          end
          return render_json(response, 201, application.create_record(name, request_json(request), context:)) \
            if method == 'POST' && id.nil?

          if %w[PUT PATCH].include?(method) && id
            record = application.update_record(name, id, request_json(request), context:)
            return render_json(
              response, record ? 200 : 404,
              record || error('not_found', "#{name} #{id} not found")
            )
          end

          if method == 'DELETE' && id
            deleted = application.delete_record(name, id, context:)
            return render_json(response, deleted ? 200 : 404, ok: deleted)
          end
        end

        if (match = rest_route(method, path))
          route, path_parameters = match
          return render_json(response, 401, error('unauthorized', 'Authorization header required')) \
            if route['requires_authentication'] && request['Authorization'].to_s.empty?

          body = request.body.to_s.empty? ? nil : request_json(request)
          result = application.invoke_rest(
            route, path_parameters:, query: request.query.to_h, body:, context:
          )
          cors(response) if route['enable_cors']
          status = Integer(route.fetch('success_status', 200))
          if status == 204
            response.status = status
            response.body = ''
            return
          end
          return render_json(response, status, result)
        end

        if method == 'OPTIONS' && application.rest_routes.any? { path_match(_1.fetch('path'), path) }
          cors(response)
          response.status = 204
          return
        end

        return render_static(request, response) if method == 'GET' && !path.start_with?('/api/')

        render_json(response, 404, error('not_found', "route #{method} #{path} not found"))
      rescue JSON::ParserError, ArgumentError => e
        render_json(response, 400, error('invalid_request', e.message))
      rescue AuthenticationError => e
        render_json(response, 401, error('unauthorized', e.message))
      rescue Runtime::AuthorizationError => e
        render_json(response, 403, error('forbidden', e.message))
      rescue NativeRuntimeError => e
        render_json(response, 422, error('runtime_error', e.message))
      end

      def rest_route(method, path)
        application.rest_routes.each do |route|
          next unless route.fetch('method') == method

          match = path_match(route.fetch('path'), path)
          return [route, match.named_captures] if match
        end
        nil
      end

      def path_match(template, path)
        names = []
        pattern = Regexp.escape(template).gsub(/\\\{([A-Za-z_]\w*)\\\}/) do
          names << Regexp.last_match(1)
          '([^/]+)'
        end
        match = %r{\A#{pattern}/?\z}.match(path)
        return unless match

        values = names.zip(match.captures.map { URI.decode_www_form_component(_1) }).to_h
        Struct.new(:named_captures).new(values)
      end

      def cors(response)
        response['Access-Control-Allow-Origin'] = '*'
        response['Access-Control-Allow-Headers'] = 'Authorization, Content-Type'
        response['Access-Control-Allow-Methods'] = 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
      end

      def route_name(path, prefix)
        return unless path.start_with?(prefix)

        URI.decode_www_form_component(path.delete_prefix(prefix))
      end

      def request_json(request)
        body = request.body.to_s
        raise ArgumentError, 'request body exceeds 1 MiB' if body.bytesize > MAX_BODY_BYTES
        return {} if body.empty?

        JSON.parse(body).tap do |payload|
          raise ArgumentError, 'JSON body must be an object' unless payload.is_a?(Hash)
        end
      end

      def render_static(request, response)
        relative = request.path == '/' ? 'index.html' : request.path.delete_prefix('/')
        clean = Pathname.new(relative).cleanpath
        return render_json(response, 404, error('not_found', 'asset not found')) \
          if clean.absolute? || clean.to_s.start_with?('../')

        public_root = File.join(application.root, 'frontend', 'dist')
        path = File.join(public_root, clean.to_s)
        path = File.join(public_root, 'index.html') unless File.file?(path)
        response.status = File.file?(path) ? 200 : 404
        response['Content-Type'] = content_type(path)
        response.body = File.file?(path) ? File.binread(path) : 'Not found'
      end

      def content_type(path)
        case File.extname(path)
        when '.html' then 'text/html; charset=utf-8'
        when '.js' then 'text/javascript; charset=utf-8'
        when '.css' then 'text/css; charset=utf-8'
        when '.json' then 'application/json; charset=utf-8'
        else 'application/octet-stream'
        end
      end

      def error(code, message) = { ok: false, error: { code:, message: } }

      def render_json(response, status, payload)
        response.status = status
        response['Content-Type'] = 'application/json; charset=utf-8'
        response.body = JSON.generate(payload)
      end
    end

    # Exposes the same generic MXRB backend through the Rack protocol. Puma,
    # Sinatra and Rails presets mount this adapter instead of duplicating API
    # behavior or introducing a second application state.
    class RackAdapter
      Request = Struct.new(:path, :request_method, :body, :query, :headers) do
        def [](name) = headers[name]
      end

      # Minimal mutable response consumed by Server#dispatch.
      class Response
        attr_accessor :status, :body
        attr_reader :headers

        def initialize
          @status = 200
          @body = ''
          @headers = {}
        end

        def [](name) = headers[name]

        def []=(name, value)
          headers[name] = value
        end
      end

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root)
        @server_mutex = Mutex.new
      end

      def server
        @server || @server_mutex.synchronize { @server ||= Server.new(root, port: 0) }
      end

      def call(environment)
        request = rack_request(environment)
        response = Response.new
        server.send(:dispatch, request, response)
        [response.status, response.headers, [response.body.to_s]]
      end

      def close = @server&.application&.close

      private

      def rack_request(environment)
        input = environment['rack.input']
        body = input ? input.read.to_s : ''
        input.rewind if input.respond_to?(:rewind)
        query = URI.decode_www_form(environment['QUERY_STRING'].to_s).to_h
        headers = { 'Authorization' => environment['HTTP_AUTHORIZATION'].to_s }
        path = "#{environment['SCRIPT_NAME']}#{environment.fetch('PATH_INFO', '/')}"
        Request.new(
          path, environment.fetch('REQUEST_METHOD', 'GET'),
          body, query, headers
        )
      end
    end

    # Starts the Ruby API and Vite dev server as one supervised command.
    class Supervisor
      attr_reader :root, :host, :api_port, :frontend_port

      def initialize(root, host: '127.0.0.1', api_port: 9292, frontend_port: 5173,
                     npm: ENV.fetch('MXRB_NPM', 'npm'), frontend: true, environment: nil)
        @root = File.expand_path(root)
        @host = host.to_s
        @api_port = Integer(api_port)
        @frontend_port = Integer(frontend_port)
        @npm = npm.to_s
        @frontend = frontend
        @environment = if environment.is_a?(Environment)
                         environment
                       else
                         Environment.load(
                           environment, root: @root
                         )
                       end
      end

      def start
        if external_backend?
          @backend_pid = spawn_backend
        else
          @server = Server.new(root, host:, port: api_port, environment: @environment)
          @backend = Thread.new { @server.start }
        end
        @frontend_pid = spawn_frontend if @frontend
        yield(self) if block_given?
        if @frontend_pid
          Process.wait(@frontend_pid)
        elsif @backend_pid
          Process.wait(@backend_pid)
        else
          @backend.join
        end
      rescue Interrupt, Errno::ECHILD
        nil
      ensure
        shutdown
      end

      def shutdown
        @server&.shutdown
        terminate(@frontend_pid)
        terminate(@backend_pid)
        @backend&.join(2)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      private

      def external_backend?
        %w[flymetothemoon onrails].include?(
          Manifest.load(root).data.dig('ruby_stack', 'preset')
        )
      end

      def spawn_backend
        Process.spawn(
          profile_environment.merge('HOST' => host, 'MXRB_SERVER_PORT' => api_port.to_s),
          'bundle', 'exec', 'puma', '-C', 'config/puma.rb', chdir: root
        )
      end

      def terminate(pid)
        return unless pid

        Process.kill('TERM', pid)
        Process.wait(pid)
      end

      def spawn_frontend
        directory = File.join(root, 'frontend')
        package = File.join(directory, 'package.json')
        raise ArgumentError, "frontend package not found: #{directory}" unless File.file?(package)
        unless File.directory?(File.join(directory, 'node_modules'))
          raise ArgumentError, "frontend dependencies missing; run `#{@npm} install --prefix frontend`"
        end

        frontend_environment = profile_environment.select { _1.start_with?('VITE_') }
        frontend_environment['MXRB_ENV'] = @environment.name
        frontend_environment['MXRB_API_PORT'] = api_port.to_s
        Process.spawn(
          frontend_environment, @npm, 'run', 'dev', '--',
          '--host', host, '--port', frontend_port.to_s, chdir: directory
        )
      end

      def profile_environment
        @environment.to_h.reject { |key, value| ENV[key] == value }
                    .merge('MXRB_ENV' => @environment.name)
      end
    end
    # rubocop:enable Metrics
  end
end
