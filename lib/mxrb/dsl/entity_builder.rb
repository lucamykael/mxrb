# frozen_string_literal: true

module Mxrb
  module Dsl
    class EntityBuilder # rubocop:disable Metrics/ClassLength
      ATTR_TYPES = %i[string integer long float decimal boolean datetime autonumber hashstring binary enum].freeze
      ASSOCIATION_TYPES = %i[Reference ReferenceSet].freeze
      ASSOCIATION_OWNERS = %i[Default Both].freeze
      ASSOCIATION_STORAGE_FORMATS = %i[Column Table].freeze
      CARDINALITIES = {
        many_to_one: %i[Reference Default],
        one_to_one: %i[Reference Both],
        many_to_many: %i[ReferenceSet Default]
      }.freeze

      attr_reader :name

      def initialize(name)
        @name         = name.to_s
        @attributes   = []
        @persistable  = true
        @doc          = ''
        @associations = []
        @lifecycle    = nil
        @access_rules = nil
        @generalization = nil
        @system_members = nil
        @indexes = nil
        @oql_view = nil
      end

      ATTR_TYPES.each do |type|
        define_method(type) do |attr_name, **opts|
          opts[:default] = '1' if type == :autonumber && !opts.key?(:default)
          @attributes << { name: attr_name.to_s, type: type, **opts }
        end
      end

      def non_persistent!  = (@persistable = false)
      def documentation(d) = (@doc = d)

      # Marks an entity as an OQL-backed view. Modern Mendix projects keep the
      # query in a separate ViewEntitySourceDocument; older projects may keep
      # it directly on the embedded entity.
      def oql_view(source: nil, query: nil)
        raise ArgumentError, 'oql_view requires source or query' if source.nil? && query.nil?

        @oql_view = { source: source&.to_s, query: query&.to_s }.compact
      end

      def generalizes(entity, id: nil)
        @generalization = { target: entity.to_s, id: id&.to_s }
      end

      def system_members(owner: false, created_date: false, changed_date: false, changed_by: false)
        @system_members = {
          owner: owner, created_date: created_date,
          changed_date: changed_date, changed_by: changed_by
        }
      end

      def index(*attributes, id: nil, guid: nil, include_offline: false, ascending: true,
                members: nil)
        names = attributes.flatten.map(&:to_s)
        raise ArgumentError, 'index requires at least one attribute' if names.empty? && !members

        @indexes ||= []
        declarations = normalize_index_declarations(names, ascending, members)
        @indexes << {
          id: id&.to_s, guid: guid&.to_s, members: declarations,
          attributes: declarations.map { _1.fetch(:name).to_s },
          ascending: declarations.map { _1.fetch(:ascending, true) == true },
          include_offline: include_offline == true
        }
      end

      def association(target, type: :Reference, owner: nil, name: nil, cardinality: nil,
                      documentation: '', parent_delete: :NoAction, child_delete: :NoAction,
                      storage_format: nil)
        if cardinality
          type, inferred_owner = CARDINALITIES.fetch(cardinality.to_sym) do
            raise ArgumentError, 'cardinality must be :many_to_one, :one_to_one, or :many_to_many'
          end
          owner ||= inferred_owner
        end
        owner ||= :Default
        type = type.to_sym
        owner = owner.to_sym
        unless ASSOCIATION_TYPES.include?(type)
          raise ArgumentError, 'association type must be Reference or ReferenceSet'
        end
        raise ArgumentError, 'association owner must be Default or Both' unless ASSOCIATION_OWNERS.include?(owner)

        storage_format = normalize_association_storage_format(storage_format)

        @associations << {
          name: (name || "#{@name}_#{target}").to_s,
          target: target.to_s,
          type: type,
          owner: owner,
          documentation: documentation.to_s,
          parent_delete: parent_delete.to_sym,
          child_delete: child_delete.to_sym,
          storage_format: storage_format
        }
      end

      %i[before_commit after_commit before_delete after_delete].each do |event|
        define_method(event) do |microflow:, id: nil, pass_event_object: true,
                                raise_error_on_false: nil|
          @lifecycle ||= []
          raise_error = if raise_error_on_false.nil?
                          event.to_s.start_with?('before_')
                        else
                          raise_error_on_false == true
                        end
          @lifecycle << {
            id: id&.to_s, event:, handler: microflow.to_s,
            pass_event_object: pass_event_object == true,
            raise_error_on_false: raise_error
          }
        end
      end

      # access_rule "Module.Role", create: true, delete: false, read: :all, write: [:Name]
      def access_rule(*roles, id: nil, documentation: '', create: false, delete: false,
                      read: :none, write: :none, xpath: '', xpath_caption: nil,
                      default_rights: nil, members: nil)
        @access_rules ||= []
        @access_rules << {
          id: id&.to_s,
          documentation: documentation.to_s,
          roles: roles.map(&:to_s),
          create: create,
          delete: delete,
          read: normalize_access(read),
          write: normalize_access(write),
          xpath: xpath.to_s,
          xpath_caption: xpath_caption&.to_s,
          default_rights: default_rights&.to_s,
          members: members&.map { _1.transform_keys(&:to_sym) }
        }
      end

      def to_h
        {
          name: @name, persistable: @persistable, documentation: @doc,
          attributes: @attributes, associations: @associations, lifecycle: @lifecycle,
          access_rules: @access_rules, generalization: @generalization,
          system_members: @system_members, indexes: @indexes, oql_view: @oql_view
        }
      end

      private

      def normalize_index_declarations(names, ascending, members)
        return members.map { _1.transform_keys(&:to_sym) } if members

        directions = Array(ascending)
        if directions.size != 1 && directions.size != names.size
          raise ArgumentError, 'ascending must be one boolean or one value per indexed attribute'
        end

        directions *= names.size if directions.size == 1
        names.zip(directions).map do |name, direction|
          { name:, ascending: direction == true, type: :Normal }
        end
      end

      def normalize_association_storage_format(value)
        return if value.nil?

        format = value.to_sym
        return format if ASSOCIATION_STORAGE_FORMATS.include?(format)

        raise ArgumentError, 'association storage format must be Column or Table'
      end

      def normalize_access(value)
        case value
        when :all, :none then value
        when Array       then value.map(&:to_s)
        else value.to_sym
        end
      end
    end
  end
end
