# frozen_string_literal: true

require 'json'

module Mxrb
  module RubyApp
    # The classes Studio Pro design properties add to widgets, resolved from the
    # project theme's web design-properties.json files as the Mendix client does.
    # Widgets declared in Ruby carry their design (see DesignDeclarations); the
    # export records classes per document and widget name only for typed
    # native fragments without such declarations.
    module DesignClasses
      PATH = File.join('.mxrb', 'design_classes.json')
      WIDGET_TYPES = {
        'Forms$ActionButton' => 'Button', 'Forms$SidebarToggleButton' => 'Button',
        'Forms$DivContainer' => 'DivContainer', 'Forms$LayoutGrid' => 'LayoutGrid',
        'Forms$DataView' => 'DataView', 'Forms$DataGrid' => 'DataGrid', 'Forms$ListView' => 'ListView',
        'Forms$GroupBox' => 'GroupBox', 'Forms$StaticImageViewer' => 'StaticImageViewer',
        'Forms$ImageViewer' => 'DynamicImageViewer', 'Forms$Label' => 'Label', 'Forms$TabControl' => 'TabContainer',
        'Forms$DynamicText' => 'DynamicText', 'Forms$Table' => 'Table', 'Forms$MenuBar' => 'MenuBar',
        'Forms$NavigationTree' => 'NavigationTree', 'Forms$SimpleMenuBar' => 'SimpleMenuBar',
        'Forms$TemplateGrid' => 'TemplateGrid'
      }.freeze

      module_function

      # Widget type name => property definitions, merged across theme modules.
      def definitions(root)
        files = Dir[File.join(root, 'themesource', '*', 'web', 'design-properties.json')].sort +
                Dir[File.join(root, 'theme', 'web', 'design-properties.json')]
        files.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |file, merged|
          read_definitions(file).each { |type, properties| merged[type].concat(Array(properties)) }
        end
      end

      def read_definitions(file)
        JSON.parse(File.read(file))
      rescue JSON::ParserError
        {}
      end

      # { "Module.Document" => { "widgetName" => "class names" } } for the
      # pages, snippets and layouts of a project.
      def collect(project, root)
        definitions = definitions(root)
        return {} if definitions.empty?

        project.modules.each_with_object({}) do |mod, result|
          documents(mod).each do |name, document|
            widgets = widget_classes(document, definitions)
            result["#{mod.name}.#{name}"] = widgets unless widgets.empty?
          end
        end
      end

      def documents(mod)
        mod.pages.map { [_1.name, _1.raw_document] } + mod.presentation_documents.map { [_1[:name], _1[:doc]] }
      end

      def widget_classes(document, definitions, found = {})
        case document
        when Hash
          record_widget(document, definitions, found)
          document.each_value { widget_classes(_1, definitions, found) }
        when Array then document.each { widget_classes(_1, definitions, found) }
        end
        found
      end

      def record_widget(widget, definitions, found)
        name = widget['Name']
        return unless name.is_a?(String)

        record(found, name, type_name(widget), widget, definitions)
        record_layout_grid(name, widget, definitions, found) if widget['$Type'] == 'Forms$LayoutGrid'
      end

      # Layout grid rows and columns have no names; they are recorded by
      # position as "grid/rows/0" and "grid/rows/0/columns/1".
      def record_layout_grid(name, grid, definitions, found)
        IO::BsonCodec.parse_array(grid['Rows'])[:items].each_with_index do |row, row_index|
          record(found, "#{name}/rows/#{row_index}", 'LayoutGridRow', row, definitions)
          IO::BsonCodec.parse_array(row['Columns'])[:items].each_with_index do |column, column_index|
            record(found, "#{name}/rows/#{row_index}/columns/#{column_index}", 'LayoutGridColumn', column, definitions)
          end
        end
      end

      def record(found, key, type, element, definitions)
        values = Array(IO::BsonCodec.parse_array(element.dig('Appearance', 'DesignProperties'))[:items])
        classes = values.empty? ? '' : resolve(type, values, definitions)
        found[key] = classes unless classes.empty?
      end

      def type_name(widget)
        return widget.dig('Type', 'WidgetId').to_s if widget['$Type'] == 'CustomWidgets$CustomWidget'

        WIDGET_TYPES.fetch(widget['$Type'].to_s) { widget['$Type'].to_s.split('$').last.to_s }
      end

      # The class names of design property values for a widget type.
      def resolve(type, values, definitions)
        properties = definitions.fetch(type, []) + definitions.fetch('Widget', [])
        values.filter_map do |value|
          next unless value.is_a?(Hash)

          property = properties.find { _1['name'] == value['Key'] }
          property && property_classes(property, value['Value'])
        end.flatten.compact.uniq.join(' ')
      end

      def property_classes(property, value)
        case value.is_a?(Hash) && value['$Type']
        when 'Forms$ToggleDesignPropertyValue' then property['class']
        when 'Forms$OptionDesignPropertyValue'
          Array(property['options']).find { _1['name'] == value['Option'] }&.fetch('class', nil)
        when 'Forms$CompoundDesignPropertyValue'
          IO::BsonCodec.parse_array(value['Properties'])[:items].map { spacing_class(property, _1) }
        end
      end

      # A spacing side such as padding-top with an option such as S.
      def spacing_class(property, value)
        area, side = value['Key'].to_s.split('-', 2)
        group = area == 'padding' ? property['padding'] : property['margin']
        entry = Array(group).find { _1['name'] == value.dig('Value', 'Option') }
        entry&.dig(side, 'class')
      end

      def apply(document, widgets) = Served.apply(document, widgets)

      # Adds the recorded classes to the widgets of served documents.
      module Served
        module_function

        def apply(document, widgets)
          return document if widgets.nil? || widgets.empty?

          case document
          when Hash then apply_widget(document.transform_values { apply(_1, widgets) }, widgets)
          when Array then document.map { apply(_1, widgets) }
          else document
          end
        end

        def apply_widget(node, widgets)
          name = node['name']
          return node unless node.key?('type') && name.is_a?(String)

          node = with_class(node, widgets[name])
          node['type'] == 'layout_grid' ? apply_layout_grid(node, name, widgets) : node
        end

        def apply_layout_grid(grid, name, widgets)
          options = grid['options'] || {}
          rows = Array(options['rows']).each_with_index.map do |row, index|
            apply_row(row, "#{name}/rows/#{index}", widgets)
          end
          grid.merge('options' => options.merge('rows' => rows))
        end

        def apply_row(row, key, widgets)
          columns = Array(row['columns']).each_with_index.map do |column, index|
            with_class(column, widgets["#{key}/columns/#{index}"])
          end
          with_class(row.merge('columns' => columns), widgets[key])
        end

        def with_class(node, classes)
          return node unless classes

          node.merge('options' => (node['options'] || {}).merge('design_class' => classes))
        end
      end
    end
  end
end
