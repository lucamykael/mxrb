# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Existing native fields that have an unambiguous public Ruby scalar projection.
    # Never synthesizes fields absent from the source version or replaces a widget.
    module PageEditProperties
      INPUT_FIELDS = {
        'editable' => ['Editable', %w[Always Never Conditional]],
        'read_only_style' => ['ReadOnlyStyle', %w[Text Control Inherit]],
        'aria_required' => ['AriaRequired', :boolean], 'tab_index' => ['TabIndex', :integer]
      }.freeze
      TEXT_INPUT_FIELDS = INPUT_FIELDS.merge(
        'password' => ['IsPasswordBox', :boolean], 'max_length' => ['MaxLengthCode', :integer]
      ).freeze
      CONTRACTS = {
        'button' => [%w[Forms$ActionButton Forms$GridActionButton Pages$ActionButton], {
          'button_style' => ['ButtonStyle', %w[Default Primary Info Success Warning Danger Inverse]],
          'render_type' => ['RenderType', %w[Button Link]], 'tab_index' => ['TabIndex', :integer]
        }],
        'text' => [%w[Forms$DynamicText Forms$Label Pages$DynamicText Pages$Label], {
          'render_mode' => ['RenderMode', %w[Text H1 H2 H3 H4 H5 H6 Paragraph]]
        }],
        'data_view' => [%w[Forms$DataView], {
          'editable' => ['Editability', %w[Always Never Conditional]],
          'read_only_style' => ['ReadOnlyStyle', %w[Text Control]],
          'label_width' => ['LabelWidth', :integer], 'show_footer' => ['ShowFooter', :boolean],
          'tab_index' => ['TabIndex', :integer]
        }],
        'text_box' => [%w[Forms$TextBox Pages$TextBox], TEXT_INPUT_FIELDS],
        'number_input' => [%w[Forms$TextBox], TEXT_INPUT_FIELDS],
        'text_area' => [%w[Forms$TextArea Pages$TextArea], INPUT_FIELDS.merge(
          'max_length' => ['MaxLengthCode', :integer], 'lines' => ['NumberOfLines', :integer]
        )],
        'check_box' => [%w[Forms$CheckBox Pages$CheckBox], INPUT_FIELDS],
        'date_picker' => [%w[Forms$DatePicker Pages$DatePicker], INPUT_FIELDS]
      }.freeze

      module_function

      def supported?(type, key)
        CONTRACTS.fetch(type, [[], {}]).last.key?(key)
      end

      def apply(owner, type, key, before, after)
        field, values = field_spec(owner, type, key)
        previous = encode(before, values)
        current = encode(after, values)
        raise ArgumentError, "#{field} no longer matches the exported Ruby baseline" unless owner[field] == previous

        owner[field] = current
      end

      def field_spec(owner, type, key)
        native_types, fields = CONTRACTS.fetch(type)
        field, values = stored_field(owner, *fields.fetch(key))
        unless native_types.include?(owner['$Type']) && owner.key?(field)
          raise ArgumentError, "#{key} has no supported native field on #{owner['$Type']}"
        end

        [field, values]
      end

      def stored_field(owner, field, values)
        return [field, values] unless field == 'Editability' && !owner.key?(field) && owner.key?('Editable')

        ['Editable', { 'always' => true, 'never' => false }]
      end

      def encode(value, values)
        return value if scalar?(value, values)
        return values.fetch(value) if values.is_a?(Hash) && values.key?(value)

        native = enum_value(value, values)
        return native if native

        raise ArgumentError, "invalid value #{value.inspect}; expected #{values.inspect}"
      end

      def scalar?(value, values)
        (values == :integer && value.is_a?(Integer)) || (values == :boolean && [true, false].include?(value))
      end

      def enum_value(value, values)
        return unless values.is_a?(Array) && value.is_a?(String)

        native = value.split('_').map(&:capitalize).join
        native if values.include?(native)
      end
    end
  end
end
