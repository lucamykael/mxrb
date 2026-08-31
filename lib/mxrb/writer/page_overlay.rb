# frozen_string_literal: true

require 'digest'
require 'json'

module Mxrb
  class Writer
    # Locates the only root widget slot whose parent identity is known.
    module PageRootSlots
      private

      def sole_root_slot(document)
        slots = root_slots(document)
        return slots.first if slots.one?

        raise ValidationError,
              "page overlay requires exactly one root widget slot (found #{slots.size})"
      end

      def root_slots(document) # rubocop:disable Metrics/AbcSize
        slots = []
        slots << collection_items(document['Widgets']) if document.key?('Widgets')
        form_call = document['FormCall']
        return slots unless form_call.is_a?(Hash)

        collection_items(form_call['Arguments']).each do |argument|
          next unless argument.is_a?(Hash)

          slots << collection_items(argument['Widgets']) if argument.key?('Widgets')
          slots << [argument['Widget']].compact if argument.key?('Widget')
        end
        slots
      end

      def collection_items(value)
        return [] unless value.is_a?(Array)

        value.first.is_a?(Integer) ? value.drop(1) : value
      end
    end

    # Applies explicitly declared Ruby page fields to an imported native page
    # without replacing its native widget tree. Child collections remain
    # baseline-owned until their semantic nodes carry stable identities.
    class PageOverlay # rubocop:disable Metrics/ClassLength
      include PageRootSlots

      METADATA_KEY = '__mxrb_page_overlay_baseline'
      SUPPORTED_TYPES = %w[Forms$Table Forms$LayoutGrid Forms$DataView].freeze
      SCALAR_FIELDS = {
        'Forms$Table' => {
          tab_index: 'TabIndex', width_unit: 'WidthUnit'
        },
        'Forms$LayoutGrid' => {
          tab_index: 'TabIndex', width: 'Width'
        },
        'Forms$DataView' => {
          editable: 'Editability', label_width: 'LabelWidth',
          read_only_style: 'ReadOnlyStyle', show_footer: 'ShowFooter',
          tab_index: 'TabIndex'
        }
      }.freeze
      APPEARANCE_FIELDS = {
        class: 'Class', dynamic_class: 'DynamicClasses', style: 'Style'
      }.freeze

      STRUCTURAL_SCALAR_OPTIONS = {
        table: %i[tab_index width_unit class dynamic_class style],
        layout_grid: %i[tab_index width class dynamic_class style],
        data_view: %i[editable label_width read_only_style show_footer tab_index
                      class dynamic_class style]
      }.freeze

      def self.metadata(widgets, page_unit_id: nil, module_unit_id: nil)
        {
          'version' => 1,
          'page_unit_id' => page_unit_id,
          'module_unit_id' => module_unit_id,
          'widgets' => Array(widgets).map { widget_metadata(_1) }
        }
      end

      def self.widget_metadata(widget)
        {
          'type' => widget.fetch(:type).to_s,
          'name' => widget.fetch(:name).to_s,
          'fingerprint' => structural_fingerprint(widget)
        }
      end
      private_class_method :widget_metadata

      def self.structural_fingerprint(widget)
        projection = deep_stringify(widget)
        strip_projection_noise(projection)
        normalize_redundant_widget_children(projection)
        type = projection.fetch('type').to_sym
        normalize_table_columns(projection) if type == :table
        options = projection['options']
        Array(STRUCTURAL_SCALAR_OPTIONS[type]).each { options.delete(_1.to_s) } if options.is_a?(Hash)
        Digest::SHA256.hexdigest(JSON.generate(canonical(projection)))
      end

      def self.deep_stringify(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_s, deep_stringify(item)] }
        when Array then value.map { deep_stringify(_1) }
        when Symbol then value.to_s
        else value
        end
      end
      private_class_method :deep_stringify

      def self.strip_projection_noise(value)
        case value
        when Hash
          value.delete('declared_fields')
          value.delete('arguments') if value['arguments'] == {}
          value.each_value { strip_projection_noise(_1) }
        when Array
          value.each { strip_projection_noise(_1) }
        end
      end
      private_class_method :strip_projection_noise

      def self.normalize_redundant_widget_children(value)
        case value
        when Hash
          value.each_value { normalize_redundant_widget_children(_1) }
          value.delete('children') if redundant_widget_children?(value)
        when Array
          value.each { normalize_redundant_widget_children(_1) }
        end
      end
      private_class_method :normalize_redundant_widget_children

      def self.redundant_widget_children?(widget)
        return false unless widget['type'] == 'pluggable_widget'

        children = widget['children']
        slots = widget['slots']
        return true if children == []
        return false unless children.is_a?(Array)
        return false unless valid_widget_slots?(slots)

        redundant_slotted_projection?(children, slots)
      end
      private_class_method :redundant_widget_children?

      def self.redundant_slotted_projection?(children, slots)
        projection = canonical(children)
        projection == canonical(slotted_widget_roots(slots)) ||
          projection == canonical(slotted_widget_preorder(slots)) ||
          projection == canonical(nested_slotted_widgets(slots))
      end
      private_class_method :redundant_slotted_projection?

      def self.valid_widget_slots?(slots)
        slots.is_a?(Array) && slots.all? do |slot|
          slot.is_a?(Hash) && slot['widgets'].is_a?(Array)
        end
      end
      private_class_method :valid_widget_slots?

      def self.slotted_widget_roots(slots)
        slots.flat_map { _1.fetch('widgets') }
      end
      private_class_method :slotted_widget_roots

      def self.slotted_widget_preorder(slots)
        roots = slotted_widget_roots(slots)
        roots.each_with_object(roots.dup) do |widget, preorder|
          widget.each_value { collect_widget_preorder(_1, preorder) }
        end
      end
      private_class_method :slotted_widget_preorder

      def self.collect_widget_preorder(value, preorder)
        case value
        when Hash
          preorder << value if value.key?('type') && value.key?('name')
          value.each_value { collect_widget_preorder(_1, preorder) }
        when Array
          value.each { collect_widget_preorder(_1, preorder) }
        end
      end
      private_class_method :collect_widget_preorder

      def self.nested_slotted_widgets(slots)
        collect_nested_widget_arrays(slots, []).uniq { [_1['name'], _1['type']] }
      end
      private_class_method :nested_slotted_widgets

      def self.collect_nested_widget_arrays(value, found)
        case value
        when Hash
          found.concat(Array(value['widgets'])) if value['widgets']
          value.each_value { collect_nested_widget_arrays(_1, found) }
        when Array
          value.each { collect_nested_widget_arrays(_1, found) }
        end
        found
      end
      private_class_method :collect_nested_widget_arrays

      def self.normalize_table_columns(projection)
        rows = projection.dig('options', 'rows')
        return unless rows.is_a?(Array)

        occupied = {}
        rows.each_with_index do |row, row_index|
          normalize_table_row(row, row_index, occupied)
        end
      end
      private_class_method :normalize_table_columns

      def self.normalize_table_row(row, row_index, occupied)
        cursor = 0
        Array(row['cells']).each do |cell|
          column = cell['column'] || next_free_column(occupied, row_index, cursor)
          cell['column'] = column
          occupy_table_cell(occupied, row_index, column, cell)
          cursor = column + cell.fetch('colspan', 1).to_i
        end
      end
      private_class_method :normalize_table_row

      def self.occupy_table_cell(occupied, row, column, cell)
        rows = row...(row + cell.fetch('rowspan', 1).to_i)
        columns = column...(column + cell.fetch('colspan', 1).to_i)
        rows.each { |child_row| columns.each { occupied[[_1, child_row]] = true } }
      end
      private_class_method :occupy_table_cell

      def self.next_free_column(occupied, row, cursor)
        cursor += 1 while occupied[[cursor, row]]
        cursor
      end
      private_class_method :next_free_column

      def self.canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
        when Array then value.map { canonical(_1) }
        else value
        end
      end
      private_class_method :canonical

      def initialize(baseline:, target:, widgets:, encoded_widgets:, metadata:)
        @baseline = baseline
        @target = target
        @widgets = Array(widgets)
        @encoded_widgets = Array(encoded_widgets)
        @metadata = metadata
      end

      def apply
        verify_structural_projection!
        verify_target_baseline!
        result = deep_copy(@target)
        actionable = @widgets.select { actionable?(_1) }
        return result if actionable.empty?

        slot = sole_root_slot(result)
        matches = actionable.map { |widget| match(widget, encoded_widget(widget), slot) }
        reject_duplicate_matches!(matches)
        matches.each { |widget, encoded, native| apply_fields!(widget, encoded, native) }
        result
      end

      private

      def actionable?(widget)
        SUPPORTED_TYPES.include?(storage_type(widget)) && declared_fields(widget).any? do |field|
          scalar_field?(storage_type(widget), field) || APPEARANCE_FIELDS.key?(field)
        end
      end

      def match(widget, encoded, slot)
        candidates = slot.select do |native|
          native.is_a?(Hash) && native['$Type'] == encoded['$Type'] &&
            native['Name'].to_s == encoded['Name'].to_s
        end
        unless candidates.one?
          reason = candidates.empty? ? 'missing' : 'ambiguous'
          raise ValidationError,
                "page overlay #{reason} widget #{encoded['$Type']} #{encoded['Name'].inspect}"
        end

        [widget, encoded, candidates.first]
      end

      def reject_duplicate_matches!(matches)
        duplicates = matches.group_by { |_widget, _encoded, native| native.object_id }
                            .select { |_id, entries| entries.size > 1 }
        return if duplicates.empty?

        raise ValidationError, 'page overlay maps multiple Ruby widgets to the same native widget'
      end

      def apply_fields!(widget, encoded, native)
        type = encoded.fetch('$Type')
        declared_fields(widget).each do |field|
          native_key = SCALAR_FIELDS.fetch(type).fetch(field, nil)
          native[native_key] = deep_copy(encoded.fetch(native_key)) if native_key
          apply_appearance_field!(native, encoded, field) if APPEARANCE_FIELDS.key?(field)
        end
      end

      def apply_appearance_field!(native, encoded, field)
        native_appearance = native['Appearance']
        encoded_appearance = encoded['Appearance']
        unless native_appearance.is_a?(Hash) && encoded_appearance.is_a?(Hash)
          raise ValidationError, 'page overlay cannot safely create a missing Appearance node'
        end

        key = APPEARANCE_FIELDS.fetch(field)
        native_appearance[key] = deep_copy(encoded_appearance.fetch(key))
      end

      def storage_type(widget)
        {
          table: 'Forms$Table', layout_grid: 'Forms$LayoutGrid', data_view: 'Forms$DataView'
        }[widget.fetch(:type).to_sym]
      end

      def scalar_field?(type, field) = SCALAR_FIELDS.fetch(type).key?(field)

      def declared_fields(widget) = Array(widget[:declared_fields]).map(&:to_sym)

      def encoded_widget(widget)
        index = @widgets.index { _1.equal?(widget) }
        @encoded_widgets.fetch(index)
      end

      def verify_structural_projection!
        expected = @metadata.is_a?(Hash) ? @metadata['widgets'] || @metadata[:widgets] : nil
        raise ValidationError, 'page overlay has no structural baseline' unless expected.is_a?(Array)

        actual = self.class.metadata(@widgets).fetch('widgets')
        expected_projection = expected.map { self.class.send(:deep_stringify, _1) }
        return if actual == expected_projection

        raise_structural_projection_error(actual, expected_projection)
      end

      def raise_structural_projection_error(actual, expected)
        index = [actual.size, expected.size].max.times.find { actual[_1] != expected[_1] }
        widget = actual[index] || expected[index] || {}
        raise ValidationError,
              'page overlay contains an unsupported structural or property edit at ' \
              "#{widget['type']} #{widget['name'].inspect}"
      end

      def verify_target_baseline!
        baseline = comparable_page(@baseline)
        target = comparable_page(@target)
        return if baseline == target

        raise ValidationError,
              'page changed outside the Ruby overlay since it was exported'
      end

      def comparable_page(document)
        copy = deep_copy(document)
        %w[$ID Name name].each { copy.delete(_1) }
        scrub_supported_fields!(copy)
        IO::BsonCodec.parse(IO::BsonCodec.serialize(copy))
      end

      def scrub_supported_fields!(document) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        slot = sole_root_slot(document)
        Array(@metadata['widgets'] || @metadata[:widgets]).each do |entry|
          type = storage_type(type: entry['type'] || entry[:type])
          next unless type

          name = (entry['name'] || entry[:name]).to_s
          matches = slot.select { _1.is_a?(Hash) && _1['$Type'] == type && _1['Name'].to_s == name }
          next unless matches.one?

          native = matches.first
          SCALAR_FIELDS.fetch(type).each_value { native.delete(_1) }
          appearance = native['Appearance']
          APPEARANCE_FIELDS.each_value { appearance.delete(_1) } if appearance.is_a?(Hash)
        end
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, item| [key, deep_copy(item)] }
        when Array then value.map { deep_copy(_1) }
        else value
        end
      end
    end
  end
end
