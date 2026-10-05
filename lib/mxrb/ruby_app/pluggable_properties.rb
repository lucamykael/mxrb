# frozen_string_literal: true

require_relative '../pluggable/mpr_codec'
require_relative 'pluggable_context'

module Mxrb
  module RubyApp
    # Isolated bridge to the existing runtime projection, not a replacement
    # for the lossless Forms codec. A catalog is always application-scoped.
    class PluggableProperties # rubocop:disable Metrics/ClassLength
      class UnsupportedProjection < StandardError; end

      CatalogLoad = Data.define(:catalog, :unsupported_widget_ids)
      ActionValue = Data.define(:kind, :handler, :arguments)
      DataSourceValue = Data.define(:entity, :xpath, :sort)
      ObjectValue = Data.define(:assignments)
      ObjectListValue = Data.define(:objects)

      # Builds one schema-validated object inside an Object property.
      class ObjectValueBuilder
        def initialize(owner)
          @owner = owner
          @assignments = []
        end

        def evaluate(&block)
          block.arity == 1 ? block.call(self) : instance_eval(&block)
          ObjectValue.new(@assignments.dup.freeze)
        end

        def set(identifier, value)
          key = identifier.to_s
          raise ArgumentError, "duplicate object property #{key.inspect}" if @assignments.any? { _1.first == key }

          @assignments << [key.freeze, value].freeze
          self
        end

        def action(**options) = @owner.action(**options)
        def data_source(**options) = @owner.data_source(**options)
        def objects(&block) = @owner.objects(&block)
      end

      # Builds the ordered objects assigned to an Object property.
      class ObjectListBuilder
        def initialize(owner)
          @owner = owner
          @objects = []
        end

        def object(&block)
          raise ArgumentError, 'object requires a block' unless block

          @objects << ObjectValueBuilder.new(@owner).evaluate(&block)
          self
        end

        def build = ObjectListValue.new(@objects.dup.freeze)
      end
      SUPPORTED_KINDS = %w[String Boolean Integer Decimal Enumeration Selection Expression Attribute TextTemplate
                           Image].freeze
      private_constant :SUPPORTED_KINDS

      attr_reader :schema

      def self.with(manifest, &block) = PluggableContext.with(manifest:, &block)
      def self.with_mpr(mpr, &block) = PluggableContext.with(mpr:, &block)

      def self.with_page(identifier, &block)
        context = PluggableContext.current
        context ? context.with_page(identifier, &block) : block.call
      end

      def self.for_widget(name, widget_id:)
        context = PluggableContext.current
        raise ValidationError, 'typed pluggable properties require an application baseline' unless context

        context.for_widget(name, widget_id:)
      end

      def self.try_for_widget(name, widget_id:, properties:)
        return unless properties.is_a?(Hash)

        bridge = for_widget(name, widget_id:)
        bridge.populate_projection(properties)
        bridge if bridge.to_projection.to_a.eql?(properties.to_a)
      rescue ValidationError, UnsupportedProjection, KeyError, TypeError, ArgumentError
        nil
      end

      # Returns the losslessly editable subset of a projection. Unsupported
      # complex values stay in the private native baseline and are therefore
      # preserved during an incremental rebuild instead of leaking storage
      # hashes into the public Ruby source.
      def self.try_supported_subset_for_widget(name, widget_id:, properties:)
        return unless properties.is_a?(Hash)

        bridge = for_widget(name, widget_id:)
        bridge.populate_supported_subset(properties)
        bridge
      rescue ValidationError, KeyError
        nil
      end

      # Reads embedded widget types without evaluating schema Ruby or using
      # the process-global default catalog. The caller owns the MPR handle.
      def self.catalog_from_mpr(mpr)
        catalog = Pluggable::Catalog.new
        unsupported = register_mpr_types(mpr, catalog)
        available = Pluggable::Catalog.new
        catalog.schema_definitions.each { available.register(_1) unless unsupported.include?(_1.id) }
        CatalogLoad.new(catalog: available, unsupported_widget_ids: unsupported.uniq.map { _1.dup.freeze }.freeze)
      end

      def self.register_mpr_types(mpr, catalog)
        codec = Pluggable::MprCodec.new(forms_codec: nil, catalog:)
        unsupported = []
        mpr.all_units.each do |unit|
          visit_widget_types(mpr.parse_contents(unit)) do |document|
            codec.register_type(Marshal.load(Marshal.dump(document)))
          rescue Pluggable::UnsupportedStoragePropertyError
            unsupported << document.fetch('WidgetId', '').to_s
          end
        end
        unsupported
      end
      private_class_method :register_mpr_types

      def self.visit_widget_types(value, &block)
        case value
        when Hash
          yield value.fetch('Type') if value['$Type'] == 'CustomWidgets$CustomWidget'
          value.each_value { visit_widget_types(_1, &block) }
        when Array then value.each { visit_widget_types(_1, &block) }
        end
      end
      private_class_method :visit_widget_types

      # nil means retain the existing representation. Unknown keys are errors,
      # not a request to silently discard a misspelled property.
      def self.try_from_projection(widget_id, properties, catalog:)
        return unless properties.is_a?(Hash) && catalog.type(widget_id)

        bridge = new(widget_id, catalog:)
        bridge.populate_projection(properties)
        bridge if bridge.to_projection.to_a.eql?(properties.to_a)
      rescue UnsupportedProjection, TypeError, ArgumentError
        nil
      end

      def populate_projection(properties)
        validate_projection_keys!(properties)
        evaluate { properties.each { |key, value| set(key, value) } }
      end

      def populate_supported_subset(properties)
        validate_projection_keys!(properties)
        properties.each { |key, value| set_supported(key, supported_value(key, value)) }
        self
      end

      def initialize(widget_id, catalog:)
        @schema = catalog.fetch(widget_id).object_type
        @object = Pluggable::ObjectNode.new(schema)
        @semantic_values = {}
        @projection_order = []
      end

      def self.build(widget_id, catalog:, &block)
        new(widget_id, catalog:).tap { _1.evaluate(&block) if block }
      end

      def evaluate(&block)
        previous = @object
        previous_semantic = @semantic_values.dup
        previous_order = @projection_order.dup
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @object = previous
        @semantic_values = previous_semantic
        @projection_order = previous_order
        raise
      end

      def action(kind:, handler:, arguments: [])
        kind = kind.to_s
        handler = handler.to_s
        raise ArgumentError, 'action kind and handler must not be empty' if kind.empty? || handler.empty?

        pairs = canonical_pairs(arguments, label: 'action arguments')
        ActionValue.new(kind.freeze, handler.freeze, pairs.freeze)
      end

      def data_source(entity:, xpath: '', sort: [])
        entity = entity.to_s
        raise ArgumentError, 'data source entity must not be empty' if entity.empty?

        order = canonical_sort(sort)
        DataSourceValue.new(entity.freeze, xpath.to_s.freeze, order.freeze)
      end

      def objects(&block)
        raise ArgumentError, 'objects requires a block' unless block

        builder = ObjectListBuilder.new(self)
        block.arity == 1 ? block.call(builder) : builder.instance_eval(&block)
        builder.build
      end

      def set(identifier, value)
        property = schema.fetch_property(identifier)
        ensure_supported!(property, value)
        validate_semantic_input!(property, value)
        return apply_nil(property) if value.nil?

        apply_value(property, value)
      end

      def apply_nil(property)
        remember(property)
        @semantic_values.delete(property.key)
        @object = copy_object(except: property.key)
        self
      end

      def apply_value(property, value)
        return apply_semantic_value(property, value) if semantic_value?(value)

        candidate = copy_object
        candidate.set(property.key, bridge_value(property, value))
        validate_choice!(property, candidate.fetch(property.key))
        project_value(property, candidate.fetch(property.key))
        remember(property)
        @semantic_values.delete(property.key)
        @object = candidate
        self
      end

      def typed_value(identifier)
        property = schema.fetch_property(identifier)
        return @semantic_values[property.key] if @semantic_values.key?(property.key)

        value = @object.fetch(identifier)
        value.is_a?(Forms::Node) ? text_template(value) : value
      end

      def to_projection
        assignments = @object.assignments.to_h { [_1.property.key, _1] }
        @projection_order.to_h do |key|
          next [key, project_semantic_value(@semantic_values.fetch(key))] if @semantic_values.key?(key)

          assignment = assignments[key]
          [key, assignment ? project_value(assignment.property, assignment.value) : nil]
        end.freeze
      end

      def source_expression(identifier, indentation: 0)
        property = schema.fetch_property(identifier)
        value = @semantic_values[property.key]
        case value
        when ActionValue then action_source(value)
        when DataSourceValue then data_source_source(value)
        when ObjectListValue then object_list_source(value, indentation)
        end
      end

      private

      def validate_projection_keys!(properties)
        return if properties.keys.all? do |key|
          key.is_a?(String) && schema.properties.any? { _1.key == key }
        end

        raise KeyError, 'unknown or noncanonical pluggable projection property'
      end

      def set_supported(key, value)
        set(key, value)
      rescue UnsupportedProjection, TypeError, ArgumentError
        # The unrepresented value remains authoritative in the baseline.
        nil
      end

      def supported_value(key, value)
        property = schema.fetch_property(key)
        supported_value_for_property(property, value)
      rescue KeyError, ArgumentError, TypeError
        value
      end

      def supported_value_for_property(property, value)
        return value unless value.is_a?(Hash)

        normalized = value.to_h { |name, item| [name.to_sym, item] }
        case property.value_type.kind
        when 'Action' then supported_action_value(normalized)
        when 'DataSource' then supported_data_source_value(normalized)
        when 'Object' then supported_object_list_value(property, normalized)
        else value
        end
      end

      def supported_action_value(value)
        action(kind: value.fetch(:kind), handler: value.fetch(:handler),
               arguments: value.fetch(:arguments, []))
      end

      def supported_data_source_value(value)
        data_source(entity: value.fetch(:data_source), xpath: value.fetch(:xpath, ''),
                    sort: value.fetch(:sort, []))
      end

      def supported_object_list_value(property, value)
        schema = property.value_type.object_type
        items = Array(value.fetch(:objects)).map { supported_object_value(schema, _1) }
        ObjectListValue.new(items.freeze)
      end

      def supported_object_value(schema, item)
        raise TypeError, 'pluggable object projection requires a Hash' unless item.is_a?(Hash)

        assignments = item.filter_map do |key, entry|
          nested = schema.fetch_property(key)
          candidate = supported_value_for_property(nested, entry)
          next unless value_supported_for_property?(nested, candidate)

          [nested.key.freeze, candidate].freeze
        end
        ObjectValue.new(assignments.freeze)
      end

      def remember(property)
        @projection_order << property.key unless @projection_order.include?(property.key)
      end

      def copy_object(except: nil)
        Pluggable::ObjectNode.new(schema).tap do |candidate|
          @object.assignments.each do |assignment|
            candidate.set(assignment.property.key, assignment.value) unless assignment.property.key == except
          end
        end
      end

      def ensure_supported!(property, value)
        type = property.value_type
        return if value.nil? && (!type.list? || type.widgets? || type.object?)
        return if scalar_supported?(type) || semantic_supported?(type, value)

        raise UnsupportedProjection, 'pluggable property requires the legacy projection or full Forms codec'
      end

      def scalar_supported?(type)
        SUPPORTED_KINDS.include?(type.kind) && !type.list?
      end

      def semantic_supported?(type, value)
        (type.kind == 'Action' && value.is_a?(ActionValue)) ||
          (type.kind == 'DataSource' && value.is_a?(DataSourceValue)) ||
          (type.object? && value.is_a?(ObjectListValue) && valid_object_list?(type, value))
      end

      def semantic_value?(value)
        value.is_a?(ActionValue) || value.is_a?(DataSourceValue) || value.is_a?(ObjectListValue)
      end

      def apply_semantic_value(property, value)
        @object = copy_object(except: property.key)
        @semantic_values[property.key] = value
        remember(property)
        self
      end

      def project_semantic_value(value)
        case value
        when ActionValue
          { action: { kind: value.kind, handler: value.handler, arguments: value.arguments.to_h } }
        when DataSourceValue
          sort = value.sort.map { |attribute, direction| { attribute:, direction: } }
          { data_source: { entity: value.entity, xpath: value.xpath, sort: } }
        when ObjectListValue
          { objects: value.objects.map { project_object_value(_1) } }
        end
      end

      def project_object_value(value)
        value.assignments.to_h do |key, item|
          projected = semantic_value?(item) ? project_semantic_value(item) : item
          [key, projected]
        end
      end

      def valid_object_list?(type, value)
        value.objects.all? do |object|
          object.assignments.all? do |key, item|
            property = type.object_type.fetch_property(key)
            value_supported_for_property?(property, item)
          end
        end
      rescue KeyError, TypeError
        false
      end

      def value_supported_for_property?(property, value)
        semantic_value?(value) ? semantic_supported?(property.value_type, value) : valid_scalar?(property, value)
      end

      def valid_scalar?(property, value)
        schema = Pluggable::ObjectType.new([property].freeze)
        Pluggable::ObjectNode.new(schema).tap do |node|
          node.set(property.key, value.nil? ? nil : bridge_value(property, value))
        end
        true
      rescue TypeError, ArgumentError
        false
      end

      def canonical_pairs(value, label:)
        pairs = value.is_a?(Hash) ? value.to_a : Array(value)
        pairs.map do |pair|
          unless pair.is_a?(Array) && pair.length == 2
            raise ArgumentError, "#{label} must be a Hash or an Array of pairs"
          end

          [pair[0].to_s.freeze, pair[1].to_s.freeze].freeze
        end
      end

      def canonical_sort(value)
        Array(value).map { canonical_sort_item(_1) }
      end

      def canonical_sort_item(item)
        if item.is_a?(Hash)
          item = item.to_h { |key, entry| [key.to_sym, entry] }
          item = [item.fetch(:attribute), item.fetch(:direction)]
        end
        raise ArgumentError, 'data source sort must be an Array of pairs' unless item.is_a?(Array) && item.length == 2

        [item[0].to_s.freeze, item[1].to_s.freeze].freeze
      end

      def action_source(value)
        arguments = value.arguments.empty? ? '' : ", arguments: #{value.arguments.inspect}"
        "action(kind: #{value.kind.inspect}, handler: #{value.handler.inspect}#{arguments})"
      end

      def data_source_source(value)
        sort = value.sort.empty? ? '' : ", sort: #{value.sort.inspect}"
        "data_source(entity: #{value.entity.inspect}, xpath: #{value.xpath.inspect}#{sort})"
      end

      def object_list_source(value, indentation)
        pad = ' ' * indentation
        body = value.objects.map { object_value_source(_1, indentation + 2) }
        "objects do\n#{body.join("\n")}\n#{pad}end"
      end

      def object_value_source(object, indentation)
        pad = ' ' * indentation
        assignments = object.assignments.map do |key, item|
          expression = semantic_source(item, indentation + 2) || item.inspect
          "#{' ' * (indentation + 2)}set #{key.inspect}, #{expression}"
        end
        "#{pad}object do\n#{assignments.join("\n")}\n#{pad}end"
      end

      def semantic_source(value, indentation)
        case value
        when ActionValue then action_source(value)
        when DataSourceValue then data_source_source(value)
        when ObjectListValue then object_list_source(value, indentation)
        end
      end

      def bridge_value(property, value)
        return nil if value.nil?

        case property.value_type.kind
        when 'TextTemplate' then text_template(value)
        when 'Image' then image_reference(value)
        else value.is_a?(String) ? value.dup : value
        end
      end

      def image_reference(value)
        if value.is_a?(Pluggable::Reference)
          raise TypeError, 'image requires an Image reference' unless value.kind == 'Image'

          value = value.target
        end
        raise TypeError, 'image requires a String or Image reference' unless value.is_a?(String)

        Pluggable.reference(:image, value.dup)
      end

      def text_template(value)
        text = value.is_a?(Forms::Node) ? template_text(value) : scalar_template_text(value)
        Forms::Node.build('ClientTemplate') { set :template, text }
      end

      def scalar_template_text(value)
        template = Forms::TextTemplate.coerce(value)
        unless template.parameters.empty?
          raise UnsupportedProjection, 'template parameters require the full Forms codec'
        end

        template.text
      end

      def template_text(value)
        unless value.schema_type.name == 'ClientTemplate' &&
               value.assignments.all? { _1.property.ruby_name == 'template' }
          raise UnsupportedProjection, 'template structure is not represented by a scalar caption'
        end

        value.fetch(:template)
      end

      def validate_choice!(property, value)
        return if value.nil? || property.value_type.kind != 'Enumeration'

        choices = property.value_type.enumeration_values.map(&:key)
        return if choices.empty? || choices.include?(value)

        raise TypeError, 'unknown pluggable enumeration value'
      end

      def validate_semantic_input!(property, value)
        return if value.nil?

        expected = case property.value_type.kind
                   when 'Expression' then Forms::Expression
                   when 'Attribute' then Forms::AttributeReference
                   end
        return unless expected
        return if value.is_a?(String) || value.is_a?(expected)

        raise TypeError, 'pluggable semantic value requires a String or its typed value'
      end

      def project_value(property, value)
        return nil if value.nil?

        case property.value_type.kind
        when 'Expression' then value.source
        when 'Attribute' then project_attribute(value)
        when 'Decimal' then project_decimal(value)
        when 'Image' then value.target
        when 'TextTemplate' then project_text(value)
        else value
        end
      end

      def project_attribute(value)
        unless value.entity_reference.nil?
          raise UnsupportedProjection, 'attribute context is not represented by this scalar projection'
        end

        value.attribute
      end

      def project_text(value)
        text = template_text(value)
        unless text.is_a?(Forms::Text) && text.translations.size <= 1 && text.translations.all? { _1.language.nil? }
          raise UnsupportedProjection, 'translation metadata is not represented by a scalar caption'
        end

        text.to_s
      end

      def project_decimal(value)
        result = Float(value.value)
        unless result.finite? && Pluggable::Decimal.coerce(result).value == value.value
          raise UnsupportedProjection, 'decimal precision is not representable by the runtime projection'
        end

        result
      end
    end
  end
end
