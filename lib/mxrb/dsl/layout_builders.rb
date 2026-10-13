# frozen_string_literal: true

module Mxrb
  module Dsl
    class TableBuilder
      include OverlayFields

      WIDTH_UNITS = %i[weight percentage pixels].freeze

      def initialize(name, width_unit:, tab_index:, class_name:, style:, dynamic_class:, visible:)
        @declared_fields = declared_fields(
          width_unit:, tab_index:, class: class_name, style:, dynamic_class:, visible:
        )
        width_unit = default_value(width_unit, :weight)
        tab_index = default_value(tab_index, 0)
        class_name = default_value(class_name, nil)
        style = default_value(style, nil)
        dynamic_class = default_value(dynamic_class, nil)
        visible = default_value(visible, nil)
        width_unit = width_unit.to_sym
        raise ArgumentError, 'table width_unit must be weight, percentage, or pixels' unless
          WIDTH_UNITS.include?(width_unit)

        @name = name.to_s
        @options = {
          width_unit: width_unit.to_sym, tab_index: tab_index.to_i,
          class: class_name&.to_s, style: style&.to_s,
          dynamic_class: dynamic_class&.to_s, visible: visible&.to_s
        }.compact
        @columns = []
        @rows = []
      end

      def column(width: nil, &block)
        builder = TableColumnBuilder.new(width)
        builder.instance_eval(&block) if block
        @columns << builder.to_h
      end

      def row(class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        builder = TableRowBuilder.new(
          class_name:, style:, dynamic_class:, visible:
        )
        builder.instance_eval(&block) if block
        @rows << builder.to_h
      end

      def to_h
        validate_layout!
        options = @options.merge(columns: @columns, rows: @rows)
        { type: :table, name: @name, options:, events: [], declared_fields: @declared_fields }
      end

      private

      def validate_layout!
        raise ArgumentError, 'table requires at least one column' if @columns.empty?

        occupied = {}
        @rows.each_with_index do |row, row_index|
          cursor = 0
          row.fetch(:cells).each do |cell|
            column = cell[:column] || next_available_column(occupied, row_index, cursor)
            validate_cell_bounds!(cell, row_index, column)
            occupy_cell!(occupied, cell, row_index, column)
            cell[:column] = column
            cursor = column + cell.fetch(:colspan)
          end
        end
      end

      def next_available_column(occupied, row, cursor)
        cursor += 1 while occupied[[row, cursor]]
        cursor
      end

      def validate_cell_bounds!(cell, row, column)
        right = column + cell.fetch(:colspan)
        bottom = row + cell.fetch(:rowspan)
        raise ArgumentError, 'table cell exceeds column count' if right > @columns.size
        raise ArgumentError, 'table cell rowspan exceeds row count' if bottom > @rows.size
      end

      def occupy_cell!(occupied, cell, row, column)
        coordinates = (row...(row + cell.fetch(:rowspan))).to_a.product(
          (column...(column + cell.fetch(:colspan))).to_a
        )
        raise ArgumentError, 'table cells cannot overlap' if coordinates.any? { occupied[_1] }

        coordinates.each { occupied[_1] = true }
      end
    end

    module LayoutGridValues
      GRID_WIDTHS = %i[full fixed].freeze
      ALIGNMENTS = %i[none start center end].freeze

      private

      def normalize_grid_width(value)
        width = value.to_s.downcase.delete_suffix('_width').to_sym
        raise ArgumentError, 'layout grid width must be :full or :fixed' unless GRID_WIDTHS.include?(width)

        width
      end

      def normalize_grid_alignment(value)
        alignment = value.to_s
                         .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
                         .downcase.to_sym
        raise ArgumentError, "unsupported layout grid alignment #{value.inspect}" unless
          ALIGNMENTS.include?(alignment)

        alignment
      end

      def normalize_grid_weight(value)
        return value if %i[grow auto].include?(value)

        weight = Integer(value)
        return :grow if weight == -1
        return :auto if weight == -2
        return weight if (1..12).cover?(weight)

        raise ArgumentError, 'layout grid weight must be 1..12, :grow, or :auto'
      rescue ArgumentError, TypeError
        raise ArgumentError, 'layout grid weight must be 1..12, :grow, or :auto'
      end
    end

    class LayoutGridBuilder
      include LayoutGridValues
      include OverlayFields

      def initialize(name, width:, tab_index:, class_name:, style:, dynamic_class:, visible:)
        @declared_fields = declared_fields(
          width:, tab_index:, class: class_name, style:, dynamic_class:, visible:
        )
        width = default_value(width, :full)
        tab_index = default_value(tab_index, 0)
        class_name = default_value(class_name, nil)
        style = default_value(style, nil)
        dynamic_class = default_value(dynamic_class, nil)
        visible = default_value(visible, nil)
        @name = name.to_s
        @options = {
          width: normalize_grid_width(width), tab_index: tab_index.to_i,
          class: class_name&.to_s, style: style&.to_s,
          dynamic_class: dynamic_class&.to_s, visible: visible&.to_s
        }.compact
        @rows = []
      end

      def row(horizontal_alignment: :none, vertical_alignment: :none, gutters: true,
              class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        builder = LayoutGridRowBuilder.new(
          horizontal_alignment:, vertical_alignment:, gutters:, class_name:, style:,
          dynamic_class:, visible:
        )
        builder.instance_eval(&block) if block
        @rows << builder.to_h
      end

      def to_h
        {
          type: :layout_grid, name: @name, options: @options.merge(rows: @rows), events: [],
          declared_fields: @declared_fields
        }
      end
    end

    class LayoutGridRowBuilder
      include LayoutGridValues

      def initialize(horizontal_alignment:, vertical_alignment:, gutters:, class_name:, style:,
                     dynamic_class:, visible:)
        @options = {
          horizontal_alignment: normalize_grid_alignment(horizontal_alignment),
          vertical_alignment: normalize_grid_alignment(vertical_alignment), gutters: gutters == true,
          class: class_name&.to_s, style: style&.to_s,
          dynamic_class: dynamic_class&.to_s, visible: visible&.to_s
        }.compact
        @columns = []
      end

      def column(desktop: :grow, tablet: :grow, phone: :grow, vertical_alignment: :none,
                 class_name: nil, style: nil, dynamic_class: nil, &block)
        builder = LayoutGridColumnBuilder.new(
          desktop:, tablet:, phone:, vertical_alignment:, class_name:, style:, dynamic_class:
        )
        builder.instance_eval(&block) if block
        @columns << builder.to_h
      end

      def to_h = { options: @options, columns: @columns }
    end

    class LayoutGridColumnBuilder
      include WidgetDsl
      include LayoutGridValues

      def initialize(desktop:, tablet:, phone:, vertical_alignment:, class_name:, style:, dynamic_class:)
        @options = {
          desktop: normalize_grid_weight(desktop), tablet: normalize_grid_weight(tablet),
          phone: normalize_grid_weight(phone),
          vertical_alignment: normalize_grid_alignment(vertical_alignment),
          class: class_name&.to_s, style: style&.to_s, dynamic_class: dynamic_class&.to_s
        }.compact
        @widgets = []
      end

      def to_h = { options: @options, widgets: @widgets }

      private

      def _widget_list = @widgets
    end

    class TableColumnBuilder
      def initialize(width = nil) = (@width = width)

      def width(value) = (@width = value)

      def to_h
        value = @width.to_i
        raise ArgumentError, 'table column width must be positive' unless value.positive?

        { width: value }
      end
    end

    class TableRowBuilder
      def initialize(class_name:, style:, dynamic_class:, visible:)
        @options = {
          class: class_name&.to_s, style: style&.to_s,
          dynamic_class: dynamic_class&.to_s, visible: visible&.to_s
        }.compact
        @cells = []
      end

      def cell(column: nil, colspan: 1, rowspan: 1, header: false, class_name: nil,
               style: nil, dynamic_class: nil, &block)
        builder = TableCellBuilder.new(
          column:, colspan:, rowspan:, header:, class_name:, style:,
          dynamic_class:
        )
        builder.instance_eval(&block) if block
        @cells << builder.to_h
      end

      def to_h = { options: @options, cells: @cells }
    end

    class TableCellBuilder
      include WidgetDsl

      def initialize(column:, colspan:, rowspan:, header:, class_name:, style:, dynamic_class:)
        @column = column&.to_i
        @colspan = colspan.to_i
        @rowspan = rowspan.to_i
        validate_dimensions!

        @header = header == true
        @options = {
          class: class_name&.to_s, style: style&.to_s,
          dynamic_class: dynamic_class&.to_s
        }.compact
        @widgets = []
      end

      def to_h
        {
          column: @column, colspan: @colspan, rowspan: @rowspan,
          header: @header, options: @options, widgets: @widgets
        }.compact
      end

      private

      def validate_dimensions!
        raise ArgumentError, 'table cell column cannot be negative' if @column&.negative?
        raise ArgumentError, 'table cell colspan must be positive' unless @colspan.positive?
        raise ArgumentError, 'table cell rowspan must be positive' unless @rowspan.positive?
      end

      def _widget_list = @widgets
    end

    class SearchBarBuilder
      def initialize
        @fields = []
      end

      def search_field(attribute, caption: nil)
        @fields << { attribute: attribute.to_s, caption: caption }
      end

      def to_h
        { fields: @fields }
      end
    end

    class ToolbarBuilder
      def initialize
        @buttons = []
      end

      def new_button(caption: 'New')
        @buttons << { type: :new, caption: caption }
      end

      def delete_button(caption: 'Delete')
        @buttons << { type: :delete, caption: caption }
      end

      def search_button(caption: 'Search')
        @buttons << { type: :search, caption: caption }
      end

      def export_button(caption: 'Export')
        @buttons << { type: :export, caption: caption }
      end

      def to_h
        { buttons: @buttons }
      end
    end

    # Builds nested widgets inside a container widget.
    class ContainerBuilder
      include WidgetDsl
      include WidgetEvents

      def initialize(name, class_name: nil, style: nil, dynamic_class: nil, visible: nil)
        @name = name.to_s
        @appearance = {
          class: class_name&.to_s, style: style&.to_s,
          dynamic_class: dynamic_class&.to_s, visible: visible&.to_s
        }.compact.reject { |_key, value| value.empty? }
        @children = []
        @events = []
      end

      def to_h
        { type: :container, name: @name, options: @appearance, children: @children, events: @events }
      end

      private

      def _widget_list = @children
    end

    class LayoutGridBuilder
      private

      def design_rows = @rows
    end

    class LayoutGridRowBuilder
      private

      def design_columns = @columns
    end

    WidgetDesign.wrap(WidgetDsl, WidgetDsl.public_instance_methods(false), list: :_widget_list)

    [WidgetDsl, LayoutGridBuilder, LayoutGridRowBuilder].each { _1.include(WidgetDesign::Helpers) }

    WidgetDesign.wrap(LayoutGridBuilder, %i[row], list: :design_rows)

    WidgetDesign.wrap(LayoutGridRowBuilder, %i[column], list: :design_columns)
  end
end
