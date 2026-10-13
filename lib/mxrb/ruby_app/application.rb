# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Loads generated Ruby classes and provides one shared in-memory backend.
    class Application
      THEME_PLATFORM = %w[frontend src generated platform].freeze

      attr_reader :root, :manifest, :environment, :reload_status

      def initialize(root, environment: nil, process: ENV, reload: nil)
        @root = File.expand_path(root)
        @runtime_monitor = Monitor.new
        @async_invocations_mutex = Mutex.new
        @manifest = Manifest.load(@root)
        @environment = if environment.is_a?(Environment)
                         environment
                       else
                         Environment.load(
                           environment, root: @root, process:
                         )
                       end
        @reload_enabled = if reload.nil?
                            process['MXRB_RELOAD'].to_s.match?(/\A(?:1|true|yes)\z/i)
                          else
                            reload == true
                          end
        Registry.reset!
        load_adapters
        load_application_files
        @source_reloader = SourceReloader.new(@root)
        @reload_status = { enabled: @reload_enabled, state: 'ready', error: nil }.freeze
      end

      def reload_if_changed!
        return false unless @reload_enabled

        runtime_synchronize do
          revision = @source_reloader.changed_revision
          next false unless revision

          reload_sources!(revision)
        end
      end

      def schema(context: nil)
        result = {
          mode: 'ruby', environment: environment.name, project: manifest.data.fetch('project'),
          languages: manifest.data.fetch('languages', {}),
          navigation: manifest.data.fetch('navigation', {}),
          presentation: design_classed_presentation,
          modules: runtime_schema_modules, coverage: manifest.coverage,
          constants: Registry.all(:constant).values.select { _1.exposed_to_client && !_1.excluded }
                             .to_h { [_1.mendix_name, _1.client_value] },
          module_roles: context&.module_roles || []
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
          staged = invocation_arguments.delete('__mxrb_changes') || []
          raise ArgumentError, 'staged changes must be a list of objects' unless
            staged.is_a?(Array) && staged.all?(Hash)

          bridge.interpreter.store.transaction do
            active_context = synchronize_context(synchronized_context, context:) if synchronized_context
            staged.each { synchronize_context(_1, context:) }
            implicit_context_argument(name, invocation_arguments, active_context, synchronized_context)
            result = call_service(name, invocation_arguments, context:)
            {
              result: serialize(result, context:), effects: serialize(bridge.interpreter.effects, context:),
              context: serialize(active_context, context:)
            }
          end
        ensure
          release_runtime_cache
        end
      end

      # Uncommitted objects the context reaches (through non-persistent objects)
      # are the instances the call works on: a staged change to one of them
      # resumes that instance, not a copy from its draft snapshot.
      def stage_reachable_drafts(root, context:)
        store = bridge.interpreter.store
        return unless store.respond_to?(:resume_draft)

        owner = draft_owner(context)
        pending = [root]
        seen = {}
        until pending.empty?
          value = pending.pop
          next unless value.is_a?(Runtime::Native::ObjectValue) && !seen[[value.entity, value.id]]

          seen[[value.entity, value.id]] = true
          if store.find(value.entity, value.id).nil? && store.client_drafts.registered?(value, owner:)
            store.resume_draft(value)
          elsif !value.equal?(root) && !store.transient_entity?(value.entity)
            next
          end
          value.members.each_value { pending.concat(Array(_1)) }
        end
      end
      private :stage_reachable_drafts

      # A page action without parameter mappings passes the object of its data
      # view to the one unmapped parameter of a compatible entity.
      def implicit_context_argument(name, arguments, object, reference)
        return unless object.is_a?(Runtime::Native::ObjectValue)

        service = manifest.modules.flat_map { _1.fetch('services', []) }.find { _1['name'] == name.to_s }
        schema = bridge.interpreter.store.schema
        candidates = Array(service&.fetch('parameters', nil)).select do |parameter|
          entity = parameter['entity'].to_s
          !arguments.key?(parameter['name']) && !entity.empty? && schema.assignable?(object.entity, entity)
        end
        arguments[candidates.first.fetch('name')] = reference if candidates.one?
      end
      private :implicit_context_argument

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
          service = Registry.fetch(:service, name.to_s)
          kind = service&.native_kind == :nanoflow ? :nanoflow : :microflow
          authorize_document!(kind, name, :execute, context)
          serialize(
            bridge.interpreter.call(name.to_s, arguments.to_h.transform_keys(&:to_s), context:), context:
          )
        end
      end

      def records(name, context: nil, association: nil, context_type: nil, context_id: nil,
                  filters: [], sort: [], offset: 0, limit: nil,
                  xpath: nil, xpath_context_type: nil, xpath_context_id: nil, xpath_variables: {})
        record_page(
          name, context:, association:, context_type:, context_id:, filters:, sort:, offset:, limit:,
                xpath:, xpath_context_type:, xpath_context_id:, xpath_variables:
        ).fetch(:records)
      end

      def record_page(name, context: nil, association: nil, context_type: nil, context_id: nil,
                      filters: [], sort: [], offset: 0, limit: nil,
                      xpath: nil, xpath_context_type: nil, xpath_context_id: nil, xpath_variables: {})
        runtime_synchronize do
          filter = [association, context_type, context_id]
          if filter.any? && !filter.all? { !_1.to_s.empty? }
            raise ArgumentError,
                  'association filter requires association, context_type, and context_id'
          end
          store = bridge.interpreter.store
          values = if filter.all? { !_1.to_s.empty? }
                     parent = store.find(context_type.to_s, context_id.to_s)
                     if parent
                       authorize_entity!(parent.entity, :read, context, record: parent)
                       authorize_entity!(parent.entity, :read, context, member: association.to_s.split('.').last,
                                                                        record: parent)
                     end
                     parent ? store.retrieve_association(association.to_s, parent) : []
                   else
                     store.retrieve(name.to_s)
                   end
          values = values.select do |value|
            value.entity == name.to_s || (store.respond_to?(:schema) && store.schema.assignable?(value.entity,
                                                                                                 name.to_s))
          end
          if context
            values = values.select do |value|
              access_control.entity_allowed?(value.entity, action: :read, context:, record: value)
            end
          end
          unless xpath.nil?
            current = nil
            if xpath_context_type || xpath_context_id
              raise ArgumentError, 'XPath context requires type and id' if
                xpath_context_type.to_s.empty? || xpath_context_id.to_s.empty?

              current = store.find(xpath_context_type, xpath_context_id)
              raise ArgumentError, 'XPath context object not found' unless current

              authorize_entity!(current.entity, :read, context, record: current)
            end
            constraint = Runtime::XPath.new(xpath, store:, policy: context && access_control, context:)
            variables = xpath_variable_values(xpath_variables, store, context)
            values = constraint.filter(values, variables.merge('currentObject' => current))
          end
          values = values.select { grid_record_matches?(_1, filters) }
          values = grid_sort_records(values, sort)
          total = values.length
          normalized_offset = Integer(offset || 0)
          normalized_limit = limit.nil? || limit.to_s.empty? ? nil : Integer(limit)
          raise ArgumentError, 'record offset must be non-negative' if normalized_offset.negative?
          raise ArgumentError, 'record limit must be positive' if normalized_limit && !normalized_limit.positive?

          values = values.drop(normalized_offset)
          values = values.first(normalized_limit) if normalized_limit
          { records: values.map { serialize(_1, context:) }, total: }
        ensure
          release_runtime_cache
        end
      end

      # Nanoflow XPath variables: objects as {type, id} (read-authorized), tagged decimals and scalars.
      def xpath_variable_values(values, store, context)
        raise ArgumentError, 'XPath variables must be an object' unless values.is_a?(Hash)

        values.to_h do |name, value|
          next [name.to_s, Runtime::DecimalValues.parse(value.fetch(Runtime::DecimalValues::TAG))] if
            Runtime::DecimalValues.tagged?(value)
          next [name.to_s, value] unless value.is_a?(Hash)

          object = store.find(value['type'].to_s, value['id'].to_s)
          raise ArgumentError, "XPath variable $#{name} object not found" unless object

          authorize_entity!(object.entity, :read, context, record: object)
          [name.to_s, object]
        end
      end
      private :xpath_variable_values

      def record(name, id, context: nil)
        runtime_synchronize do
          value = bridge.interpreter.store.find(name.to_s, id.to_s)
          next unless value
          next unless !context || access_control.entity_allowed?(value.entity, action: :read, context:, record: value)

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
              value.members[member.to_s] = deserialize(member_value, context:)
            end
            bridge.interpreter.store.commit(value)
            serialize(value, context:)
          end
        end
      end

      # Client-created objects remain private to the browser until Save. The
      # temporary store object is removed before this synchronized call returns.
      def draft_record(name, context: nil)
        raise ArgumentError, 'type must be a nonempty string' unless name.is_a?(String) && !name.empty?

        runtime_synchronize do
          authorize_entity!(name, :create, context)
          store = bridge.interpreter.store
          value = store.create(name.to_s)
          begin
            serialize(value, context:).except(:draft_token).merge(new_record: true)
          ensure
            store.rollback(value)
          end
        end
      end

      # Storage restoration creates an uncommitted object, with a capability that
      # lets subsequent microflows resume it without persisting it prematurely.
      def restore_record(name, attributes, context: nil)
        unless name.is_a?(String) && !name.empty? && attributes.is_a?(Hash)
          raise ArgumentError, 'restore requires an entity type and attributes'
        end

        runtime_synchronize do
          authorize_entity!(name, :create, context)
          store = bridge.interpreter.store
          store.transaction do
            value = store.create(name)
            attributes.each do |member, member_value|
              authorize_entity!(name, :write, context, member:, record: value)
              value.members[member] = deserialize(member_value, context:)
            end
            serialize(value, context:)
          end
        ensure
          release_runtime_cache
        end
      end

      def delete_records(records, context: nil)
        unless records.is_a?(Array) && records.length <= 1000 && records.all? do |entry|
          entry.is_a?(Hash) && %w[type id].all? { entry[_1].is_a?(String) && !entry[_1].empty? }
        end
          raise ArgumentError, 'records must contain at most 1000 objects with type and id'
        end

        runtime_synchronize do
          bridge.interpreter.store.transaction do
            records.each do |entry|
              store = bridge.interpreter.store
              value = store.find(entry.fetch('type'), entry.fetch('id'))
              raise ArgumentError, 'record not found' unless value

              authorize_entity!(value.entity, :delete, context, record: value)
              store.delete(value)
              FileContent.new(store.database).delete(value.entity, value.id)
            end
          end
        end
        true
      end

      def delete_record(name, id, context: nil)
        runtime_synchronize do
          value = bridge.interpreter.store.find(name.to_s, id.to_s)
          next false unless value

          name = value.entity
          authorize_entity!(name, :delete, context, record: value)
          bridge.interpreter.store.transaction do
            bridge.interpreter.store.delete(value)
            FileContent.new(bridge.interpreter.store.database).delete(name, id)
          end
          true
        end
      end

      def update_record(name, id, attributes, context: nil)
        runtime_synchronize do
          value = bridge.interpreter.store.find(name.to_s, id.to_s)
          next unless value

          name = value.entity
          authorize_entity!(name, :write, context, record: value)
          bridge.interpreter.store.transaction do
            attributes.to_h.each do |member, member_value|
              authorize_entity!(name, :write, context, member: member, record: value)
              value.members[member.to_s] = deserialize(member_value, context:)
            end
            bridge.interpreter.store.commit(value)
            serialize(value, context:)
          end
        end
      end

      # Commit page drafts together: a missing object or denied member rolls
      # back every object, including the store's identity map.
      def commit_records(records, context: nil)
        unless records.is_a?(Array) && records.length <= 1000 && records.all? { valid_record_changes?(_1) }
          raise ArgumentError, 'records must contain at most 1000 objects with type, id and attributes'
        end

        keys = records.map { [_1.fetch('type'), _1.fetch('id')] }
        raise ArgumentError, 'duplicate record in commit' unless keys.uniq.size == keys.size

        runtime_synchronize do
          store = bridge.interpreter.store
          store.transaction do
            objects = records.to_h do |entry|
              key = [entry.fetch('type'), entry.fetch('id')]
              value = if entry['draft_token']
                        deserialize(entry, context:)
                      elsif entry['new_record'] == true
                        authorize_entity!(key.first, :create, context)
                        store.create(key.first)
                      else
                        store.find(*key)
                      end
              raise ArgumentError, "record #{key.join(' ')} not found" unless value

              authorize_entity!(value.entity, :create, context) if entry['draft_token']
              authorize_entity!(value.entity, :write, context, record: value)
              [key, value]
            end
            records.each do |entry|
              value = objects.fetch([entry.fetch('type'), entry.fetch('id')])
              entry.fetch('attributes').each do |member, member_value|
                authorize_entity!(value.entity, :write, context, member:, record: value)
                value.members[member] = deserialize_draft_member(member_value, objects, context:)
              end
            end
            store.database.execute('PRAGMA defer_foreign_keys = ON')
            store.commit(objects.values)
            records.map do |entry|
              value = objects.fetch([entry.fetch('type'), entry.fetch('id')])
              result = serialize(value, context:)
              result[:draft_id] = entry.fetch('id') if entry['new_record'] == true
              result
            end
          end
        ensure
          release_runtime_cache
        end
      end

      def deserialize_draft_member(value, objects, context:)
        value = value.transform_keys(&:to_s) if value.is_a?(Hash) && value.key?(:type) && value.key?(:id)
        if value.is_a?(Hash) && value['type'] && value['id']
          objects[[value['type'], value['id']]] || deserialize(value, context:)
        elsif value.is_a?(Hash)
          value.transform_values { deserialize_draft_member(_1, objects, context:) }
        elsif value.is_a?(Array)
          value.map { deserialize_draft_member(_1, objects, context:) }
        else
          value
        end
      end
      private :deserialize_draft_member

      def valid_record_changes?(entry)
        entry.is_a?(Hash) && %w[type id].all? { entry[_1].is_a?(String) && !entry[_1].empty? } &&
          entry['attributes'].is_a?(Hash) && entry['attributes'].keys.all? { _1.is_a?(String) }
      end
      private :valid_record_changes?

      def file_content(name, id, context: nil, upload: nil, thumbnail: nil)
        if upload && (!upload.is_a?(Hash) || !%w[name content].all? { upload[_1].is_a?(String) })
          raise ArgumentError, 'file upload requires string name and base64 content'
        end

        runtime_synchronize do
          store = bridge.interpreter.store
          value = store.find(name.to_s, id.to_s)
          next unless value

          name = value.entity
          authorize_entity!(name, :read, context, record: value)
          authorize_entity!(name, upload ? :write : :read, context, member: 'Contents', record: value)
          files = FileContent.new(store.database)
          next files.thumbnail(name, id, *thumbnail) if thumbnail && !upload
          next files.read(name, id) unless upload

          store.transaction do
            files.attach(store.schema.entity(name))
            policy = Registry.fetch(:record, name.to_s)&.runtime_file_policy || {}
            metadata = files.write(name, id, upload.fetch('name'), upload.fetch('content'), **policy)
            fields = store.schema.entity(name).columns.map(&:name)
            { 'Name' => metadata.fetch(:name), 'FileSize' => metadata.fetch(:size),
              'HasContents' => true }.each do |key, item|
              value.members[key] = item if fields.include?(key)
            end
            store.commit(value)
            metadata
          end
        end
      end

      def page(name, context: nil)
        implementation = Registry.fetch(:page, name.to_s)
        return if implementation.nil? || implementation.excluded?

        authorize_document!(:page, name, :read, context)

        {
          name: implementation.mendix_name, id: implementation.mendix_id,
          title: implementation.title,
          appearance_class: implementation.appearance_class,
          appearance_style: implementation.appearance_style,
          data_source: implementation.data_source
        }.merge(Presentation.page(implementation, classes: design_classes.method(:[]),
                                                  definitions: design_definitions))
          .merge(implementation.presentation_contract || {})
      end

      # Theme design property classes per document, recorded by the export.
      def design_classes
        @design_classes ||= begin
          path = root && File.join(root, DesignClasses::PATH)
          path && File.file?(path) ? JSON.parse(File.read(path)) : {}
        end
      end

      # The theme design properties that declared widget designs resolve to.
      def design_definitions
        @design_definitions ||= root ? DesignClasses.definitions(File.join(root, *THEME_PLATFORM)) : {}
      end

      def design_classed_presentation
        Registry.all(:presentation).to_h do |name, resource|
          widgets = design_classes[name.to_s]
          resource = DesignClasses.apply(JSON.parse(JSON.generate(resource)), widgets) if widgets
          [name, DesignDeclarations.resolve(resource, design_definitions)]
        end
      end

      # The language code of the signed-in user (System.User_Language), if any.
      def user_language(context)
        user = session_user(context)
        language = user&.members&.fetch('User_Language', nil)
        language.respond_to?(:members) ? language.members['Code'] : nil
      end

      # The Language selector changes the language of the signed-in user, as the
      # Mendix client does; the platform sets it regardless of entity access.
      def change_language(code, context:)
        runtime_synchronize do
          user = session_user(context)
          raise ArgumentError, 'changing the language requires a signed-in user' unless user

          store = bridge.interpreter.store
          language = store.retrieve(Runtime::Languages::LANGUAGE).find { _1.members['Code'] == code.to_s }
          raise ArgumentError, "unknown language #{code}" unless language

          user.members['User_Language'] = language
          store.commit(user)
          code.to_s
        end
      end

      def session_user(context)
        id = context&.user
        id && bridge.interpreter.store.find(Runtime::SystemDomain::USER, id.to_s)
      end
      private :session_user

      def async_invocations
        @async_invocations_mutex.synchronize { @async_invocations ||= AsyncInvocations.new(self) }
      end

      def access_control = (@access_control ||= bridge.access_control)

      def session_manager
        @session_manager ||= SessionManager.new(
          access_control, users: environment['MXRB_USERS_JSON'],
                          tokens: environment['MXRB_AUTH_TOKENS'],
                          ttl: environment.fetch('MXRB_SESSION_TTL', '3600'),
                          store: shared_store, directory: -> { bridge.store }
        )
      end

      def start_scheduler
        @scheduler_started = true
        bridge.start_scheduler
      end

      def close
        @async_invocations&.close
        @async_invocations = nil
        @bridge&.close
        @shared_store&.close
        @bridge = nil
        @access_control = nil
        @session_manager = nil
        @shared_store = nil
        @scheduler_started = false
      end

      private

      def runtime_schema_modules
        modules = RuntimeCatalog.new(manifest.modules,
                                     authoritative: manifest.data['runtime_model'] == 'ruby').modules.map do |mod|
          enumerations = mod.fetch('enumerations', []).map do |definition|
            implementation = Registry.fetch(:enumeration, definition.fetch('name'))
            next definition unless implementation

            values = implementation.values.map do |value|
              captions = value.fetch(:captions)
              {
                'name' => value.fetch(:name), 'id' => value.fetch(:id), 'captions' => captions,
                'caption' => captions['en_US'] || captions.values.first || value.fetch(:name)
              }
            end
            definition.merge('values' => values)
          end
          models = mod.fetch('models', []).map { runtime_model_definition(_1) }
          dtos = mod.fetch('dtos', []).map { runtime_model_definition(_1) }
          mod.except('constants').merge('enumerations' => enumerations, 'models' => models, 'dtos' => dtos)
        end
        return modules if modules.any? { _1['name'] == 'System' }

        modules + [system_schema_module]
      end

      # The Runtime-owned System entities and associations, without the hashed password.
      def system_schema_module
        models = Runtime::SystemDomain::ATTRIBUTES.map do |entity, attributes|
          members = attributes.reject { _2 == :hashstring }.map do |name, type, default, unique|
            { 'name' => name, 'mendix_name' => name, 'type' => type.to_s, 'default' => default, 'unique' => unique }
          end
          { 'name' => entity, 'persistable' => true, 'attributes' => members }
        end
        associations = Runtime::SystemDomain::ASSOCIATIONS.map do |qualified, from, to, type|
          { 'name' => qualified.split('.').last, 'type' => type.to_s, 'from_entity' => from, 'to_entity' => to }
        end
        { 'name' => 'System', 'models' => models, 'dtos' => [], 'associations' => associations,
          'enumerations' => [], 'pages' => [], 'services' => [] }
      end

      def runtime_model_definition(definition)
        implementation = Registry.fetch(:record, definition.fetch('name'))
        return definition unless implementation

        attributes = implementation.runtime_attributes.map do |attribute|
          attribute.transform_keys(&:to_s).merge(
            'name' => attribute.fetch(:mendix_name), 'ruby_name' => attribute.fetch(:name).to_s,
            'type' => attribute.fetch(:type).to_s
          )
        end
        definition.merge('attributes' => attributes)
      end

      GRID_FILTER_OPERATORS = {
        'text' => %w[contains equals not_equals starts_with ends_with empty not_empty],
        'number' => %w[equals not_equals gt gte lt lte between empty not_empty],
        'date' => %w[equals not_equals before after on_or_before on_or_after between empty not_empty],
        'boolean' => %w[equals not_equals empty not_empty],
        'enum' => %w[equals not_equals empty not_empty]
      }.freeze

      GRID_DEFAULT_OPERATORS = {
        'text' => 'contains', 'number' => 'equals', 'date' => 'equals',
        'boolean' => 'equals', 'enum' => 'equals'
      }.freeze

      def grid_record_matches?(record, filters)
        Array(filters).all? do |raw|
          filter = raw.to_h.transform_keys(&:to_s)
          type = filter.fetch('type', 'text').to_s.downcase
          allowed = GRID_FILTER_OPERATORS[type] || raise(ArgumentError, "unsupported filter type #{type}")
          operator = filter.fetch('operator', GRID_DEFAULT_OPERATORS.fetch(type)).to_s.downcase
          raise ArgumentError, "unsupported #{type} filter operator #{operator}" unless allowed.include?(operator)

          attribute = grid_member_name(filter.fetch('attribute'))
          grid_filter_match?(record.members[attribute], filter['value'], type, operator)
        end
      end

      def grid_filter_match?(actual, expected, type, operator)
        return actual.nil? || actual.to_s.empty? if operator == 'empty'
        return !actual.nil? && !actual.to_s.empty? if operator == 'not_empty'

        left = grid_filter_value(actual, type)
        right = grid_filter_value(expected, type)
        return false if left.nil? || right.nil?
        return Array(right).include?(left) if type == 'enum' && operator == 'equals' && right.is_a?(Array)

        case operator
        when 'contains' then left.include?(right)
        when 'starts_with' then left.start_with?(right)
        when 'ends_with' then left.end_with?(right)
        when 'equals' then left == right
        when 'not_equals' then left != right
        when 'gt', 'after' then left > right
        when 'gte', 'on_or_after' then left >= right
        when 'lt', 'before' then left < right
        when 'lte', 'on_or_before' then left <= right
        when 'between'
          bounds = Array(expected).map { grid_filter_value(_1, type) }
          bounds.size == 2 && bounds.none?(&:nil?) && left >= bounds[0] && left <= bounds[1]
        end
      end

      def grid_filter_value(value, type)
        return value.map { grid_filter_value(_1, type) } if value.is_a?(Array)

        case type
        when 'text', 'enum' then value.to_s.downcase
        when 'number' then Runtime::DecimalValues.parse(value)
        when 'date' then Date.iso8601(value.to_s[0, 10])
        when 'boolean'
          return value if [true, false].include?(value)
          return true if value.to_s.casecmp?('true')

          false if value.to_s.casecmp?('false')
        end
      rescue ArgumentError, TypeError
        nil
      end

      def grid_sort_records(records, sortings)
        keys = Array(sortings).map do |raw|
          sorting = raw.to_h.transform_keys(&:to_s)
          direction = sorting.fetch('direction', 'Ascending').to_s
          unless %w[Ascending Descending asc desc].include?(direction)
            raise ArgumentError, "unsupported sort direction #{direction}"
          end

          [grid_member_name(sorting.fetch('attribute')), %w[Descending desc].include?(direction)]
        end
        Runtime::SortOrder.sort(records, keys) { |record, attribute| record.members[attribute] }
      end

      def grid_member_name(value)
        name = value.to_s.split(%r{[./]}).last.to_s
        raise ArgumentError, 'filter/sort attribute cannot be empty' if name.empty?

        name
      end

      def runtime_synchronize
        (@runtime_monitor ||= Monitor.new).synchronize do
          @runtime_depth = @runtime_depth.to_i + 1
          begin
            yield
          ensure
            @runtime_depth -= 1
          end
        end
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
        secured.fetch(:presentation, {}).each_value do |resource|
          next unless resource[:kind] == 'menu'

          resource[:items] = secure_navigation_items(resource[:items], allowed_pages, allowed_services)
        end
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
          action = item[:action].to_h.transform_keys(&:to_sym)
          allowed &&= pages.include?(action[:handler]) if action[:kind].to_s == 'page'
          allowed &&= services.include?(action[:handler]) if %w[microflow nanoflow].include?(action[:kind].to_s)
          next unless allowed || children.any?

          item = item.reject { %i[page microflow action].include?(_1) } unless allowed
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
        parameters = service.fetch('parameters', []).reject { rest_context_parameter?(_1) }
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

      def rest_context_parameter?(parameter)
        %w[System.HttpRequest System.HttpResponse].include?(parameter['entity'].to_s)
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
        RubyApp.load_sources(manifest)
      end

      def load_adapters
        path = File.join(root, 'config', 'adapters.rb')
        load path, true if File.file?(path)
      end

      def bridge
        @bridge ||= build_bridge
      end

      def build_bridge
        NativeBridge.new(
          manifest.absolute_path('runtime_mpr'),
          runtime_project: manifest.data['runtime_model'] == 'ruby' ? RuntimeProject.new(manifest) : nil,
          database: runtime_database_path,
          record_hooks: Registry.all(:record), adapters: Registry.adapters,
          java_custom_actions: Registry.java_custom_actions,
          allow_destructive: environment['MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS'].to_s.casecmp?('true'),
          coordinator: shared_store,
          scheduler_lease_ttl: environment.fetch('MXRB_SCHEDULER_LEASE_TTL', '300'),
          runtime_records: Registry.all(:record),
          administrator_password: environment['MXRB_ADMIN_PASSWORD'],
          service_dispatch: lambda { |name, arguments, context|
            deserialize(call_service(name, arguments, context:), context:)
          }
        )
      end

      def reload_sources!(revision)
        previous_registry = Registry.snapshot
        previous_bridge = @bridge
        candidate = nil
        Registry.reset!
        load_adapters
        load_application_files
        candidate = build_bridge if previous_bridge
        candidate.start_scheduler if @scheduler_started
        @bridge = candidate if previous_bridge
        @access_control = nil
        @session_manager = nil
        @rest_routes = nil
        previous_bridge&.close
        @source_reloader.commit(revision)
        @reload_status = { enabled: true, state: 'reloaded', error: nil }.freeze
        true
      rescue StandardError, ScriptError => e
        candidate&.close
        Registry.restore!(previous_registry)
        @bridge = previous_bridge
        @reload_status = { enabled: true, state: 'error', error: "#{e.class}: #{e.message}" }.freeze
        warn "[mxrb] Ruby reload failed; keeping previous application: #{@reload_status.fetch(:error)}"
        false
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

      # Hashed strings such as System.User.Password never leave the server.
      def hashed_members(entity)
        (@hashed_members ||= {})[entity] ||= begin
          store = bridge.interpreter.store
          columns = store.respond_to?(:schema) ? store.schema.entity(entity).columns : []
          columns.select { _1.type == :hashstring }.map(&:name)
        rescue ArgumentError
          []
        end
      end

      def serialize(value, seen = {}, context: nil)
        case value
        when Runtime::Native::ObjectValue
          key = [value.entity, value.id]
          return { id: value.id, type: value.entity } if seen[key]

          branch = seen.merge(key => true)
          members = value.members.except(*hashed_members(value.entity))
          if context
            members = members.select do |member, _member_value|
              access_control.member_allowed?(
                value.entity, member, action: :read, context:, record: value
              )
            end
          end
          result = { id: value.id, type: value.entity, attributes: serialize(members, branch, context:) }
          store = bridge.interpreter.store
          owner = draft_owner(context)
          if store.respond_to?(:draft?) &&
             (store.draft?(value) || store.client_drafts.registered?(value, owner:))
            token = store.client_drafts.capture(value, owner:)
            result.merge!(new_record: true, draft_token: token)
          end
          result
        when BigDecimal then Runtime::DecimalValues.encode(value)
        when Hash then value.to_h { [serialize(_1, seen, context:), serialize(_2, seen, context:)] }
        when Array then value.map { serialize(_1, seen, context:) }
        else value
        end
      end

      def deserialize(value = nil, context: nil, synchronize: false, **keyword_value)
        value = keyword_value if value.nil? && !keyword_value.empty?
        value = value.transform_keys(&:to_s) if value.is_a?(Hash) && value.key?(:id) && value.key?(:type)
        if Runtime::DecimalValues.tagged?(value)
          Runtime::DecimalValues.parse(value.fetch(Runtime::DecimalValues::TAG))
        elsif value.is_a?(Hash) && value['id'] && value['type']
          store = bridge.interpreter.store
          object = if value['draft_token']
                     store.client_drafts.resume(value['draft_token'], entity: value['type'].to_s,
                                                                      id: value['id'].to_s, owner: draft_owner(context))
                   else
                     store.find(value['type'].to_s, value['id'].to_s)
                   end
          if !object && value['transient'] == true
            object = Runtime::Native::ObjectValue.new(
              entity: value['type'].to_s, id: value['id'].to_s, members: {}
            )
            value.fetch('attributes', {}).each do |member, member_value|
              object.members[member.to_s] = deserialize(member_value, context:, synchronize:)
            end
          end
          raise NativeRuntimeError, "object #{value['type']} #{value['id']} not found" unless object

          authorize_entity!(object.entity, :read, context, record: object)

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

        stage_reachable_drafts(object, context:)
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
          store.commit(object) if value['transient'] != true && !value['draft_token'] && store.respond_to?(:commit)
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
        return if @runtime_depth.to_i > 1

        store = bridge.interpreter.store
        store.release_cache! if store.respond_to?(:release_cache!)
      end

      def draft_owner(context)
        context.respond_to?(:user) && context.user ? "user:#{context.user}" : 'anonymous'
      end
    end
    # rubocop:enable Metrics
  end
end
