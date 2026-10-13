# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Studio Pro design properties as Ruby declares them: design:
    # { "Size" => "Large" } on a widget, layout grid row or column, where a
    # toggle is true, an option its name, and spacing a Hash of sides and
    # options. The export adds them to projected widgets; the application
    # resolves them to theme classes when it serves a document, so editing or
    # moving a declaration changes the served classes.
    module DesignDeclarations
      # Runtime widget types and the design-properties.json type they use.
      RUNTIME_TYPES = {
        'button' => 'Button', 'sidebar_toggle' => 'Button', 'container' => 'DivContainer',
        'layout_grid' => 'LayoutGrid', 'data_view' => 'DataView', 'data_grid' => 'DataGrid',
        'list_view' => 'ListView', 'group_box' => 'GroupBox', 'static_image' => 'StaticImageViewer',
        'image_viewer' => 'DynamicImageViewer', 'label' => 'Label', 'tab_control' => 'TabContainer',
        'text' => 'DynamicText', 'table' => 'Table', 'menu_bar' => 'MenuBar',
        'navigation_tree' => 'NavigationTree', 'simple_menu_bar' => 'SimpleMenuBar',
        'template_grid' => 'TemplateGrid', 'gallery' => 'com.mendix.widget.web.gallery.Gallery'
      }.freeze
      DATA_GRID_2 = 'com.mendix.widget.web.datagrid.Datagrid'

      module_function

      # { key => design } for the widgets of one stored document, keyed like
      # DesignClasses.widget_classes.
      def declared(document, found = {})
        case document
        when Hash
          declare_widget(document, found)
          document.each_value { declared(_1, found) }
        when Array then document.each { declared(_1, found) }
        end
        found
      end

      def declare_widget(widget, found)
        name = widget['Name']
        return unless name.is_a?(String)

        declare(found, name, widget)
        return unless widget['$Type'] == 'Forms$LayoutGrid'

        each_grid_element(widget, name) { |key, element| declare(found, key, element) }
      end

      def each_grid_element(grid, name)
        IO::BsonCodec.parse_array(grid['Rows'])[:items].each_with_index do |row, row_index|
          yield "#{name}/rows/#{row_index}", row
          IO::BsonCodec.parse_array(row['Columns'])[:items].each_with_index do |column, column_index|
            yield "#{name}/rows/#{row_index}/columns/#{column_index}", column
          end
        end
      end

      def declare(found, key, element)
        values = IO::BsonCodec.parse_array(element.dig('Appearance', 'DesignProperties'))[:items]
        design = values.select { _1.is_a?(Hash) }.to_h { [_1['Key'].to_s, declared_value(_1['Value'])] }
        found[key] = design unless design.empty?
      end

      def declared_value(value)
        case value.is_a?(Hash) && value['$Type']
        when 'Forms$OptionDesignPropertyValue' then value['Option'].to_s
        when 'Forms$CompoundDesignPropertyValue'
          IO::BsonCodec.parse_array(value['Properties'])[:items].to_h do |side|
            [side['Key'].to_s, side.dig('Value', 'Option').to_s]
          end
        else true
        end
      end

      # The class names of a declared design for a design-properties.json type.
      def classes(type, design, definitions)
        values = design.map { |key, value| { 'Key' => key.to_s, 'Value' => stored_value(value) } }
        DesignClasses.resolve(type, values, definitions)
      end

      def stored_value(value)
        case value
        when true then { '$Type' => 'Forms$ToggleDesignPropertyValue' }
        when Hash
          sides = value.map { |key, option| { 'Key' => key.to_s, 'Value' => { 'Option' => option.to_s } } }
          { '$Type' => 'Forms$CompoundDesignPropertyValue', 'Properties' => [2, *sides] }
        else { '$Type' => 'Forms$OptionDesignPropertyValue', 'Option' => value.to_s }
        end
      end

      # Calls the block with each widget node, layout grid row and column of
      # projected or served widgets and the key and theme type it is known by,
      # replacing the node with the block's result.
      module Walk
        module_function

        def map(document, &block)
          case document
          when Hash then widget(document.transform_values { map(_1, &block) }, &block)
          when Array then document.map { map(_1, &block) }
          else document
          end
        end

        def widget(node, &block)
          name = node['name']
          return node unless node.key?('type') && name.is_a?(String)

          node = yield(node, name, type_name(node))
          node['type'] == 'layout_grid' ? grid(node, name, &block) : node
        end

        def grid(node, name, &block)
          options = node['options'] || {}
          rows = Array(options['rows']).each_with_index.map do |row, index|
            key = "#{name}/rows/#{index}"
            columns = Array(row['columns']).each_with_index.map do |column, column_index|
              yield(column, "#{key}/columns/#{column_index}", 'LayoutGridColumn')
            end
            yield(row.merge('columns' => columns), key, 'LayoutGridRow')
          end
          node.merge('options' => options.merge('rows' => rows))
        end

        # Data grid 2 and gallery are pluggable widgets in the theme.
        def type_name(node)
          return node.dig('options', 'widget_id').to_s if node['type'] == 'pluggable_widget'
          return DATA_GRID_2 if node['type'] == 'data_grid' && node.dig('options', 'presentation').to_s == 'datagrid2'

          RUNTIME_TYPES.fetch(node['type'].to_s) { node['type'].to_s }
        end
      end

      # Data views declare their design as typed design_properties.
      module Typed
        module_function

        def properties(node)
          properties = node.dig('options', 'design_properties')
          properties if properties.is_a?(Array)
        end

        # The design of typed data view design_properties.
        def design(properties)
          properties.select { _1.is_a?(Hash) }.to_h do |property|
            value = if property.key?('properties')
                      Array(property['properties']).to_h { [_1['key'].to_s, _1['option'].to_s] }
                    else
                      property['option'] || true
                    end
            [property['key'].to_s, value]
          end
        end
      end

      # Adds stored designs to projected widgets as their design option. Data
      # views already declare theirs as typed design_properties, and native
      # fragments keep theirs in the typed fragment.
      def inject(widgets, designs)
        return widgets if designs.empty?

        Walk.map(widgets) do |node, key, _type|
          design = designs[key]
          next node unless design && !Typed.properties(node) && node['type'] != 'native_widget'

          node.merge('options' => (node['options'] || {}).merge('design' => design))
        end
      end

      # Replaces the design option of served widgets with its theme classes.
      def resolve(widgets, definitions)
        Walk.map(widgets) do |node, _key, type|
          design = node.dig('options', 'design')
          design = Typed.design(Typed.properties(node)) if !design.is_a?(Hash) && Typed.properties(node)
          next node unless design.is_a?(Hash)

          names = classes(type, design, definitions)
          options = node['options'].except('design')
          node.merge('options' => names.empty? ? options : options.merge('design_class' => names))
        end
      end

      # The keys whose declared design reached a projected node.
      def injected_keys(projected, designs)
        keys = []
        Walk.map(projected) do |node, key, _type|
          keys << key if designs.key?(key) && (node.dig('options', 'design') || Typed.properties(node))
          node
        end
        keys
      end
    end
  end
end
