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
        properties.each_key do |key|
          unless key.is_a?(String) && schema.properties.any? { _1.key == key }
            raise KeyError, 'unknown or noncanonical pluggable projection property'
          end
        end
        evaluate { properties.each { |key, value| set(key, value) } }
      end

      def initialize(widget_id, catalog:)
        @schema = catalog.fetch(widget_id).object_type
        @object = Pluggable::ObjectNode.new(schema)
        @projection_order = []
      end

      def self.build(widget_id, catalog:, &block)
        new(widget_id, catalog:).tap { _1.evaluate(&block) if block }
      end

      def evaluate(&block)
        previous = @object
        previous_order = @projection_order.dup
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @object = previous
        @projection_order = previous_order
        raise
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
        @object = copy_object(except: property.key)
        self
      end

      def apply_value(property, value)
        candidate = copy_object
        candidate.set(property.key, bridge_value(property, value))
        validate_choice!(property, candidate.fetch(property.key))
        project_value(property, candidate.fetch(property.key))
        remember(property)
        @object = candidate
        self
      end

      def typed_value(identifier)
        value = @object.fetch(identifier)
        value.is_a?(Forms::Node) ? text_template(value) : value
      end

      def to_projection
        assignments = @object.assignments.to_h { [_1.property.key, _1] }
        @projection_order.to_h do |key|
          assignment = assignments[key]
          [key, assignment ? project_value(assignment.property, assignment.value) : nil]
        end.freeze
      end

      private

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
        return if value.nil? && (!type.list? || type.widgets?)
        return if SUPPORTED_KINDS.include?(type.kind) && !type.list?

        raise UnsupportedProjection, 'pluggable property requires the legacy projection or full Forms codec'
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
