# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'monitor'
require 'uri'
require_relative 'native_fragment_store'
require_relative 'ruby_app/session_manager'
require_relative 'ruby_app/source_identity'
require_relative 'ruby_app/domain_rule_builders'
require_relative 'ruby_app/security_builders'
require_relative 'ruby_app/member_identity'
require_relative 'ruby_app/record_identity'
require_relative 'ruby_app/regular_expression'
require_relative 'ruby_app/security_identity'
require_relative 'ruby_app/schedule_builder'
require_relative 'ruby_app/page_data_sources'
require_relative 'ruby_app/page_design_identity'
require_relative 'ruby_app/pluggable_properties'
require_relative 'http/server'

module Mxrb
  # Runtime and reversible metadata contract for projects exported with
  # `mxrb export --mode ruby`.
  module RubyApp
    # rubocop:disable Metrics
    MANIFEST_PATH = File.join('.mxrb', 'ruby-app.json')
    SOURCE_GLOBS = [
      'app/**/*.rb', 'config/**/*', 'frontend/**/*', 'spec/**/*.rb',
      'db/migrate/**/*', 'bin/**/*', '.rspec', 'config.ru',
      'Gemfile', 'Rakefile', 'README.md', '.gitignore', '.env.example', '.ruby-version'
    ].freeze
    SOURCE_EXCLUSIONS = %w[frontend/node_modules/ frontend/dist/].freeze
    ARTIFACT_DIRECTORIES = %w[
      constants enumerations models dtos controllers services pages security scheduled_events regular_expressions
    ].freeze

    def self.application_files(root)
      ARTIFACT_DIRECTORIES.flat_map do |directory|
        files = Dir.glob(File.join(root, 'app', directory, '**', '*.rb'))
        next files unless directory == 'controllers'

        files.select { mxrb_controller_file?(_1) }
      end.sort
    end

    def self.mxrb_controller_file?(path)
      source = File.read(path)
      source.match?(/<\s*(?:::)?Mxrb::RubyApp::Controller\b/) ||
        source.match?(/^\s*controller_name\b/)
    end

    def self.with_native_fragments(root, &block)
      store = NativeFragmentStore.new(File.join(File.expand_path(root), '.mxrb', 'native_fragments'))
      NativeFragmentStore.with(store, &block)
    end

    def self.load_sources(manifest, member_identity_project: nil)
      SourceIdentity.with(manifest) do |identities|
        FlowMetadata.with(manifest) do
          PageDesignIdentity.with(manifest) do
            PluggableProperties.with(manifest) do
              with_native_fragments(manifest.root) do
                application_files(manifest.root).each do |path|
                  identities.load_file(path) { load path, true }
                end
                identities.rebase_member_identities!(member_identity_project) if member_identity_project
                identities.finalize!
              end
            end
          end
        end
      end
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
      runtime_mpr = manifest.absolute_path('runtime_mpr')
      if File.file?(runtime_mpr)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(runtime_mpr, destination)
        runtime_contents = File.join(File.dirname(runtime_mpr), 'mprcontents')
        if File.directory?(runtime_contents)
          FileUtils.cp_r(runtime_contents, File.dirname(destination), remove_destination: true)
        end
        restore_runtime_project(manifest, destination)
      else
        load manifest.absolute_path('mendix_project')
      end
      transitioned = mendix_version && manifest.data.dig('project', 'mendix_version') != mendix_version.to_s
      transition(destination, mendix_version) if mendix_version
      Synchronizer.new(root, destination, manifest:, rebase_member_identities: transitioned).synchronize!
      destination
    ensure
      if previous
        ENV['MXRB_OUTPUT_PATH'] = previous
      else
        ENV.delete('MXRB_OUTPUT_PATH')
      end
    end

    def self.restore_runtime_project(manifest, destination)
      source = manifest.absolute_path('runtime_project')
      return unless File.directory?(source)

      Dir.children(source).each do |name|
        FileUtils.cp_r(File.join(source, name), File.join(File.dirname(destination), name),
                       remove_destination: true)
      end
    rescue KeyError
      nil
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
        @constants = {}
        @enumerations = {}
        @records = {}
        @controllers = {}
        @services = {}
        @pages = {}
        @module_security = {}
        @project_security = {}
        @scheduled_events = {}
        @regular_expressions = {}
        @adapters = {}
        @java_custom_actions = {}
      end

      def register(kind, name, implementation, unit_id: nil)
        return register_service(name, implementation, unit_id:) if kind == :service

        collection(kind)[name] = implementation
      end

      def fetch(kind, name, unit_id: nil)
        return fetch_service(name, unit_id:) if kind == :service

        collection(kind)[name]
      end

      def all(kind) = collection(kind).dup.freeze

      def register_service(name, implementation, unit_id: nil)
        services = collection(:service)
        qualified_name = name.to_s
        identifier = unit_id.to_s
        matches = services.select do |_key, candidate|
          candidate.mendix_name.to_s == qualified_name
        end
        if matches.empty?
          services[qualified_name] = implementation
          return implementation
        end

        existing_ids = matches.values.map { _1.mendix_id.to_s }
        if identifier.empty? || existing_ids.any?(&:empty?)
          raise ValidationError,
                "ambiguous Ruby service #{qualified_name}: duplicate names require explicit unit ids"
        end

        if services.key?(qualified_name)
          existing = services.delete(qualified_name)
          services[service_key(qualified_name, existing.mendix_id)] = existing
        end
        services[service_key(qualified_name, identifier)] = implementation
        implementation
      end

      def fetch_service(name, unit_id: nil)
        services = collection(:service)
        qualified_name = name.to_s
        direct = services[qualified_name]
        return direct if direct && (unit_id.nil? || direct.mendix_id.to_s == unit_id.to_s)

        matches = services.values.select do |candidate|
          candidate.mendix_name.to_s == qualified_name &&
            (unit_id.nil? || candidate.mendix_id.to_s == unit_id.to_s)
        end
        return matches.first if matches.one?
        return nil if matches.empty?

        raise ValidationError,
              "ambiguous Ruby service #{qualified_name}: specify its unit id"
      end

      def service_key(name, unit_id) = [name.to_s, unit_id.to_s].freeze

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
          constant: @constants, enumeration: @enumerations, record: @records, service: @services,
          controller: (@controllers ||= {}), page: @pages, module_security: @module_security,
          project_security: @project_security, scheduled_event: @scheduled_events,
          regular_expression: @regular_expressions,
          adapter: @adapters,
          java_custom_action: @java_custom_actions
        }.fetch(kind)
      end
    end

    AccessRuleMember = Data.define(:name, :rights, :id, :reference, :kind)

    # Ordered member declarations shared by persistent models and DTOs.
    class AccessRuleBuilder
      def initialize(members = [])
        @members = Array(members).dup
      end

      def member(name, rights:, id: nil, reference: nil, kind: :attribute)
        raise ArgumentError, 'access member requires a name' if name.to_s.empty?

        @members << AccessRuleMember.new(name:, rights:, id:, reference:, kind:)
      end

      def evaluate(&block)
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      end

      def members = @members.dup.freeze
    end

    # Base for generated persistent models.
    class Record
      LIFECYCLE_EVENTS = Runtime::Native::Store::LIFECYCLE_EVENTS
      NATIVE_LIFECYCLE_EVENTS = %i[before_commit after_commit before_delete after_delete].freeze
      ASSOCIATION_TYPES = %i[Reference ReferenceSet].freeze
      ASSOCIATION_OWNERS = %i[Default Both].freeze
      ASSOCIATION_STORAGE_FORMATS = %i[Column Table].freeze
      ACCESS_RIGHTS = %i[None ReadOnly ReadWrite].freeze
      ACCESS_RIGHT_ALIASES = { none: :None, read_only: :ReadOnly, read_write: :ReadWrite }.freeze
      ACCESS_MEMBER_KINDS = %i[attribute association].freeze
      ATTRIBUTE_OPTION_UNSET = Object.new.freeze

      class << self
        attr_reader :mendix_id, :attributes, :associations, :persistable, :lifecycle_callbacks,
                    :access_rules, :indexes, :generalization, :oql_view_definition,
                    :native_lifecycle_definitions, :validation_rules

        def inherited(child)
          super
          child.instance_variable_set(:@attributes, [])
          child.instance_variable_set(:@associations, [])
          child.instance_variable_set(:@lifecycle_callbacks, {})
          child.instance_variable_set(:@access_rules, nil)
          child.instance_variable_set(:@indexes, nil)
          child.instance_variable_set(:@system_members, nil)
          child.instance_variable_set(:@generalization, nil)
          child.instance_variable_set(:@oql_view_definition, nil)
          child.instance_variable_set(:@native_lifecycle_definitions, nil)
          child.instance_variable_set(:@validation_rules, nil)
          child.instance_variable_set(:@removed_domain_members, {})
          child.instance_variable_set(:@declared_domain_collections, {})
        end

        def mendix_name(value = nil, id: nil, renamed_from: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :record, @mendix_name, id:, renamed_from:)
          Registry.register(:record, @mendix_name, self)
        end

        def persistence(value) = (@persistable = value == true)

        def attribute(name, type:, mendix_name:, required: false, unique: false, default: nil,
                      documentation: '', length: nil, localize_date: ATTRIBUTE_OPTION_UNSET,
                      enumeration: nil)
          @attributes ||= []
          declaration = {
            name: name.to_sym, type: type.to_sym,
            mendix_name: mendix_name.to_s, required: required == true,
            unique: unique == true, default: default,
            documentation: documentation.to_s, length: length,
            enumeration: enumeration
          }
          declaration[:localize_date] = localize_date unless localize_date.equal?(ATTRIBUTE_OPTION_UNSET)
          @attributes << declaration
          attr_accessor name
        end

        def association(target, name:, id: nil, type: :Reference, owner: :Default,
                        documentation: '', parent_delete: :NoAction, child_delete: :NoAction,
                        storage_format: nil, renamed_from: nil)
          type = type.to_sym
          owner = owner.to_sym
          storage_format = storage_format&.to_sym
          raise ArgumentError, 'association type must be Reference or ReferenceSet' \
            unless ASSOCIATION_TYPES.include?(type)
          raise ArgumentError, 'association owner must be Default or Both' \
            unless ASSOCIATION_OWNERS.include?(owner)
          if storage_format && !ASSOCIATION_STORAGE_FORMATS.include?(storage_format)
            raise ArgumentError, 'association storage format must be Column or Table'
          end

          @associations ||= []
          declaration = {
            name: name.to_s, id: id&.to_s, target: target.to_s, type:, owner:,
            documentation: documentation.to_s, parent_delete: parent_delete.to_sym,
            child_delete: child_delete.to_sym, storage_format:
          }
          declaration[:renamed_from] = renamed_from unless renamed_from.nil?
          @associations << declaration
          (@declared_domain_collections ||= {})[:associations] = true
        end

        def clear_associations! = clear_domain_collection(:associations, :@associations)

        def access_rule(*roles, id: nil, identity: nil, documentation: '', create: false, delete: false,
                        default_rights: :None, xpath: '', xpath_caption: nil, members: [],
                        renamed_from: nil, &block)
          raise ArgumentError, 'access_rule requires at least one module role' if roles.empty?

          declarations = AccessRuleBuilder.new(members)
          declarations.evaluate(&block) if block
          rule = {
            id: id.to_s, roles: roles.map(&:to_s), documentation: documentation.to_s,
            create: create == true, delete: delete == true,
            default_rights: normalize_access_right(default_rights), xpath: xpath.to_s,
            xpath_caption: xpath_caption&.to_s,
            members: declarations.members.map { normalize_access_member(_1) }
          }
          rule[:source_identity] = identity.to_s unless identity.nil?
          rule[:renamed_from] = renamed_from unless renamed_from.nil?
          (@access_rules ||= []) << rule
          (@declared_domain_collections ||= {})[:access_rules] = true
        end

        def clear_access_rules! = clear_domain_collection(:access_rules, :@access_rules)

        def index(*attributes, id: nil, guid: nil, include_offline: false, ascending: true,
                  members: nil, renamed_from: nil, &block)
          declarations = IndexBuilder.new(members || index_members(attributes, ascending))
          declarations.evaluate(&block) if block
          normalized = declarations.members.map { normalize_index_member(_1) }
          raise ArgumentError, 'index requires at least one attribute' if normalized.empty?

          definition = {
            id: id.to_s, guid: guid.to_s, include_offline: include_offline == true,
            members: normalized
          }
          definition[:renamed_from] = renamed_from unless renamed_from.nil?
          (@indexes ||= []) << definition
          (@declared_domain_collections ||= {})[:indexes] = true
        end

        def clear_indexes! = clear_domain_collection(:indexes, :@indexes)

        def system_members(owner: ATTRIBUTE_OPTION_UNSET, created_date: ATTRIBUTE_OPTION_UNSET,
                           changed_date: ATTRIBUTE_OPTION_UNSET, changed_by: ATTRIBUTE_OPTION_UNSET)
          values = [owner, created_date, changed_date, changed_by]
          return @system_members if values.all? { _1.equal?(ATTRIBUTE_OPTION_UNSET) }

          @system_members = {
            owner: owner == true, created_date: created_date == true,
            changed_date: changed_date == true, changed_by: changed_by == true
          }
        end

        def generalizes(entity, id: nil)
          target = entity.to_s
          raise ArgumentError, 'generalizes requires a qualified entity name' if target.empty?

          @generalization = { target:, id: id&.to_s }
        end

        def oql_view(source: nil, query: nil, document_id: nil, source_id: nil)
          raise ArgumentError, 'oql_view requires source or query' \
            if source.to_s.empty? && query.to_s.empty?

          @oql_view_definition = {
            source: source&.to_s, query: query&.to_s,
            document_id: document_id&.to_s, source_id: source_id&.to_s
          }.compact
        end

        def lifecycle(event, method_name = nil, microflow: nil, id: nil, pass_event_object: true,
                      raise_error_on_false: nil, renamed_from: nil, &block)
          event = event.to_sym
          raise ArgumentError, "unknown lifecycle event #{event}" unless LIFECYCLE_EVENTS.include?(event)

          if microflow
            raise ArgumentError, "#{event} is not a native Mendix lifecycle event" \
              unless NATIVE_LIFECYCLE_EVENTS.include?(event)
            raise ArgumentError, 'native lifecycle cannot also declare a Ruby callback' \
              if method_name || block

            raise_error = if raise_error_on_false.nil?
                            event.to_s.start_with?('before_')
                          else
                            raise_error_on_false == true
                          end
            @native_lifecycle_definitions ||= []
            definition = {
              id: id.to_s, event:, handler: microflow.to_s,
              pass_event_object: pass_event_object == true,
              raise_error_on_false: raise_error
            }
            definition[:renamed_from] = renamed_from unless renamed_from.nil?
            @native_lifecycle_definitions << definition
            (@declared_domain_collections ||= {})[:lifecycle] = true
            return
          end
          raise ArgumentError, 'callback method or block is required' unless method_name || block

          @lifecycle_callbacks ||= {}
          (@lifecycle_callbacks[event] ||= []) << (method_name || block)
        end

        LIFECYCLE_EVENTS.each do |event|
          define_method(event) do |method_name = nil, **options, &block|
            lifecycle(event, method_name, **options, &block)
          end
        end

        def clear_native_lifecycle! = clear_domain_collection(:lifecycle, :@native_lifecycle_definitions)

        def validation_rule(attribute, kind:, id: nil, message_id: nil, translations: [],
                            rule_info_id: nil, rule_info: {}, renamed_from: nil, &block)
          name = attribute.to_s
          raise ArgumentError, 'validation_rule requires an attribute' if name.empty?

          builder = ValidationRuleBuilder.new(kind:, translations:, rule_info:)
          builder.evaluate(&block) if block
          definition = {
            id: id.to_s, attribute: name, kind: builder.kind,
            message_id: message_id.to_s,
            translations: builder.translations.map { normalize_validation_translation(_1) },
            rule_info_id: rule_info_id.to_s,
            rule_info: builder.rule_info
          }
          definition[:renamed_from] = renamed_from unless renamed_from.nil?
          (@validation_rules ||= []) << definition
          (@declared_domain_collections ||= {})[:validation_rules] = true
          option = { 'required' => :required, 'unique' => :unique }[builder.kind.downcase]
          declared_attribute = @attributes&.find do |candidate|
            [candidate[:name], candidate[:mendix_name]].map(&:to_s).include?(name)
          end
          declared_attribute[option] = true if option && declared_attribute
        end

        def clear_validation_rules! = clear_domain_collection(:validation_rules, :@validation_rules)

        def remove_association(name) = remove_domain_member(:associations, name)
        def remove_index(*members) = remove_domain_member(:indexes, members)
        def remove_access_rule(*roles, xpath: '') = remove_domain_member(:access_rules, [roles, xpath])
        def remove_native_lifecycle(event) = remove_domain_member(:lifecycle, event)
        def remove_validation_rule(attribute, kind:) = remove_domain_member(:validation_rules, [attribute, kind])

        def resolve_record_identities!(identities)
          (@removed_domain_members || {}).each do |collection, removed|
            next if removed.empty? || @declared_domain_collections.to_h[collection]

            raise ValidationError,
                  "domain removal requires explicit complete #{collection} declarations or an explicit clear operation"
          end
          resolved = identities.resolve(
            id: mendix_id, name: mendix_name, removed: @removed_domain_members || {},
            associations: @associations, access_rules: @access_rules, indexes: @indexes,
            lifecycle: @native_lifecycle_definitions, validation_rules: @validation_rules,
            generalization: @generalization, oql_view: @oql_view_definition
          )
          @associations = resolved.fetch(:associations)
          @access_rules = resolved.fetch(:access_rules)
          @indexes = resolved.fetch(:indexes)
          @native_lifecycle_definitions = resolved.fetch(:lifecycle)
          @validation_rules = resolved.fetch(:validation_rules)
          @generalization = resolved.fetch(:generalization)
          @oql_view_definition = resolved.fetch(:oql_view)
        end

        def from_native(value)
          values = attributes.to_a.to_h do |attribute|
            [attribute.fetch(:name), value.members[attribute.fetch(:mendix_name)]]
          end
          new(id: value.id, **values).tap { _1.instance_variable_set(:@native_value, value) }
        end

        private

        def clear_domain_collection(collection, variable)
          (@declared_domain_collections ||= {})[collection] = true
          instance_variable_set(variable, [])
        end

        def remove_domain_member(collection, key)
          raise ArgumentError, 'domain removal requires a semantic key' if key.nil? || key.to_s.empty? || key == []

          @removed_domain_members ||= {}
          (@removed_domain_members[collection] ||= []) << key
        end

        def normalize_access_right(value)
          right = ACCESS_RIGHT_ALIASES.fetch(value.to_sym, value.to_sym)
          raise ArgumentError, "access rights must be one of #{ACCESS_RIGHTS.join(', ')}" \
            unless ACCESS_RIGHTS.include?(right)

          right
        end

        def normalize_access_member(member)
          declaration = member.to_h.transform_keys(&:to_sym)
          kind = declaration.fetch(:kind, :attribute).to_sym
          raise ArgumentError, 'access member kind must be attribute or association' \
            unless ACCESS_MEMBER_KINDS.include?(kind)

          {
            id: declaration[:id].to_s, name: declaration.fetch(:name).to_s,
            reference: declaration[:reference].to_s,
            rights: normalize_access_right(declaration.fetch(:rights)), kind:
          }
        end

        def index_members(attributes, ascending)
          names = attributes.flatten.map(&:to_s)
          directions = Array(ascending)
          if directions.size != 1 && directions.size != names.size
            raise ArgumentError, 'ascending must be one boolean or one value per indexed attribute'
          end

          directions *= names.size if directions.size == 1
          names.zip(directions).map { |name, direction| { name:, ascending: direction } }
        end

        def normalize_index_member(member)
          declaration = member.to_h.transform_keys(&:to_sym)
          {
            id: declaration[:id].to_s, name: declaration.fetch(:name).to_s,
            ascending: declaration.fetch(:ascending, true) == true,
            type: declaration.fetch(:type, :Normal).to_sym
          }
        end

        def normalize_validation_translation(translation)
          value = translation.to_h.transform_keys(&:to_sym)
          {
            id: value[:id].to_s,
            language_code: value.fetch(:language_code, value[:language]).to_s,
            text: value.fetch(:text).to_s
          }
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

    # Application-owned HTTP controller. Routes remain declared by published
    # REST endpoints; controllers receive actions and use these typed CRUD helpers.
    class Controller
      class << self
        attr_reader :registered_name

        def controller_name(name)
          value = name.to_s
          raise ArgumentError, 'controller name cannot be empty' if value.empty?

          @registered_name = value
          Registry.register(:controller, value, self)
        end
      end

      attr_reader :application, :context

      def initialize(application, context: nil)
        @application = application
        @context = context
      end

      def all(model)
        application.records(entity_name(model), context:)
      end

      def find(model, id)
        application.record(entity_name(model), id, context:)
      end

      def find!(model, id)
        find(model, id) || raise(NotFoundError, "#{entity_name(model)} #{id} not found")
      end

      def find_by(model, **attributes)
        expected = mendix_attributes(model, attributes)
        all(model).find do |record|
          members = record.fetch(:attributes)
          expected.all? do |name, value|
            actual = members[name]
            actual == value || (!actual.nil? && !value.nil? && actual.to_s == value.to_s)
          end
        end
      end

      def find_by!(model, **attributes)
        find_by(model, **attributes) ||
          raise(NotFoundError, "#{entity_name(model)} matching #{attributes.keys.join(', ')} not found")
      end

      def create(model, attributes = nil, **values)
        attributes = values if attributes.nil?
        application.create_record(
          entity_name(model), mendix_attributes(model, attributes), context:
        )
      end

      def update(model, id, attributes = nil, **values)
        attributes = values if attributes.nil?
        result = application.update_record(
          entity_name(model), id, mendix_attributes(model, attributes), context:
        )
        result || raise(NotFoundError, "#{entity_name(model)} #{id} not found")
      end

      def destroy(model, id)
        deleted = application.delete_record(entity_name(model), id, context:)
        raise NotFoundError, "#{entity_name(model)} #{id} not found" unless deleted

        true
      end

      def update_by(model, attribute:, value:, **attributes)
        record = find_by!(model, attribute => value)
        update(model, record.fetch(:id), attributes)
      end

      def destroy_by(model, attribute:, value:)
        record = find_by!(model, attribute => value)
        destroy(model, record.fetch(:id))
      end

      def model(name)
        Registry.fetch(:record, name.to_s) ||
          raise(ValidationError, "model #{name} is not registered")
      end

      private

      def entity_name(model)
        return model.mendix_name if model.is_a?(Class) && model <= Record

        raise ArgumentError, 'CRUD helpers require an Mxrb::RubyApp::Record class'
      end

      def mendix_attributes(model, attributes)
        attributes.to_h.to_h do |name, value|
          member = model.attributes.find do |candidate|
            [candidate.fetch(:name), candidate.fetch(:mendix_name)].map(&:to_s).include?(name.to_s)
          end
          raise ArgumentError, "unknown #{model.mendix_name} attribute #{name}" unless member

          [member.fetch(:mendix_name), value]
        end
      end
    end

    # Editable Mendix enumeration definition. Generated Ruby sources retain
    # document/value ids and every standard localized caption.
    class Enumeration
      OPTION_UNSET = Object.new.freeze

      # Localized captions are authored as ordered, typed translations.
      class TranslationBuilder
        def initialize = (@translations = [])

        def translation(language, text)
          @translations << Forms::Translation.new(language.to_s, text.to_s)
        end

        def build = Forms::Text.new(@translations)
      end

      class << self
        attr_reader :mendix_id, :values

        def inherited(child)
          super
          child.instance_variable_set(:@values, [])
          child.instance_variable_set(:@removed_values, [])
          child.instance_variable_set(:@documentation, '')
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :enumeration, @mendix_name, id:)
          Registry.register(:enumeration, @mendix_name, self)
        end

        def documentation(value = OPTION_UNSET)
          return @documentation.to_s if value.equal?(OPTION_UNSET)

          @documentation = value.to_s
        end

        def value(name, id: nil, caption: OPTION_UNSET, captions: nil, renamed_from: nil, &block)
          if block && (!captions.nil? || !caption.equal?(OPTION_UNSET))
            raise ArgumentError, 'value accepts either caption options or a translation block'
          end

          localized = if block
                        builder = TranslationBuilder.new
                        block.arity.zero? ? builder.instance_eval(&block) : block.call(builder)
                        builder.build.translations.to_h { [_1.language, _1.text] }
                      elsif captions.nil?
                        {}
                      else
                        captions.to_h.transform_keys(&:to_s).transform_values(&:to_s)
                      end
          localized['en_US'] = caption.to_s unless caption.equal?(OPTION_UNSET)
          localized['en_US'] = name.to_s if !block && captions.nil? && caption.equal?(OPTION_UNSET)
          @values ||= []
          declaration = { name: name.to_s, id: id.to_s, captions: localized.freeze }
          declaration[:renamed_from] = renamed_from.to_s unless renamed_from.nil?
          @values << declaration.freeze
        end

        def remove_value(name)
          value = name.to_s
          raise ArgumentError, 'remove_value requires a value name' if value.empty?

          (@removed_values ||= []) << value
        end

        def resolve_value_identities!(previous)
          @values = MemberIdentity.resolve(
            previous:, declarations: Array(@values), removed: Array(@removed_values)
          ).map(&:freeze)
        end

        def native_definition
          {
            name: @mendix_name.to_s.split('.', 2).last, id: @mendix_id.to_s,
            documentation: @documentation.to_s, values: Array(@values)
          }
        end
      end
    end

    # Editable Mendix constant definition. Private defaults are omitted from
    # generated source and can be supplied locally through process/.env values.
    class Constant
      OPTION_UNSET = Object.new.freeze

      class << self
        attr_reader :mendix_id

        def inherited(child)
          super
          child.instance_variable_set(:@documentation, '')
          child.instance_variable_set(:@type, :string)
          child.instance_variable_set(:@default_supplied, false)
          child.instance_variable_set(:@default_value, nil)
          child.instance_variable_set(:@exposed_to_client, false)
          child.instance_variable_set(:@excluded, false)
          child.instance_variable_set(:@export_level, 'Hidden')
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :constant, @mendix_name, id:)
          Registry.register(:constant, @mendix_name, self)
        end

        def documentation(value = OPTION_UNSET)
          return @documentation.to_s if value.equal?(OPTION_UNSET)

          @documentation = value.to_s
        end

        def type(value = OPTION_UNSET)
          return @type if value.equal?(OPTION_UNSET)

          @type = value.to_sym
        end

        def default(value = OPTION_UNSET)
          return @default_value if value.equal?(OPTION_UNSET)

          @default_supplied = true
          @default_value = value
        end

        def default_from_env(name)
          default ENV.fetch(name.to_s)
        end

        def preserve_default!
          @default_supplied = false
          @default_value = nil
        end

        def exposed_to_client(value = OPTION_UNSET)
          return @exposed_to_client == true if value.equal?(OPTION_UNSET)

          @exposed_to_client = value == true
        end

        def excluded(value = OPTION_UNSET)
          return @excluded == true if value.equal?(OPTION_UNSET)

          @excluded = value == true
        end

        def export_level(value = OPTION_UNSET)
          return @export_level.to_s if value.equal?(OPTION_UNSET)

          @export_level = value.to_s
        end

        def native_definition
          {
            name: @mendix_name.to_s.split('.', 2).last, id: @mendix_id.to_s,
            documentation: @documentation.to_s, type: @type || :string,
            default_supplied: @default_supplied == true, default_value: @default_value,
            exposed_to_client: @exposed_to_client == true, excluded: @excluded == true,
            export_level: @export_level.to_s
          }
        end
      end
    end

    # Authoritative module-role collection with stable Mendix identities.
    class ModuleSecurity
      class << self
        attr_reader :mendix_id, :roles

        def inherited(child)
          super
          child.instance_variable_set(:@roles, [])
          child.instance_variable_set(:@removed_roles, [])
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :module_security, @mendix_name, id:)
          Registry.register(:module_security, @mendix_name, self)
        end

        def module_role(name, id: nil, description: '', renamed_from: nil)
          @roles ||= []
          declaration = { name: name.to_s, id: id.to_s, description: description.to_s }
          declaration[:renamed_from] = renamed_from.to_s unless renamed_from.nil?
          @roles << declaration
        end

        def clear_module_roles! = (@roles = [])

        def remove_module_role(name)
          raise ArgumentError, 'remove_module_role requires a role name' if name.to_s.empty?

          (@removed_roles ||= []) << name.to_s
        end

        def resolve_security_identities!(identities)
          definition = identities.module_security(native_definition, removed_roles: Array(@removed_roles))
          @mendix_id = definition.fetch(:id)
          @roles = definition.fetch(:roles)
        end

        def native_definition
          { module_name: @mendix_name.to_s, id: @mendix_id.to_s, roles: Array(@roles) }
        end
      end
    end

    # Authoritative project-security declaration. Passwords remain private and
    # are only replaced when explicitly supplied by application code.
    class ProjectSecurity
      OPTION_UNSET = Object.new.freeze

      class << self
        attr_reader :user_roles, :demo_user_definitions

        def inherited(child)
          super
          child.instance_variable_set(:@mendix_id, '')
          child.instance_variable_set(:@user_roles, [])
          child.instance_variable_set(:@demo_user_definitions, [])
          child.instance_variable_set(:@settings, {})
          child.instance_variable_set(:@password_policy, nil)
          child.instance_variable_set(:@removed_user_roles, [])
          child.instance_variable_set(:@removed_demo_users, [])
        end

        def mendix_id(value = OPTION_UNSET)
          return @mendix_id.to_s if value.equal?(OPTION_UNSET)

          project_security(id: value)
        end

        def mendix_name = 'project'

        def project_security(id: nil)
          @mendix_id = SourceIdentity.resolve(self, :project_security, 'project', id:)
          Registry.register(:project_security, 'project', self)
        end

        def security_level(value) = (@settings[:security_level] = value.to_s)
        def admin_user_role(value) = (@settings[:admin_user_role] = value.to_s)
        def demo_users(enabled: true) = (@settings[:demo_users_enabled] = enabled == true)
        def sign_in_microflow(value) = (@settings[:sign_in_microflow] = value.to_s)

        def guest_access(enabled: true, role: nil)
          @settings[:guest_access_enabled] = enabled == true
          @settings[:guest_user_role] = role.to_s
        end

        def user_role(name, id: nil, guid: nil, description: '', check_security: true,
                      manageable_roles: [], manage_all_roles: false,
                      manage_users_without_roles: false, module_roles: [], renamed_from: nil)
          @user_roles ||= []
          declaration = {
            name: name.to_s, id: id.to_s, guid: guid.to_s,
            description: description.to_s, check_security: check_security == true,
            manageable_roles: Array(manageable_roles).map(&:to_s),
            manage_all_roles: manage_all_roles == true,
            manage_users_without_roles: manage_users_without_roles == true,
            module_roles: Array(module_roles).map(&:to_s)
          }
          declaration[:renamed_from] = renamed_from.to_s unless renamed_from.nil?
          @user_roles << declaration
        end

        def clear_user_roles! = (@user_roles = [])

        def demo_user(name, entity:, roles:, id: nil, password: nil, renamed_from: nil)
          @demo_user_definitions ||= []
          declaration = {
            name: name.to_s, id: id.to_s, entity: entity.to_s,
            roles: Array(roles).map(&:to_s), password: password
          }
          declaration[:renamed_from] = renamed_from.to_s unless renamed_from.nil?
          @demo_user_definitions << declaration
        end

        def clear_demo_users! = (@demo_user_definitions = [])

        def remove_user_role(name)
          raise ArgumentError, 'remove_user_role requires a role name' if name.to_s.empty?

          (@removed_user_roles ||= []) << name.to_s
        end

        def remove_demo_user(name)
          raise ArgumentError, 'remove_demo_user requires a user name' if name.to_s.empty?

          (@removed_demo_users ||= []) << name.to_s
        end

        def resolve_security_identities!(identities)
          definition = identities.project_security(
            native_definition, removed_user_roles: Array(@removed_user_roles),
                               removed_demo_users: Array(@removed_demo_users)
          )
          @mendix_id = definition.fetch(:id)
          @user_roles = definition.fetch(:user_roles)
          @demo_user_definitions = definition.fetch(:demo_users)
          @password_policy = definition[:password_policy]
        end

        def password_policy(id: nil, properties: {}, **options, &block)
          values = properties.to_h.merge(options)
          if block
            builder = PasswordPolicyBuilder.new(values)
            builder.evaluate(&block)
            values = builder.properties
          end
          @password_policy = {
            id: id.to_s,
            properties: values.transform_keys(&:to_s)
          }
        end

        def native_definition
          @settings.to_h.merge(
            id: @mendix_id.to_s, user_roles: Array(@user_roles),
            demo_users: Array(@demo_user_definitions), password_policy: @password_policy
          )
        end
      end
    end

    # Editable Mendix scheduled event, including its nested schedule identity
    # and version-specific schedule properties.
    class ScheduledEvent
      OPTION_UNSET = Object.new.freeze

      class << self
        attr_reader :mendix_id

        def inherited(child)
          super
          child.instance_variable_set(
            :@definition,
            { documentation: '', export_level: 'Hidden', enabled: true, interval: 1 }
          )
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :scheduled_event, @mendix_name, id:)
          Registry.register(:scheduled_event, @mendix_name, self)
        end

        def documentation(value) = (@definition[:documentation] = value.to_s)
        def export_level(value) = (@definition[:export_level] = value.to_s)
        def unbound = (@definition[:unbound] = true)
        def microflow(value) = (@definition[:microflow] = value.to_s)
        def start_at(value) = (@definition[:start_at] = value)
        def time_zone(value) = (@definition[:time_zone] = value.to_s)
        def on_overlap(value) = (@definition[:on_overlap] = value.to_s)
        def enabled(value: true) = (@definition[:enabled] = value == true)
        def interval_type(value) = (@definition[:interval_type] = value.to_s)
        def interval(value) = (@definition[:interval] = Integer(value))

        def schedule(type, id: nil, properties: {}, **options, &block)
          values = properties.to_h.merge(options)
          definition = if block
                         ScheduleBuilder.new(type, id:, properties: values).evaluate(&block).build.to_h
                       else
                         { type: type.to_s, id: id.to_s, properties: values.transform_keys(&:to_s) }
                       end
          @definition[:schedule] = definition
        end

        def native_definition
          @definition.to_h.merge(
            name: @mendix_name.to_s.split('.', 2).last,
            qualified_name: @mendix_name.to_s, id: @mendix_id.to_s
          )
        end
      end
    end

    # Flow baselines belong to the exporting application's private sidecar.
    # Scope the lookup to source loading so application roots cannot leak
    # metadata into each other or into newly authored services.
    class FlowMetadata
      THREAD_KEY = :mxrb_ruby_app_flow_metadata

      def self.with(manifest)
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = new(manifest)
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      def self.for(unit_id, native_type)
        Thread.current[THREAD_KEY]&.fetch(unit_id, native_type)
      end

      def self.validate!(unit_id, native_type, builder)
        context = Thread.current[THREAD_KEY]
        return unless context&.registered?(unit_id, native_type)
        return unless builder.expected_body_fingerprint.to_s.empty?

        raise ValidationError, 'existing Ruby flow requires its semantic metadata baseline or a legacy body fingerprint'
      end

      def initialize(manifest)
        @entries = {}
        @registered = manifest.modules.flat_map do |mod|
          { 'services' => 'Microflows$Microflow', 'nanoflows' => 'Microflows$Nanoflow' }.flat_map do |key, native_type|
            Array(mod[key]).map { [_1.fetch('id').to_s, native_type] }
          end
        end.to_set
        path = File.join(manifest.root, '.mxrb', 'semantic_metadata.json')
        unless File.file?(path)
          path = File.join(File.dirname(manifest.absolute_path('mendix_project')), '.mxrb', 'semantic_metadata.json')
        end
        return unless File.file?(path)

        modules = JSON.parse(File.read(path)).fetch('modules', {})
        modules.each_value do |mod|
          mod.fetch('flows', {}).each_value do |metadata|
            (metadata.is_a?(Array) ? metadata : [metadata]).each { index(_1) }
          end
        end
      rescue JSON::ParserError => e
        raise SerializationError, "invalid flow metadata sidecar #{path}: #{e.message}"
      end

      def fetch(unit_id, native_type) = @entries[[unit_id.to_s, native_type.to_s]]
      def registered?(unit_id, native_type) = @registered.include?([unit_id.to_s, native_type.to_s])

      private

      def index(metadata)
        key = [metadata.fetch('unit_id', '').to_s, metadata.fetch('native_type', '').to_s]
        return if key.any?(&:empty?)

        previous = @entries[key]
        raise ValidationError, 'conflicting flow metadata identities' if previous && previous != metadata

        @entries[key] = metadata
      end
    end

    # Base for generated services. The default body executes through MXRB's
    # pure-Ruby native interpreter and can be replaced with idiomatic Ruby.
    class Service
      class << self
        attr_reader :mendix_id, :native_definition, :native_kind, :controller_definition

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :service, @mendix_name, id:)
          Registry.register(:service, @mendix_name, self, unit_id: @mendix_id)
        end

        # Declares how this Ruby service materializes as a Mendix flow. The
        # typed block is ordinary editable Ruby and supports both runtimes.
        def flow(kind = :microflow, public: false, &block)
          qualified = require_qualified_mendix_name!
          runtime, flow_kind = case kind.to_sym
                               when :microflow then %i[server use_case]
                               when :nanoflow then %i[client client_action]
                               else
                                 raise ArgumentError, 'flow kind must be microflow or nanoflow'
                               end
          unit_id = native_unit_id(kind)
          SourceIdentity.validate_flow!(self, kind)
          @mendix_id = unit_id if @mendix_id.to_s.empty?
          native_type = kind.to_sym == :nanoflow ? 'Microflows$Nanoflow' : 'Microflows$Microflow'
          builder = Dsl::FlowBuilder.new(
            qualified.split('.', 2).last,
            runtime:, kind: flow_kind, public:, unit_id:, metadata: FlowMetadata.for(unit_id, native_type)
          )
          builder.instance_eval(&block) if block
          FlowMetadata.validate!(unit_id, native_type, builder)
          @native_kind = kind.to_sym
          @native_definition = builder.to_h
        end

        # Compatibility for Ruby applications exported before `flow` became
        # the public, domain-oriented name.
        alias native flow

        def controller(controller_class, action:)
          unless controller_class.is_a?(String) || controller_class.is_a?(Symbol) ||
                 (controller_class.is_a?(Class) && controller_class <= Controller)
            raise ArgumentError, 'controller must be a registered name or RubyApp::Controller class'
          end

          action_name = action.to_sym
          raise ArgumentError, 'controller action cannot be empty' if action_name.to_s.empty?

          @controller_definition = { controller: controller_class, action: action_name }.freeze
        end

        private

        def require_qualified_mendix_name!
          value = @mendix_name.to_s
          return value if value.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)

          raise ArgumentError, 'call mendix_name with Module.Document before flow'
        end

        def native_unit_id(kind)
          return @mendix_id unless @mendix_id.to_s.empty?

          hex = Digest::SHA1.hexdigest("mxrb:ruby:#{kind}:#{@mendix_name}")
          "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
        end
      end

      def initialize(application, context: nil)
        @application = application
        @context = context
      end

      def call(**arguments) = native_call(arguments)

      private

      def execute_flow(arguments) = native_call(arguments)

      def native_call(arguments)
        if (definition = self.class.controller_definition)
          controller_class = definition.fetch(:controller)
          unless controller_class.is_a?(Class)
            controller_class = Registry.fetch(:controller, controller_class.to_s)
            raise ValidationError, "controller #{definition.fetch(:controller)} is not registered" \
              unless controller_class
          end
          controller = controller_class.new(@application, context: @context)
          return controller.public_send(definition.fetch(:action), **arguments.transform_keys(&:to_sym))
        end

        @application.native_call(self.class.mendix_name, arguments, context: @context)
      end
    end

    # Page metadata remains ordinary Ruby while the browser receives its JSON
    # projection from the integrated backend.
    class Page
      extend PageDataSources

      # Builds the runtime-facing widget projection without making the page an
      # authoritative native document. This keeps exported pages lossless via
      # the MPR sidecar while presenting their structure as editable Ruby.
      class WidgetTree
        include Dsl::WidgetComposite
        include Dsl::WidgetEvents
        include NativeFragmentAccess
        include PageDataSources

        OPTION_UNSET = Object.new.freeze
        STRUCTURED_METHODS = %i[data_view layout_grid native_widget tab_control table].freeze
        WIDGET_METHODS = %i[
          button check_box container data_grid data_view date_picker drop_down gallery
          file_manager image_uploader image_viewer native_widget layout_grid menu_bar
          navigation_list navigation_tree number_input page_title
          pluggable_widget radio_button_group reference_selector reference_set_selector
          scroll_container snippet static_image tab_control table text text_area text_box
        ].freeze

        attr_reader :widgets

        def initialize(event_owner: false, property_owner: nil)
          @widgets = []
          @events = []
          @event_owner = event_owner
          @property_owner = property_owner
          initialize_widget_composite(
            key_transform: :to_s.to_proc,
            path_normalizer: method(:normalize),
            child_factory: -> { self.class.new }
          )
        end

        def widget(type, name = '', options: {}, events: OPTION_UNSET, caption: OPTION_UNSET, &block)
          options = normalize(options)
          value = { 'type' => type.to_s, 'name' => name.to_s }
          value['options'] = options unless options.empty?
          caption = options['caption'] if caption.equal?(OPTION_UNSET) && options.key?('caption')
          value['caption'] = caption unless caption.equal?(OPTION_UNSET) || caption.to_s.empty?
          explicit_events = !events.equal?(OPTION_UNSET)
          normalized_events = explicit_events ? normalize(events) : []
          value['events'] = normalized_events unless normalized_events.empty?

          if block
            property_owner = if type.to_s == 'pluggable_widget'
                               { name: name.to_s, widget_id: options['widget_id'], legacy: options.key?('properties') }
                             end
            content = self.class.new(event_owner: true, property_owner:)
            block.arity.zero? ? content.instance_eval(&block) : block.call(content)
            if explicit_events && content.send(:widget_event_collection).any?
              raise ArgumentError, 'widget accepts either events: or typed event declarations'
            end

            content.send(:append_to, value)
          end

          @widgets << value
          value
        end

        def properties(&block)
          raise ArgumentError, 'properties must belong to a pluggable widget' unless @property_owner
          raise ArgumentError, 'properties requires a block' unless block
          if @property_owner.fetch(:legacy)
            raise ArgumentError, 'widget accepts either properties: or a properties block'
          end

          raise ArgumentError, 'widget accepts only one properties block' if @pluggable_properties

          bridge = PluggableProperties.for_widget(
            @property_owner.fetch(:name), widget_id: @property_owner.fetch(:widget_id)
          )
          @pluggable_properties = bridge.evaluate(&block).to_projection
        end

        (WIDGET_METHODS - STRUCTURED_METHODS).each do |type|
          define_method(type) do |name = '', caption: OPTION_UNSET, events: OPTION_UNSET, **options, &block|
            options[:class] = options.delete(:class_name) if options.key?(:class_name)
            options[:caption] = caption unless caption.equal?(OPTION_UNSET)
            widget(type, name, options:, events:, &block)
          end
        end

        def table(name = '', width_unit: :weight, tab_index: 0, class_name: nil, style: nil,
                  dynamic_class: nil, visible: nil, &block)
          builder = Dsl::TableBuilder.new(
            name, width_unit:, tab_index:, class_name:, style:, dynamic_class:, visible:
          )
          builder.instance_eval(&block) if block
          append_structured(builder)
        end

        def layout_grid(name = '', width: :full, tab_index: 0, class_name: nil, style: nil,
                        dynamic_class: nil, visible: nil, &block)
          builder = Dsl::LayoutGridBuilder.new(
            name, width:, tab_index:, class_name:, style:, dynamic_class:, visible:
          )
          builder.instance_eval(&block) if block
          append_structured(builder)
        end

        def data_view(name = '', from:, editable: Dsl::UNSET, read_only_style: Dsl::UNSET,
                      label_width: Dsl::UNSET, show_footer: Dsl::UNSET,
                      no_entity_message: Dsl::UNSET, tab_index: Dsl::UNSET,
                      class_name: Dsl::UNSET, style: Dsl::UNSET,
                      dynamic_class: Dsl::UNSET, &block)
          builder = Dsl::DataViewBuilder.new(
            name, from:, editable:, read_only_style:, label_width:, show_footer:,
                  no_entity_message:, tab_index:, class_name:, style:, dynamic_class:
          )
          builder.instance_eval(&block) if block
          append_structured(builder, declared_fields: false)
        end

        def tab_control(name = '', **options, &block)
          builder = Dsl::WidgetBuilder.new(:tab_control, name, **options)
          builder.instance_eval(&block) if block
          append_structured(builder, declared_fields: false)
        end

        def native_widget(name = '', type:, deep_structure:)
          raise ArgumentError, 'deep_structure requires a Hash' unless deep_structure.is_a?(Hash)

          value = {
            type: :native_widget, name: name.to_s,
            options: { native_type: type.to_s, deep_structure: }, events: []
          }
          append_structured(value, declared_fields: false)
        end

        def grid_column(name, attribute: nil, caption: nil, filter: nil)
          builder = Dsl::WidgetBuilder.new(:data_grid, '')
          normalize(builder.column(name, attribute:, caption:, filter:).last)
        end

        def sort_by(attribute, direction: 'Ascending')
          { 'attribute' => attribute.to_s, 'direction' => direction.to_s }
        end

        private

        def append_to(value)
          (value['options'] ||= {})['properties'] = @pluggable_properties if @pluggable_properties
          value['events'] = normalize(@events) unless @events.empty?
          append_widget_composite(value, children: @widgets)
        end

        def widget_event_collection
          raise ArgumentError, 'event declarations must belong to a widget' unless @event_owner

          @events
        end

        def append_structured(builder, declared_fields: true)
          value = normalize(builder.to_h)
          value.delete('events') if Array(value['events']).empty?
          value.delete('declared_fields') unless declared_fields
          @widgets << value
          value
        end

        def normalize(value)
          case value
          when Hash then value.to_h { |key, child| [key.to_s, normalize(child)] }
          when Array then value.map { normalize(_1) }
          when Symbol then value.to_s
          else value
          end
        end
      end

      class << self
        attr_reader :mendix_id, :title, :widgets, :appearance_class,
                    :appearance_style, :data_source, :native_definition,
                    :navigation_definition

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :page, @mendix_name, id:)
          Registry.register(:page, @mendix_name, self)
        end

        def configure(title:, widgets: nil, appearance_class: '', appearance_style: '', data_source: nil,
                      &block)
          raise ArgumentError, 'configure accepts either widgets: or a widget block, not both' \
            if widgets && block

          title = title.to_s
          appearance_class = appearance_class.to_s
          appearance_style = appearance_style.to_s
          widgets = if block
                      tree = WidgetTree.new
                      PluggableProperties.with_page(mendix_id) do
                        block.arity.zero? ? tree.instance_eval(&block) : block.call(tree)
                      end
                      tree.widgets.freeze
                    else
                      Array(widgets).freeze
                    end
          widgets = PageDesignIdentity.configure(self, widgets).freeze
          @title = title
          @widgets = widgets
          @appearance_class = appearance_class
          @appearance_style = appearance_style
          @data_source = data_source
        end

        # Declares an editable native Mendix page with the typed page/widget
        # DSL. Existing exported pages may keep using #configure and remain
        # untouched; only pages with #native are synchronized back to the MPR.
        def native(&block)
          qualified = require_qualified_mendix_name!
          builder = Dsl::PageBuilder.new(qualified.split('.', 2).last)
          builder.instance_eval(&block) if block
          definition = builder.to_h.merge(unit_id: native_unit_id)
          @native_definition = definition
          @title = definition.fetch(:title).to_s
          @widgets = definition.fetch(:widgets).freeze
          @data_source = definition[:data_source]
          @appearance_class ||= ''
          @appearance_style ||= ''
          definition
        end

        # Adds or updates one navigation item without replacing unrelated
        # native menu entries. Set home: true only when this page must become
        # the profile's home page.
        def navigation(caption:, profile: 'Responsive', icon: nil, home: false)
          qualified = require_qualified_mendix_name!
          @navigation_definition = {
            page: qualified, caption:, profile: profile.to_s, icon:, home: home == true
          }
        end

        private

        def require_qualified_mendix_name!
          value = @mendix_name.to_s
          return value if value.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)

          raise ArgumentError, 'call mendix_name with Module.Document before native'
        end

        def native_unit_id
          return @mendix_id unless @mendix_id.to_s.empty?

          hex = Digest::SHA1.hexdigest("mxrb:ruby:page:#{@mendix_name}")
          "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
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
          service = Registry.fetch(:service, name.to_s)
          kind = service&.native_kind == :nanoflow ? :nanoflow : :microflow
          authorize_document!(kind, name, :execute, context)
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
          if !object && value['transient'] == true
            object = Runtime::Native::ObjectValue.new(
              entity: value['type'].to_s, id: value['id'].to_s, members: {}
            )
            value.fetch('attributes', {}).each do |member, member_value|
              object.members[member.to_s] = deserialize(member_value, context:, synchronize:)
            end
          end
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
          store.commit(object) if value['transient'] != true && store.respond_to?(:commit)
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
      def initialize(root, target, manifest: Manifest.load(root), rebase_member_identities: false)
        @root = File.expand_path(root)
        @target = File.expand_path(target)
        @manifest = manifest
        @rebase_member_identities = rebase_member_identities
      end

      def synchronize!
        Registry.reset!
        project = Model::Project.open(@target, readonly: false)
        Environment.load(root: @root).with do
          identity_project = project if @rebase_member_identities
          @source_identities = RubyApp.load_sources(@manifest, member_identity_project: identity_project)
        end
        @source_identities.validate_entity_names!
        preflight_regular_expressions!(project)
        synchronize_regular_expression_definitions(project)
        synchronize_constant_definitions(project)
        synchronize_enumeration_definitions(project)
        synchronize_module_security(project)
        synchronize_project_security(project)
        synchronize_entity_structures(project, existing_only: true)
        synchronize_entity_access(project, existing_only: true)
        synchronize_entities(project)
        synchronize_entity_structures(project, existing_only: false)
        synchronize_entity_access(project, existing_only: false)
        synchronize_associations(project)
        synchronize_entity_behaviors(project)
        prune_constants(project)
        prune_enumerations(project)
        synchronize_native_documents(project)
        synchronize_scheduled_events(project)
        @source_identities.reconcile!(project)
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
        files << @source_identities.bundle if @source_identities
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
        (registered.keys - source_names).each do |name|
          implementation = registered.fetch(name)
          if project.find_artifact(name, kind: :entity)
            synchronize_entity(project, name, implementation)
          else
            add_entity(project, name, implementation)
          end
        end
        (source_names & registered.keys).each { synchronize_entity(project, _1, registered.fetch(_1)) }
      end

      def synchronize_enumeration_definitions(project)
        enumerations = Registry.all(:enumeration).values.group_by do |implementation|
          module_name(implementation.mendix_name)
        end
        return if enumerations.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        enumerations.each do |name, implementations|
          writer.synchronize_ruby_enumerations!(
            project.mpr, module_name: name,
                         enumerations: implementations.map(&:native_definition)
          )
        end
        project.refresh!
      end

      def preflight_regular_expressions!(project)
        registered = Registry.all(:regular_expression).values.group_by { module_name(_1.mendix_name) }
        sources = @manifest.modules.to_h do |mod|
          [mod.fetch('name'), mod.fetch('regular_expressions', [])]
        end
        @regular_expression_changes = {}
        return if registered.empty? && sources.values.all?(&:empty?)

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        (sources.keys + registered.keys).uniq.each do |name|
          declarations = Array(registered[name]).map(&:native_definition)
          baseline = sources.fetch(name, [])
          next if declarations.empty? && baseline.empty?

          declarations = declarations.map do |declaration|
            prior = baseline.find { _1.fetch('id').to_s == declaration[:id].to_s }
            next declaration unless prior

            absent = RegularExpression::FIELDS.values - prior.fetch('properties').keys -
                     declaration.fetch(:properties).keys
            declaration.merge(absent_properties: absent)
          end

          retained_ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
          retained_names = Array(registered[name]).map(&:mendix_name)
          removed = baseline.reject do |entry|
            retained_ids.include?(entry.fetch('id').to_s) || retained_names.include?(entry.fetch('name'))
          end
          remove_ids = removed.map { _1.fetch('id') }
          plan = writer.plan_ruby_regular_expressions(project.mpr, module_name: name,
                                                                   expressions: declarations, remove_ids:)
          plan.fetch(:changes).each do |declaration, raw, previous|
            next unless previous && previous['Name'].to_s != declaration.fetch(:name).to_s

            validate_regular_expression_references!(project, raw, "#{name}.#{previous['Name']}", :rename)
          end
          removed.each do |entry|
            raw = project.mpr.unit(entry.fetch('id'))
            validate_regular_expression_references!(project, raw, entry.fetch('name'), :remove)
          end
          @regular_expression_changes[name] = { expressions: declarations, remove_ids: }
        end
      end

      def validate_regular_expression_references!(project, raw, name, operation)
        artifact = project.semantic_index.artifacts.find { _1.unit_id == raw.fetch('UnitID') }
        raise ValidationError, 'regular-expression reference baseline is unavailable' unless artifact

        incoming = project.references_to(artifact).reject { _1.source.id == artifact.id }
        explicit = project.all_units.any? do |unit|
          regular_expression_reference?(project.parse_bson(unit), name)
        end
        children = project.children_of(raw.fetch('UnitID'))
        return if incoming.empty? && !explicit && children.empty?

        raise ValidationError, "cannot #{operation} referenced regular expression #{name}"
      end

      def regular_expression_reference?(value, name)
        case value
        when Hash
          value['RegExIdentifier'] == name || value.values.any? { regular_expression_reference?(_1, name) }
        when Array then value.any? { regular_expression_reference?(_1, name) }
        else false
        end
      end

      def synchronize_regular_expression_definitions(project)
        return if @regular_expression_changes.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        @regular_expression_changes.each do |name, options|
          writer.synchronize_ruby_regular_expressions!(project.mpr, module_name: name, **options)
        end
        project.refresh!
      end

      def synchronize_constant_definitions(project)
        constants = Registry.all(:constant).values.group_by do |implementation|
          module_name(implementation.mendix_name)
        end
        return if constants.empty?

        validate_constant_renames!(project)
        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        constants.each do |name, implementations|
          writer.synchronize_ruby_constants!(
            project.mpr, module_name: name,
                         constants: implementations.map(&:native_definition)
          )
        end
        project.refresh!
      end

      def synchronize_module_security(project)
        declarations = Registry.all(:module_security).values
        return if declarations.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        declarations.each do |implementation|
          writer.synchronize_ruby_module_security!(
            project.mpr, module_name: implementation.mendix_name,
                         security: implementation.native_definition
          )
        end
        project.refresh!
      end

      def synchronize_project_security(project)
        implementation = Registry.all(:project_security).values.first
        return unless implementation

        Writer.new(@target, version: project.mendix_version, modules: [])
              .synchronize_ruby_project_security!(
                project.mpr, security: implementation.native_definition
              )
        project.refresh!
      end

      def synchronize_scheduled_events(project)
        registered = Registry.all(:scheduled_event).values.group_by do |implementation|
          module_name(implementation.mendix_name)
        end
        authoritative_modules = @manifest.modules.select do |mod|
          mod['scheduled_events_authoritative'] == true
        end
        manifest_modules = authoritative_modules.map { _1.fetch('name') }
        modules = (manifest_modules + registered.keys).uniq
        return if modules.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        modules.each do |name|
          writer.synchronize_ruby_scheduled_events!(
            project.mpr, module_name: name,
                         events: Array(registered[name]).map(&:native_definition)
          )
        end
        project.refresh!
      end

      def validate_constant_renames!(project)
        source_by_id = @manifest.modules.flat_map { _1.fetch('constants', []) }
                                .to_h { [_1.fetch('id', '').to_s, _1] }
        Registry.all(:constant).each_value do |implementation|
          id = implementation.mendix_id.to_s
          source = source_by_id[id]
          next unless source && source.fetch('name') != implementation.mendix_name

          artifact = project.find_artifact(source.fetch('name'))
          incoming = artifact ? project.references_to(artifact) : []
          next if incoming.empty?

          raise ValidationError,
                "cannot rename constant #{source.fetch('name')}: " \
                "#{incoming.size} incoming reference(s)"
        end
        nil
      end

      def prune_constants(project)
        registered = Registry.all(:constant)
        registered_ids = registered.values.map(&:mendix_id).reject(&:empty?)
        @manifest.modules.flat_map { _1.fetch('constants', []) }.each do |source|
          retained = registered.key?(source.fetch('name')) ||
                     registered_ids.include?(source.fetch('id', '').to_s)
          next if retained

          plan = project.plan_remove(source.fetch('name'))
          unless plan.safe?
            raise ValidationError,
                  "cannot remove constant #{source.fetch('name')}: " \
                  "#{plan.incoming.size} incoming reference(s), #{plan.children.size} child unit(s)"
          end

          plan.apply!
        end
      end

      def prune_enumerations(project)
        registered = Registry.all(:enumeration)
        registered_ids = registered.values.map(&:mendix_id).reject(&:empty?)
        @manifest.modules.flat_map { _1.fetch('enumerations', []) }.each do |source|
          retained = registered.key?(source.fetch('name')) ||
                     registered_ids.include?(source.fetch('id', '').to_s)
          next if retained

          attribute_references = enumeration_attribute_references(project, source.fetch('name'))
          unless attribute_references.empty?
            raise ValidationError,
                  "cannot remove enumeration #{source.fetch('name')}: incoming reference(s) from " \
                  "#{attribute_references.join(', ')}"
          end

          plan = project.plan_remove(source.fetch('name'))
          unless plan.safe?
            raise ValidationError,
                  "cannot remove enumeration #{source.fetch('name')}: " \
                  "#{plan.incoming.size} incoming reference(s), #{plan.children.size} child unit(s)"
          end

          plan.apply!
        end
      end

      def enumeration_attribute_references(project, enumeration_name)
        project.modules.flat_map do |mod|
          mod.entities.flat_map do |entity|
            entity.attributes.filter_map do |attribute|
              next unless attribute.respond_to?(:enumeration) &&
                          attribute.enumeration.to_s == enumeration_name

              "#{mod.name}.#{entity.name}/#{attribute.name}"
            end
          end
        end
      end

      def synchronize_native_documents(project)
        services = Registry.all(:service).values.select(&:native_definition)
        pages = if File.exist?(File.join(@root, '.mxrb', 'preserve_native_pages'))
                  []
                else
                  Registry.all(:page).values.select(&:native_definition)
                end
        modules = (services + pages).group_by { module_name(_1.mendix_name) }
        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        modules.each do |name, implementations|
          module_services = implementations.grep(Class).select { _1 <= Service }
          module_pages = implementations.grep(Class).select { _1 <= Page }
          writer.synchronize_ruby_documents!(
            project.mpr, module_name: name,
                         pages: module_pages.map(&:native_definition),
                         microflows: module_services.select { _1.native_kind == :microflow }
                                                    .map(&:native_definition),
                         nanoflows: module_services.select { _1.native_kind == :nanoflow }
                                                   .map(&:native_definition),
                         navigation_items: module_pages.filter_map(&:navigation_definition)
          )
        end
        project.refresh!
      end

      def synchronize_associations(project)
        records = Registry.all(:record).values.group_by { module_name(_1.mendix_name) }
        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        records.each do |name, implementations|
          writer.synchronize_ruby_associations!(
            project.mpr, module_name: name,
                         entities: implementations.map do |implementation|
                           {
                             name: qualified_parts(implementation.mendix_name).last,
                             associations: implementation.associations.to_a,
                             oql_view: implementation.oql_view_definition
                           }
                         end
          )
        end
        project.refresh!
      end

      def synchronize_entity_access(project, existing_only:)
        existing_names = project.modules.flat_map do |mod|
          mod.entities.map { "#{mod.name}.#{_1.name}" }
        end
        existing = existing_names.to_h { [_1, true] }
        records = Registry.all(:record).values.reject { _1.access_rules.nil? }
        records.select! { existing.key?(_1.mendix_name) } if existing_only
        records = records.group_by { module_name(_1.mendix_name) }
        return if records.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        records.each do |name, implementations|
          writer.synchronize_ruby_entity_access!(
            project.mpr, module_name: name,
                         entities: implementations.map do |implementation|
                           {
                             name: qualified_parts(implementation.mendix_name).last,
                             access_rules: implementation.access_rules
                           }
                         end
          )
        end
        project.refresh!
      end

      def synchronize_entity_structures(project, existing_only:)
        existing_names = project.modules.flat_map do |mod|
          mod.entities.map { "#{mod.name}.#{_1.name}" }
        end
        existing = existing_names.to_h { [_1, true] }
        records = Registry.all(:record).values.reject do |implementation|
          implementation.indexes.nil? && implementation.system_members.nil? &&
            implementation.generalization.nil? && implementation.oql_view_definition.nil?
        end
        records.select! { existing.key?(_1.mendix_name) } if existing_only
        records = records.group_by { module_name(_1.mendix_name) }
        return if records.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        records.each do |name, implementations|
          writer.synchronize_ruby_entity_structures!(
            project.mpr, module_name: name,
                         entities: implementations.map do |implementation|
                           {
                             name: qualified_parts(implementation.mendix_name).last,
                             indexes: implementation.indexes,
                             system_members: implementation.system_members,
                             generalization: implementation.generalization,
                             oql_view: implementation.oql_view_definition
                           }
                         end
          )
        end
        project.refresh!
      end

      def synchronize_entity_behaviors(project)
        implementations = Registry.all(:record).values.reject do |implementation|
          implementation.native_lifecycle_definitions.nil? && implementation.validation_rules.nil?
        end
        records = implementations.group_by { module_name(_1.mendix_name) }
        return if records.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        records.each do |name, implementations|
          writer.synchronize_ruby_entity_behaviors!(
            project.mpr, module_name: name,
                         entities: implementations.map do |implementation|
                           {
                             name: qualified_parts(implementation.mendix_name).last,
                             lifecycle: implementation.native_lifecycle_definitions,
                             validation_rules: implementation.validation_rules
                           }
                         end
          )
        end
        project.refresh!
      end

      def module_name(qualified)
        qualified_parts(qualified).first
      end

      def add_entity(project, name, implementation)
        module_name, entity_name = qualified_parts(name)
        attributes = implementation.attributes.to_a.map do |attribute|
          {
            name: attribute.fetch(:mendix_name), type: attribute.fetch(:type),
            default: attribute[:default], required: attribute.fetch(:required, false),
            unique: attribute.fetch(:unique, false), documentation: attribute[:documentation],
            length: attribute[:length], localize_date: attribute[:localize_date],
            enumeration: attribute[:enumeration]
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
          project.plan_add_attribute(
            entity_name, name:, type: declaration.fetch(:type),
                         default: declaration[:default], required: declaration.fetch(:required, false),
                         unique: declaration.fetch(:unique, false),
                         documentation: declaration[:documentation], length: declaration[:length],
                         localize_date: declaration[:localize_date], enumeration: declaration[:enumeration]
          ).apply!
        end
        (declared.keys & existing.keys).each do |name|
          synchronize_attribute(project, entity_name, existing.fetch(name), declared.fetch(name))
        end
      end

      def synchronize_attribute(project, entity_name, attribute, declaration)
        updates = {}
        declared_required = declaration.fetch(:required, false)
        updates[:required] = declared_required if (attribute.required == true) != declared_required
        declared_unique = declaration.fetch(:unique, false)
        existing_unique = attribute.respond_to?(:unique) && attribute.unique == true
        updates[:unique] = declared_unique if existing_unique != declared_unique
        declared_type = declaration.fetch(:type).to_sym
        updates[:type] = declared_type if attribute.type != declared_type
        current_default = attribute.default_value.to_s
        declared_default = declaration[:default].to_s
        updates[:default] = declaration[:default] if current_default != declared_default
        if declaration.key?(:documentation)
          declared_documentation = declaration[:documentation].to_s
          existing_documentation = attribute.documentation if attribute.respond_to?(:documentation)
          updates[:documentation] = declared_documentation \
            if existing_documentation.to_s != declared_documentation
        end
        if declaration.key?(:length)
          declared_length = declaration[:length]
          declared_length = Model::Attribute::DEFAULT_STRING_LENGTH \
            if declared_type == :string && declared_length.nil?
          existing_length = attribute.length if attribute.respond_to?(:length)
          updates[:length] = declared_length if existing_length != declared_length
        end
        if declaration.key?(:localize_date)
          declared_localize_date = declaration[:localize_date]
          declared_localize_date = false if declared_type == :datetime && declared_localize_date.nil?
          existing_localize_date = attribute.localize_date if attribute.respond_to?(:localize_date)
          updates[:localize_date] = declared_localize_date \
            if existing_localize_date != declared_localize_date
        end
        if declaration.key?(:enumeration)
          existing_enumeration = attribute.enumeration if attribute.respond_to?(:enumeration)
          updates[:enumeration] = declaration[:enumeration] \
            if existing_enumeration.to_s != declaration[:enumeration].to_s
        end
        return if updates.empty?

        project.plan_change_attribute("#{entity_name}/#{attribute.name}", **updates).apply!
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
        @logger = logger
      end

      def start
        @server = Http::Server.new(host:, port:, logger: @logger) { dispatch(_1, _2) }
        application.start_scheduler
        @server.start { yield(_1) if block_given? }
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
          set_session_cookie(response, session.fetch(:token))
          public_session = session.reject { |key, _value| key == :token }
          return render_json(response, 200, { ok: true }.merge(public_session))
        end

        authorization = request_authorization(request)
        validate_csrf!(request, authorization) if unsafe_request?(method) && cookie_authenticated?(request)
        context = @sessions.authenticate(authorization)
        if method == 'GET' && path == '/api/session'
          return render_json(
            response, 200,
            user: context.user, roles: context.user_roles, module_roles: context.module_roles,
            csrf: @sessions.csrf_token(authorization)
          )
        end
        if method == 'POST' && path == '/api/logout'
          logged_out = @sessions.logout(authorization)
          clear_session_cookie(response)
          return render_json(response, 200, ok: logged_out)
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
          return render_json(response, 401, error('unauthorized', 'Authenticated session required')) \
            if route['requires_authentication'] && authorization.to_s.empty?

          body = request.body.to_s.empty? ? nil : request_json(request)
          route_context = if !route['requires_authentication'] && authorization.to_s.empty?
                            nil
                          else
                            context
                          end
          result = application.invoke_rest(
            route, path_parameters:, query: request.query.to_h, body:, context: route_context
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
      rescue NotFoundError => e
        render_json(response, 404, error('not_found', e.message))
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

      def request_authorization(request)
        header = request['Authorization'].to_s
        return header unless header.empty?

        token = request['Cookie'].to_s.split(';').filter_map do |part|
          name, value = part.strip.split('=', 2)
          value if name == 'mxrb_session'
        end.first
        token && "Bearer #{token}"
      end

      def cookie_authenticated?(request)
        request['Authorization'].to_s.empty? && request['Cookie'].to_s.match?(/(?:\A|;\s*)mxrb_session=/)
      end

      def unsafe_request?(method) = !%w[GET HEAD OPTIONS].include?(method)

      def validate_csrf!(request, authorization)
        return if @sessions.valid_csrf?(authorization, request['X-CSRF-Token'])

        raise AuthenticationError, 'invalid or missing CSRF token'
      end

      def set_session_cookie(response, token)
        attributes = ["mxrb_session=#{token}", 'Path=/', 'HttpOnly', 'SameSite=Strict',
                      "Max-Age=#{@sessions.ttl}"]
        attributes << 'Secure' if ENV['MXRB_SECURE_COOKIES'] == 'true'
        response['Set-Cookie'] = attributes.join('; ')
      end

      def clear_session_cookie(response)
        response['Set-Cookie'] = 'mxrb_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0'
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
        headers = {
          'Authorization' => environment['HTTP_AUTHORIZATION'].to_s,
          'Cookie' => environment['HTTP_COOKIE'].to_s,
          'X-CSRF-Token' => environment['HTTP_X_CSRF_TOKEN'].to_s
        }
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
          wait_for_process(@frontend_pid, 'frontend')
        elsif @backend_pid
          wait_for_process(@backend_pid, 'backend')
        else
          @backend.join
        end
      rescue Interrupt, Errno::ECHILD
        nil
      ensure
        shutdown
      end

      def shutdown
        @shutting_down = true
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

      def wait_for_process(pid, label)
        _waited, status = Process.wait2(pid)
        return if status.success? || @shutting_down

        reason = status.exitstatus ? "status #{status.exitstatus}" : "signal #{status.termsig}"
        raise Error, "#{label} process exited with #{reason}"
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
          '--host', host, '--port', frontend_port.to_s, '--strictPort', chdir: directory
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
