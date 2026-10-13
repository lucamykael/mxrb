# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Base for generated persistent models.
    class Record
      extend RecordInheritance
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

        # Server-owned upload policy; browser widget settings are only UX hints.
        def file_policy(max_bytes: FileContent::MAX_BYTES, extensions: [], images_only: false)
          size = Integer(max_bytes)
          raise ArgumentError, 'file policy size must be between 1 byte and 20 MiB' unless
            size.positive? && size <= FileContent::MAX_BYTES

          @file_policy = { max_bytes: size, extensions: Array(extensions).map { _1.to_s.downcase.delete_prefix('.') },
                           images_only: images_only == true }
        end

        def file_upload_policy = @file_policy || {}

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
          values = runtime_attributes.to_h do |attribute|
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
            type: normalize_index_type(declaration.fetch(:type, :Normal))
          }
        end

        def normalize_index_type(value)
          aliases = {
            normal: :Normal, created_date: :CreatedDate, changed_date: :ChangedDate
          }
          symbol = value.to_sym
          aliases.fetch(symbol, symbol)
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
        self.class.runtime_attributes.each do |attribute|
          name = attribute.fetch(:name)
          singleton_class.attr_accessor(name) unless respond_to?("#{name}=")
        end
        values.each { public_send("#{_1}=", _2) if respond_to?("#{_1}=") }
      end

      def to_h
        values = self.class.runtime_attributes.to_h { [_1.fetch(:name), public_send(_1.fetch(:name))] }
        { id:, type: self.class.mendix_name, attributes: values }
      end

      def sync_to_native!
        return self unless @native_value

        self.class.runtime_attributes.each do |attribute|
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
    # rubocop:enable Metrics
  end
end
