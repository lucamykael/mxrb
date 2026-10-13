# frozen_string_literal: true

module Mxrb
  module Dsl
    class DataViewBuilder # rubocop:disable Metrics/ClassLength
      include WidgetDsl
      include OverlayFields

      EDITABILITY = %i[always never conditional].freeze
      READ_ONLY_STYLES = %i[control text inherit].freeze

      def initialize(name, from:, editable:, read_only_style:, label_width:, show_footer:,
                     no_entity_message:, tab_index:, class_name:, style:, dynamic_class:)
        @declared_fields = declared_fields(
          source: from, editable:, read_only_style:, label_width:, show_footer:,
          no_entity_message:, tab_index:, class: class_name, style:, dynamic_class:
        )
        editable = default_value(editable, :always)
        read_only_style = default_value(read_only_style, :control)
        label_width = default_value(label_width, 0)
        show_footer = default_value(show_footer, true)
        no_entity_message = default_value(no_entity_message, '')
        tab_index = default_value(tab_index, 0)
        class_name = default_value(class_name, nil)
        style = default_value(style, nil)
        dynamic_class = default_value(dynamic_class, nil)
        @name = name.to_s
        @source = normalize_source(from)
        @options = {
          editable: normalize_enum(editable, EDITABILITY, 'editability'),
          read_only_style: normalize_enum(read_only_style, READ_ONLY_STYLES, 'read-only style'),
          label_width: Integer(label_width), show_footer: show_footer == true,
          no_entity_message: no_entity_message.to_s, tab_index: Integer(tab_index),
          class: class_name&.to_s, style: style&.to_s, dynamic_class: dynamic_class&.to_s
        }.compact
        raise ArgumentError, 'data view label_width cannot be negative' if @options[:label_width].negative?

        @body = []
        @footer = []
        @target = @body
        @visibility = nil
        @editability = nil
        @design_properties = []
        @unknown_native = {}
      end

      def body(&block) = evaluate_region(@body, &block)
      def footer(&block) = evaluate_region(@footer, &block)

      def visible_when(expression = nil, roles: [], attribute: nil, conditions: [],
                       ignore_security: false, source: nil, native: nil)
        @declared_fields << :visibility unless @declared_fields.include?(:visibility)
        @visibility = condition(
          expression:, roles:, attribute:, conditions:, ignore_security:, source:, native:
        )
      end

      def editable_when(expression = nil, roles: [], attribute: nil, conditions: [],
                        ignore_security: false, source: nil, native: nil)
        @declared_fields << :editability_condition unless
          @declared_fields.include?(:editability_condition)
        @editability = condition(
          expression:, roles:, attribute:, conditions:, ignore_security:, source:, native:
        )
      end

      def design_properties(*values) = (@design_properties = values.flatten)

      def design_property(key, option: UNSET, toggle: UNSET, id: nil, value_id: nil, &block)
        builder = DesignPropertyBuilder.new
        @design_properties << builder.build(
          key, option:, toggle:, id:, value_id:, &block
        )
      end

      def unknown_native(value)
        raise ArgumentError, 'unknown_native requires a Hash' unless value.is_a?(Hash)

        @unknown_native = value
      end

      def to_h
        options = @options.merge(source: @source)
        options[:visibility] = @visibility if @visibility
        options[:editability] = @editability if @editability
        options[:design_properties] = @design_properties unless @design_properties.empty?
        options[:unknown_native] = @unknown_native unless @unknown_native.empty?
        {
          type: :data_view, name: @name, options:, body: @body, footer: @footer, events: [],
          declared_fields: @declared_fields
        }
      end

      private

      def _widget_list = @target

      def evaluate_region(target, &block)
        previous = @target
        @target = target
        instance_eval(&block) if block
        self
      ensure
        @target = previous
      end

      def normalize_source(source)
        raise ArgumentError, 'data view from: must be a semantic source' unless source.is_a?(Hash)
        raise ArgumentError, 'data view source requires kind' unless source[:kind] || source['kind']

        source.transform_keys(&:to_sym)
      end

      def normalize_enum(value, allowed, label)
        normalized = value.to_s.downcase.to_sym
        normalized = :conditional if allowed.equal?(EDITABILITY) && normalized == :conditionally
        return normalized if allowed.include?(normalized)

        raise ArgumentError, "unsupported data view #{label} #{value.inspect}"
      end

      def condition(expression:, roles:, attribute:, conditions:, ignore_security:, source:, native:)
        compact_data_view_source(
          expression: expression&.to_s, roles: Array(roles).map(&:to_s),
          attribute: attribute&.to_s, conditions: Dsl.attribute_conditions(conditions),
          ignore_security: ignore_security == true, source_variable: source,
          unknown_native: native
        )
      end
    end

    class DesignPropertyBuilder
      attr_reader :properties

      def initialize = (@properties = [])

      def design_property(key, option: UNSET, toggle: UNSET, id: nil, value_id: nil, &block)
        @properties << build(key, option:, toggle:, id:, value_id:, &block)
      end

      def build(key, option: UNSET, toggle: UNSET, id: nil, value_id: nil, &block)
        choices = [!option.equal?(UNSET), !toggle.equal?(UNSET), !block.nil?].count(true)
        raise ArgumentError, 'design property accepts either option:, toggle: true or a nested block' if choices > 1
        raise ArgumentError, 'design property requires option:, toggle: true or a nested block' if choices.zero?
        raise ArgumentError, 'design property toggle must be true; remove the declaration to disable it' if
          !toggle.equal?(UNSET) && toggle != true

        value = { key: key.to_s, id: id&.to_s, value_id: value_id&.to_s }
        if block
          nested = self.class.new
          nested.instance_eval(&block)
          value[:properties] = nested.properties
        elsif toggle == true
          value[:toggle] = true
        else
          value[:option] = option.to_s
        end
        value
      end
    end
  end
end
