# frozen_string_literal: true

require 'fileutils'
require 'json'

module Mxrb
  module Compiler
    LegacyPageBuild = Data.define(:directory, :files, :bytes, :unsupported_widgets)

    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    # Writes deterministic Dojo page XML for the built-in Data Grid 1 contract.
    class LegacyPageBuilder
      include ModelValues

      # Model elements that own visible client widgets. Supporting a page means
      # rendering these elements, not merely serializing their nested settings.
      VISUAL_WIDGET_TYPES = %w[
        Forms$ActionButton Forms$CheckBox Forms$DataGrid Forms$DataView Forms$DatePicker
        Forms$DivContainer Forms$DropDown Forms$DynamicText Forms$ImageUploader Forms$ImageViewer
        Forms$Label
        Forms$Header Forms$LayoutGrid Forms$ListView Forms$MenuBar Forms$NavigationTree
        Forms$RadioButtonGroup Forms$ReferenceSelector Forms$ScrollContainer
        Forms$ReferenceSetSelector Forms$Table Forms$TemplateGrid Forms$VerticalSplitPane
        Forms$SidebarToggleButton Forms$SimpleMenuBar
        Forms$MobileBackButton Forms$MobileCancelButton Forms$MobileSaveButton
        Forms$SnippetCallWidget Forms$StaticImageViewer Forms$TabControl Forms$TextArea
        Forms$TextBox Forms$InputReferenceSetSelector CustomWidgets$CustomWidget
      ].freeze
      ACTION_BUTTON_TYPES = %w[
        Forms$CancelChangesClientAction Forms$ClosePageClientAction Forms$FormAction
        Forms$MicroflowAction Forms$NoAction Forms$OpenLinkClientAction
        Forms$SaveChangesClientAction
      ].freeze
      BOUND_WIDGET_TYPES = %w[
        Forms$CheckBox Forms$DatePicker Forms$DropDown Forms$InputReferenceSetSelector
        Forms$RadioButtonGroup Forms$ReferenceSelector Forms$TextArea Forms$TextBox
      ].freeze

      def initialize(source, web_root, profiles: [:dojo])
        @source = source
        @web_root = web_root
        @profiles = profiles
        @unsupported = Hash.new { |hash, key| hash[key] = [] }
      end

      def build
        pages = legacy_pages
        layouts = legacy_layouts
        languages.each do |language|
          layouts.each { write_layout(_1, language) }
          pages.each { write_page(_1, language) }
        end
        write_manifest
        files = Dir.glob(File.join(@web_root, 'pages', '**', '*.xml')).select { File.file?(_1) }
        LegacyPageBuild.new(
          directory: File.join(@web_root, 'pages'), files: files.length,
          bytes: files.sum { File.size(_1) }, unsupported_widgets: frozen_unsupported
        )
      end

      # Performs the same widget audit as #build without writing deployment files.
      def audit
        @unsupported.clear
        (legacy_layouts + legacy_pages).each do |unit|
          name = "#{unit.module_name}.#{unit.document['Name']}"
          audit_unsupported_widgets(unit.document, name)
          descendants(unit.document).select { _1['$Type'] == 'Forms$DataGrid' }.each_with_index do |grid, index|
            compiler = LegacyDataGridCompiler.new(@source, name, grid, language: 'en_US', sequence: index + 1)
            compiler.html
            @unsupported[name].concat(compiler.unsupported)
          end
        end
        frozen_unsupported
      end

      private

      def legacy_pages
        units = @source.units_of('Forms$Page')
        @source.is_a?(SourceModel) ? units.select { @source.web_page?(_1) } : units
      end

      def legacy_layouts
        units = @source.units_of('Forms$Layout')
        @source.is_a?(SourceModel) ? units.select { @source.web_layout?(_1) } : units
      end

      def write_page(unit, language)
        name = "#{unit.module_name}.#{unit.document['Name']}"
        audit_unsupported_widgets(unit.document, name)
        @widget_sequence = 0
        @widget_ids_by_name = {}
        @templates = []
        rendered = page_widgets(unit.document).map { render_widget(_1, name, language) }.join
        path = File.join(@web_root, 'pages', language, unit.module_name, "#{unit.document['Name']}.page.xml")
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, page_xml(unit, language, rendered))
      end

      def write_layout(unit, language)
        name = "#{unit.module_name}.#{unit.document['Name']}"
        audit_unsupported_widgets(unit.document, name)
        @widget_sequence = 0
        @widget_ids_by_name = {}
        @templates = []
        rendered = layout_widgets(unit.document).map { render_widget(_1, name, language) }.join
        path = File.join(@web_root, 'pages', language, unit.module_name, "#{unit.document['Name']}.layout.xml")
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, layout_xml(unit, rendered))
      end

      def audit_unsupported_widgets(root, page_name, initial_data_view_context: false)
        visit = lambda do |value, data_view_context = initial_data_view_context|
          case value
          when Hash
            type = value['$Type'].to_s
            data_view_context ||= %w[Forms$DataView Forms$ListView].include?(type)
            next if type == 'Forms$DataGrid'

            if type == 'Forms$TemplateGrid'
              audit_template_grid(value, page_name)
              next
            end

            audit_widget(value, type, page_name, data_view_context)

            value.each_value { visit.call(_1, data_view_context) }
          when Array then value.each { visit.call(_1, data_view_context) }
          end
        end
        visit.call(root)
      end

      def audit_widget(widget, type, page_name, data_view_context)
        if VISUAL_WIDGET_TYPES.include?(type) && !supported_widget_type?(type)
          @unsupported[page_name] << type
        elsif type == 'Forms$DynamicText' && !supported_dynamic_text?(widget, data_view_context)
          @unsupported[page_name] << 'Forms$DynamicText(parameters)'
        elsif type == 'Forms$ActionButton' && !supported_action_button?(widget)
          action_type = widget.dig('Action', '$Type').to_s
          @unsupported[page_name] << (action_type.empty? ? 'Forms$ActionButton(action)' : action_type)
        elsif type == 'Forms$DataView' && !supported_data_view?(widget)
          source_type = widget.dig('DataSource', '$Type').to_s
          @unsupported[page_name] << (source_type.empty? ? 'Forms$DataView(source)' : source_type)
        elsif type == 'Forms$ListView' && !supported_list_view?(widget)
          source_type = widget.dig('DataSource', '$Type').to_s
          @unsupported[page_name] << (source_type.empty? ? 'Forms$ListView(source)' : source_type)
        elsif type == 'Forms$StaticImageViewer' && !supported_static_image?(widget)
          @unsupported[page_name] << type
        elsif type == 'Forms$ImageViewer' && !supported_image_viewer?(widget, data_view_context)
          @unsupported[page_name] << type
        elsif type == 'Forms$ImageUploader' && !data_view_context
          @unsupported[page_name] << type
        elsif type == 'Forms$ReferenceSetSelector' &&
              !supported_reference_set_selector?(widget, data_view_context, page_name)
          @unsupported[page_name] << type
        elsif %w[Forms$MenuBar Forms$NavigationTree Forms$SimpleMenuBar].include?(type) &&
              menu_identifier(widget['MenuSource']).to_s.empty?
          @unsupported[page_name] << type
        elsif type == 'Forms$SnippetCallWidget'
          audit_snippet_call(widget, page_name, data_view_context)
        elsif type == 'CustomWidgets$CustomWidget' && !supported_custom_widget?(widget)
          identifier = widget.dig('Type', 'WidgetId').to_s
          @unsupported[page_name] << (identifier.empty? ? type : identifier)
        elsif BOUND_WIDGET_TYPES.include?(type) && !supported_bound_widget?(widget, data_view_context)
          @unsupported[page_name] << type
        elsif type == 'Forms$DivContainer'
          action_type = widget.dig('OnClickAction', '$Type').to_s
          @unsupported[page_name] << 'Forms$DivContainer(onClick)' \
            unless action_type.empty? || action_type == 'Forms$NoAction'
        end
      end

      def audit_template_grid(widget, page_name)
        compiler = LegacyDataGridCompiler.new(
          @source, page_name, widget, language: 'en_US', sequence: 1
        )
        compiler.html
        @unsupported[page_name].concat(compiler.unsupported)
        audit_unsupported_widgets(
          widget['Contents'] || {}, page_name, initial_data_view_context: true
        )
      end

      def page_xml(unit, language, content)
        page = unit.document
        title = translated(page['Title'], language)
        layout = page.dig('FormCall', 'Form').to_s.tr('.', '/')
        argument = array(page.dig('FormCall', 'Arguments')).first
        parameter = layout_argument_id(argument&.fetch('Parameter', '').to_s)
        css = page_css_classes(page)
        class_attribute = css.empty? ? '' : " class='#{escape(css)}'"
        "\uFEFF<?xml version='1.0' encoding='utf-8'?>" \
          "<m:page id='#{unit.id}' xmlns='http://www.w3.org/1999/xhtml' " \
          "title='#{escape(title)}'#{class_attribute} xmlns:m='http://schemas.mendix.com/forms/1.0'>" \
          "<m:layouts>#{layout.empty? ? '' : "<m:layout path='#{escape(layout)}.layout.xml'></m:layout>"}</m:layouts>" \
          "<m:arguments><m:argument parameterName='#{escape(parameter)}'>#{content}</m:argument></m:arguments>" \
          "#{templates_xml}</m:page>"
      end

      def layout_xml(unit, content)
        "\uFEFF<?xml version='1.0' encoding='utf-8'?>" \
          "<m:layout id='#{unit.id}' xmlns='http://www.w3.org/1999/xhtml' " \
          "xmlns:m='http://schemas.mendix.com/forms/1.0'>" \
          "<m:arguments><m:argument>#{content}</m:argument></m:arguments>#{templates_xml}</m:layout>"
      end

      def render_widget(widget, page_name, language)
        return '' unless widget.is_a?(Hash)

        case widget['$Type']
        when 'Forms$VerticalFlow'
          widget_children(widget).map { render_widget(_1, page_name, language) }.join
        when 'Forms$Placeholder'
          identifier = IO::BsonCodec.extract_id(widget['$ID']) || widget['Name'].to_s
          "<div data-mx-placeholder='#{escape(identifier)}' class='mx-placeholder'></div>"
        when 'Forms$DivContainer'
          render_container(widget, page_name, language)
        when 'Forms$Table'
          render_table(widget, page_name, language)
        when 'Forms$TemplateGrid'
          render_template_grid(widget, page_name, language)
        when 'Forms$LayoutGrid'
          render_layout_grid(widget, page_name, language)
        when 'Forms$LayoutGridRow'
          render_grid_row(widget, page_name, language)
        when 'Forms$LayoutGridColumn'
          render_grid_column(widget, page_name, language)
        when 'Forms$ScrollContainer'
          render_scroll_container(widget, page_name, language)
        when 'Forms$Header'
          render_header(widget, page_name, language)
        when 'Forms$SidebarToggleButton'
          render_sidebar_toggle(widget, language)
        when 'Forms$NavigationTree', 'Forms$MenuBar', 'Forms$SimpleMenuBar'
          render_navigation(widget)
        when 'Forms$ActionButton'
          render_action_button(widget, language)
        when 'Forms$MobileSaveButton'
          render_mobile_button(widget, language, 'mxui.widget.SaveButton')
        when 'Forms$MobileCancelButton'
          render_mobile_button(widget, language, 'mxui.widget.CancelButton')
        when 'Forms$MobileBackButton'
          render_mobile_button(widget, language, 'mxui.widget.BackButton')
        when 'Forms$DynamicText'
          render_dynamic_text(widget, language)
        when 'Forms$DataView'
          render_data_view(widget, page_name, language)
        when 'Forms$ListView'
          render_list_view(widget, page_name, language)
        when 'Forms$TextBox', 'Forms$TextArea', 'Forms$CheckBox', 'Forms$DatePicker',
             'Forms$DropDown', 'Forms$RadioButtonGroup', 'Forms$ReferenceSelector',
             'Forms$InputReferenceSetSelector'
          render_bound_input(widget, language)
        when 'Forms$Label'
          render_label(widget, language)
        when 'Forms$StaticImageViewer'
          render_static_image(widget)
        when 'Forms$ImageViewer'
          render_image_viewer(widget)
        when 'Forms$ImageUploader'
          render_image_uploader(widget)
        when 'Forms$ReferenceSetSelector'
          render_reference_set_selector(widget, page_name, language)
        when 'Forms$TabControl'
          render_tab_control(widget, page_name, language)
        when 'Forms$SnippetCallWidget'
          render_snippet_call(widget, page_name, language)
        when 'CustomWidgets$CustomWidget'
          render_custom_widget(widget, language)
        when 'Forms$DataGrid'
          render_data_grid(widget, page_name, language)
        else
          ''
        end
      end

      def render_container(widget, page_name, language)
        children = widget_children(widget).map { render_widget(_1, page_name, language) }.join
        tag = widget['RenderMode'].to_s == 'Span' ? 'span' : 'div'
        "<#{tag}#{html_attributes(widget, base: nil)}>#{children}</#{tag}>"
      end

      def render_table(widget, page_name, language)
        columns = array(widget['ColumnWidths'])
        colgroup = columns.map do |column|
          "<col style='width:#{column['Value'].to_i}%'></col>"
        end.join
        rows = array(widget['Rows']).each_with_index.map do |row, index|
          cells = array(widget['Cells']).select { _1['TopRowIndex'].to_i == index }
                                        .sort_by { _1['LeftColumnIndex'].to_i }
          content = cells.map { render_table_cell(_1, page_name, language) }.join
          "<tr#{html_attributes(row, base: nil)}>#{content}</tr>"
        end.join
        "<table#{html_attributes(widget, base: 'mx-table')}><colgroup>#{colgroup}</colgroup>" \
          "<tbody>#{rows}</tbody></table>"
      end

      def render_table_cell(cell, page_name, language)
        tag = cell['IsHeader'] == true ? 'th' : 'td'
        spans = {}
        spans['colspan'] = cell['Width'].to_i if cell['Width'].to_i > 1
        spans['rowspan'] = cell['Height'].to_i if cell['Height'].to_i > 1
        span_attributes = spans.map { |key, value| " #{key}='#{value}'" }.join
        content = widget_children(cell).map { render_widget(_1, page_name, language) }.join
        "<#{tag}#{html_attributes(cell, base: nil)}#{span_attributes}>#{content}</#{tag}>"
      end

      def render_template_grid(widget, page_name, language)
        sequence = next_widget_sequence
        compiler = LegacyDataGridCompiler.new(
          @source, page_name, widget, language:, sequence:
        )
        html = compiler.html
        @unsupported[page_name].concat(compiler.unsupported)
        entity = widget.dig('DataSource', 'EntityPath').to_s
        @data_view_stack ||= []
        @data_view_stack << { entity:, label_width: 0, editable: false }
        content = widget_children(widget['Contents'] || {}).map do |child|
          render_widget(child, page_name, language)
        end.join
        @data_view_stack.pop
        @templates << "<m:template widget-id='#{escape(compiler.id)}' name='content'>" \
                      "#{content}</m:template>"
        html
      end

      def render_layout_grid(widget, page_name, language)
        render_structural_widget(
          widget, array(widget['Rows']), page_name, language,
          base: 'mx-layoutgrid mx-layoutgrid-fluid'
        )
      end

      def render_grid_row(widget, page_name, language)
        render_structural_widget(widget, array(widget['Columns']), page_name, language, base: 'row')
      end

      def render_grid_column(widget, page_name, language)
        classes = ['col', grid_weight_class('md', widget['Weight']),
                   grid_weight_class('sm', widget['TabletWeight']),
                   grid_weight_class('xs', widget['PhoneWeight'])].compact.join(' ')
        render_structural_widget(widget, widget_children(widget), page_name, language, base: classes)
      end

      def render_structural_widget(widget, children, page_name, language, base:)
        content = children.map { render_widget(_1, page_name, language) }.join
        "<div#{html_attributes(widget, base:)}>#{content}</div>"
      end

      def render_scroll_container(widget, page_name, language)
        fixed = widget['ScrollBehavior'] == 'PerRegion'
        sides = [widget['Left'], widget['Right']].compact
        return render_vertical_scroll_container(widget, page_name, language, fixed:) if sides.empty?

        props = scroll_container_properties(widget, %w[Left CenterRegion Right], fixed:)
        center = render_scroll_region(
          widget['CenterRegion'], 'center', page_name, language, nested: true
        ) do
          render_vertical_scroll_container(widget, page_name, language, fixed:)
        end
        content = render_scroll_region(widget['Left'], 'left', page_name, language) + center +
                  render_scroll_region(widget['Right'], 'right', page_name, language)
        render_client_container(
          widget, 'mxui.widget.HorizontalScrollContainer', props, content,
          base: scroll_container_classes('horizontal', fixed), widget_classes: false, tabindex: false
        )
      end

      def render_vertical_scroll_container(widget, page_name, language, fixed:)
        props = scroll_container_properties(widget, %w[Top CenterRegion Bottom], fixed:)
        content = render_scroll_region(widget['Top'], 'top', page_name, language) +
                  render_scroll_region(widget['CenterRegion'], 'middle', page_name, language) +
                  render_scroll_region(widget['Bottom'], 'bottom', page_name, language)
        render_client_container(
          widget, 'mxui.widget.VerticalScrollContainer', props, content,
          base: scroll_container_classes('vertical', fixed), widget_classes: false, tabindex: false
        )
      end

      def scroll_container_properties(widget, region_names, fixed:)
        config = region_names.filter_map do |name|
          region = widget[name]
          next unless region

          position = if name == 'CenterRegion'
                       region_names.include?('Left') ? 'center' : 'middle'
                     else
                       name.downcase
                     end
          scroll_region_config(region, position)
        end
        { 'fixed' => fixed, 'config' => config }
      end

      def scroll_region_config(region, position)
        config = { 'position' => position }
        toggle = region['ToggleMode'].to_s
        return config if toggle.empty? || toggle == 'None'

        config['toggleMode'] = legacy_toggle_mode(toggle)
        config['initiallyOpen'] = toggle.include?('InitiallyOpen') ||
                                  (!toggle.include?('InitiallyClosed') && toggle.start_with?('ShrinkContent'))
        config
      end

      def legacy_toggle_mode(value)
        return 'shrinkContent' if value.start_with?('ShrinkContent')
        return 'pushContentAside' if value.start_with?('PushContent')
        return 'slideOverContent' if value.start_with?('SlideOverContent')

        value.sub(/Initially(?:Open|Closed)\z/, '').then { _1[0].to_s.downcase + _1[1..].to_s }
      end

      def render_scroll_region(region, position, page_name, language, nested: false)
        return '' unless region

        content = if block_given?
                    yield
                  else
                    array(region['Widgets']).map do |child|
                      render_widget(child, page_name, language)
                    end.join
                  end
        base = "mx-layoutcontainer-#{position} mx-scrollcontainer-#{position}"
        region_classes = css_classes(region, base:)
        wrapper = 'mx-layoutcontainer-wrapper mx-scrollcontainer-wrapper'
        wrapper += ' mx-layoutcontainer-nested mx-scrollcontainer-nested' if nested
        style = scroll_region_style(region, position)
        style_attribute = style.empty? ? '' : " style='#{escape(style)}'"
        "<div class='#{escape(region_classes)}'#{style_attribute}>" \
          "<div class='#{wrapper}'>#{content}</div></div>"
      end

      def scroll_region_style(region, position)
        styles = [region['Style'].to_s, region.dig('Appearance', 'Style').to_s].reject(&:empty?)
        if region['SizeMode'] == 'Pixels' && region['Size'].to_i.positive?
          dimension = %w[left right].include?(position) ? 'width' : 'height'
          styles << "#{dimension}:#{region['Size'].to_i}px"
        end
        styles.join(';')
      end

      def scroll_container_classes(orientation, fixed)
        classes = "mx-layoutcontainer mx-scrollcontainer mx-layoutcontainer-#{orientation} " \
                  "mx-scrollcontainer-#{orientation}"
        classes += ' mx-layoutcontainer-fixed mx-scrollcontainer-fixed' if fixed
        classes
      end

      def render_header(widget, page_name, language)
        left = array(widget['LeftWidgets']).map { render_widget(_1, page_name, language) }.join
        right = array(widget['RightWidgets']).map { render_widget(_1, page_name, language) }.join
        title = render_client_widget(
          {}, 'mxui.widget.Title', {}, base: nil, widget_classes: false, tabindex: false,
                                       properties: false
        )
        "<div#{html_attributes(widget, base: 'mx-header')}>" \
          "<div class='mx-header-center'>#{title}</div>" \
          "<div class='mx-header-left'>#{left}</div>" \
          "<div class='mx-header-right'>#{right}</div></div>"
      end

      def render_sidebar_toggle(widget, language)
        props = button_properties(widget, language)
        props['iconClass'] = 'glyphicon-menu-hamburger' if widget['Icon']&.dig('$Type') == 'Forms$GlyphIcon'
        render_type = props['renderType']
        base = render_type == 'button' ? button_style(widget) : nil
        render_client_widget(widget, 'mxui.widget.SidebarToggleButton', props, base:)
      end

      def render_navigation(widget)
        type = case widget['$Type']
               when 'Forms$NavigationTree' then 'mxui.widget.NavigationTree'
               when 'Forms$MenuBar' then 'mxui.widget.Navbar'
               else 'mxui.widget.MenuBar'
               end
        props = { 'menuID' => menu_identifier(widget['MenuSource']) }
        props['orientation'] = widget['Orientation'].to_s.downcase if widget['$Type'] == 'Forms$SimpleMenuBar'
        render_client_widget(widget, type, props, base: nil, tabindex: false)
      end

      def menu_identifier(source)
        case source&.fetch('$Type', nil)
        when 'Forms$NavigationSource'
          documents = @source.units_of('Navigation$NavigationDocument').map(&:document)
          profile = documents.flat_map { array(_1['Profiles']) }
                             .find { _1['Name'] == source['NavigationProfile'] }
          device_key = "#{source['DeviceType']}Profile"
          profile ||= documents.filter_map { _1[device_key] }.first
          IO::BsonCodec.extract_id(profile&.dig('Menu', '$ID'))
        when 'Forms$MenuDocumentSource'
          qualified = source['Menu'].to_s
          menu = @source.units_of('Menus$MenuDocument').find do |unit|
            "#{unit.module_name}.#{unit.document['Name']}" == qualified
          end
          IO::BsonCodec.extract_id(menu&.document&.dig('ItemCollection', '$ID')) || menu&.id
        end
      end

      def render_action_button(widget, language)
        action = widget['Action'] || {}
        props = button_properties(widget, language)
        case action['$Type']
        when 'Forms$SaveChangesClientAction'
          props.merge!('closeForm' => action.fetch('ClosePage', true), 'needsObject' => true)
          render_client_widget(widget, 'mxui.widget.SaveButton', props)
        when 'Forms$CancelChangesClientAction'
          props.merge!('closeForm' => action.fetch('ClosePage', true), 'needsObject' => true)
          render_client_widget(widget, 'mxui.widget.CancelButton', props)
        when 'Forms$ClosePageClientAction'
          render_client_widget(widget, 'mxui.widget.BackButton', props)
        when 'Forms$OpenLinkClientAction'
          render_link_button(widget, action, props)
        else
          props['action'] = legacy_client_action(action)
          render_client_widget(widget, 'mxui.widget.ActionButton', props)
        end
      end

      def render_mobile_button(widget, language, type)
        props = button_properties(widget, language)
        unless type == 'mxui.widget.BackButton'
          props.merge!('closeForm' => widget.fetch('ClosePage', true), 'needsObject' => true)
        end
        render_client_widget(widget, type, props)
      end

      def render_data_view(widget, page_name, language)
        id = next_widget_id
        template_index = @templates.length
        @templates << nil
        @data_view_stack ||= []
        @data_view_stack << {
          entity: data_view_entity(widget['DataSource'] || {}),
          label_width: positive_integer(widget['LabelWidth'], 3),
          editable: widget['Editable'] != false
        }
        content = data_view_children(widget, 'Widgets', 'Widget')
                  .map { render_widget(_1, page_name, language) }.join
        footer = data_view_children(widget, 'FooterWidgets', 'FooterWidget')
                 .map { render_widget(_1, page_name, language) }.join
        @data_view_stack.pop
        @templates[template_index] = data_view_templates(id, content, footer)
        render_client_widget(
          widget, 'mxui.widget.DataView', data_view_properties(widget), id:, base: 'form-horizontal'
        )
      end

      def render_list_view(widget, page_name, language)
        id = next_widget_id
        @widget_ids_by_name ||= {}
        @widget_ids_by_name[widget['Name'].to_s] = id unless widget['Name'].to_s.empty?
        entity = list_view_entity(widget)
        template_index = @templates.length
        @templates << nil
        @data_view_stack ||= []
        @data_view_stack << { entity:, label_width: 0, editable: widget['Editable'] != false }
        content = widget_children(widget).map do |child|
          render_widget(child, page_name, language)
        end.join
        @data_view_stack.pop
        @templates[template_index] = "<m:template widget-id='#{escape(id)}' name='content'>" \
                                     "#{content}</m:template>"
        props = {
          'datasource' => list_view_source(widget, page_name, entity),
          'page' => positive_integer(widget['PageSize'], 20),
          'hasSearch' => !list_view_search_paths(widget['DataSource'] || {}).empty?,
          'action' => legacy_client_action(widget['ClickAction'] || { '$Type' => 'Forms$NoAction' }),
          'selectable' => list_view_listened_to?(widget['Name'], page_name) ? 'single' : '',
          'templateMap' => { entity => 'content' },
          'readOnly' => widget['Editable'] == false
        }
        render_client_widget(widget, 'mxui.widget.ListView', props, id:, base: nil)
      end

      def list_view_source(widget, page_name, entity)
        source = widget['DataSource'] || {}
        type = source['$Type'] == 'Forms$NewListViewDatabaseSource' ? 'database' : 'xpath'
        props = {
          'friendlyId' => "#{page_name}.#{widget['Name']}", 'type' => type, 'path' => entity
        }
        props['offlineConstraints'] = [] if type == 'database'
        constraint = source['XPathConstraint'].to_s
        props['xpathConstraints'] = constraint unless constraint.empty?
        sort = array(source.dig('SortBar', 'SortItems')).map do |item|
          [relative_list_attribute(item['AttributePath'], entity),
           item['SortOrder'].to_s == 'Descending' ? 'desc' : 'asc']
        end
        props['sort'] = sort unless sort.empty?
        search = list_view_search_paths(source).map do |path|
          relative_list_attribute(path['AttributePath'] || path['Attribute'] || path, entity)
        end.reject(&:empty?)
        props['search'] = search unless search.empty?
        props
      end

      def relative_list_attribute(path, entity)
        path.to_s.delete_prefix("#{entity}.")
      end

      def list_view_entity(widget)
        source = widget['DataSource'] || {}
        entity = source['EntityPath'].to_s
        entity = source.dig('EntityRef', 'Entity').to_s if entity.empty?
        entity
      end

      def list_view_search_paths(source)
        paths = array(source.dig('Search', 'SearchPaths'))
        paths.empty? ? array(source.dig('Search', 'SearchRefs')) : paths
      end

      def list_view_listened_to?(name, page_name)
        legacy_related_documents(page_name).any? do |document|
          descendants(document).any? do |value|
            value['$Type'] == 'Forms$ListenTargetSource' && value['ListenTarget'] == name
          end
        end
      end

      def legacy_related_documents(page_name, seen = {})
        unit = (@source.units_of('Forms$Page') + @source.units_of('Forms$Layout')).find do |candidate|
          "#{candidate.module_name}.#{candidate.document['Name']}" == page_name
        end
        return [] unless unit

        documents = [unit.document]
        descendants(unit.document).select { _1['$Type'] == 'Forms$SnippetCallWidget' }.each do |call|
          qualified = call.dig('FormCall', 'Form').to_s
          next if seen[qualified]

          seen[qualified] = true
          snippet = snippet_unit(qualified)
          documents.concat(legacy_related_snippet_documents(snippet, seen)) if snippet
        end
        documents
      end

      def legacy_related_snippet_documents(snippet, seen)
        documents = [snippet.document]
        descendants(snippet.document).select { _1['$Type'] == 'Forms$SnippetCallWidget' }.each do |call|
          qualified = call.dig('FormCall', 'Form').to_s
          next if seen[qualified]

          seen[qualified] = true
          child = snippet_unit(qualified)
          documents.concat(legacy_related_snippet_documents(child, seen)) if child
        end
        documents
      end

      def data_view_templates(id, content, footer)
        templates = +"<m:template widget-id='#{escape(id)}' name='content'>#{content}</m:template>"
        templates << "<m:template widget-id='#{escape(id)}' name='footer'>#{footer}</m:template>" unless footer.empty?
        templates
      end

      def data_view_properties(widget)
        source = widget['DataSource'] || {}
        entity = data_view_entity(source)
        props = {
          'entity' => entity,
          'schema' => IO::BsonCodec.extract_id(widget['$ID']).to_s,
          'datasource' => data_view_source(source, entity)
        }
        props['readOnly'] = true if widget['Editable'] == false
        props['hideFooter'] = true if widget['ShowFooter'] == false
        props
      end

      def data_view_source(source, entity)
        if source['$Type'] == 'Forms$ListenTargetSource'
          target = source['ListenTarget'].to_s
          return { 'type' => 'listen', 'contextsource' => @widget_ids_by_name&.fetch(target, target) }
        end

        if source['$Type'] == 'Forms$MicroflowSource'
          return {
            'type' => 'microflow',
            'microflow' => source.dig('MicroflowSettings', 'Microflow').to_s,
            'argMap' => {}
          }
        end

        path = data_view_path(source)
        { 'type' => 'direct', 'path' => path.empty? ? entity : path }
      end

      def data_view_entity(source)
        if source['$Type'] == 'Forms$ListenTargetSource'
          target = source['ListenTarget'].to_s
          list = @source.documents.flat_map { descendants(_1) }.find do |value|
            value['$Type'] == 'Forms$ListView' && value['Name'] == target
          end
          return list_view_entity(list || {})
        end

        path = source['EntityPath'].to_s
        return path.split('/').last unless path.empty?

        reference = source['EntityRef'] || {}
        steps = array(reference['Steps'])
        destination = steps.last&.fetch('DestinationEntity', '').to_s
        return destination unless destination.empty?

        direct = reference['Entity'].to_s
        return direct unless direct.empty?

        microflow_return_entity(source)
      end

      def data_view_path(source)
        legacy = source['EntityPath'].to_s
        return legacy unless legacy.empty?

        reference = source['EntityRef'] || {}
        steps = array(reference['Steps'])
        return reference['Entity'].to_s if steps.empty?

        steps.flat_map { [_1['Association'], _1['DestinationEntity']] }
             .map(&:to_s).reject(&:empty?).join('/')
      end

      def microflow_return_entity(source)
        name = source.dig('MicroflowSettings', 'Microflow').to_s
        unit = @source.units_of('Microflows$Microflow').find do |candidate|
          "#{candidate.module_name}.#{candidate.document['Name']}" == name
        end
        unit&.document&.dig('MicroflowReturnType', 'Entity').to_s
      end

      def data_view_children(widget, plural, singular)
        children = array(widget[plural])
        return children unless children.empty?

        widget_children(widget[singular])
      end

      def templates_xml
        templates = Array(@templates).compact.join
        templates.empty? ? '' : "<m:templates>#{templates}</m:templates>"
      end

      def render_bound_input(widget, language)
        context = Array(@data_view_stack).last
        return '' unless context

        outer_id = next_widget_id
        type, props = bound_input_contract(widget, language, context)
        input = render_client_widget(
          widget, type, props, base: "col-sm-#{12 - context[:label_width]}", widget_classes: false
        )
        label = translated_input_text(widget, 'LabelTemplate', 'LabelText', language)
        attributes = html_attributes(widget, base: 'form-group', mendix_id: outer_id)
        "<div#{attributes}>" \
          "<label class='control-label col-sm-#{context[:label_width]}'>#{escape(label)}</label>" \
          "#{input}</div>"
      end

      def bound_input_contract(widget, language, context)
        attribute = attribute_reference(widget)
        props = {
          'insideFormGroup' => true,
          'attributePath' => bound_attribute_path(widget, context),
          'readOnlyStyle' => read_only_style(widget)
        }
        props['readOnly'] = true if widget['Editable'] == 'Never' || !context[:editable]
        props.merge!(required_properties(widget, language))
        case widget['$Type']
        when 'Forms$TextBox' then text_box_contract(widget, attribute, language, props)
        when 'Forms$TextArea' then text_area_contract(widget, language, props)
        when 'Forms$CheckBox' then ['mxui.widget.BoolSelect', props]
        when 'Forms$DatePicker' then date_picker_contract(widget, language, props)
        when 'Forms$DropDown' then ['mxui.widget.EnumSelect', props]
        when 'Forms$RadioButtonGroup' then radio_button_contract(widget, attribute, language, props)
        when 'Forms$ReferenceSelector' then reference_selector_contract(widget, props)
        when 'Forms$InputReferenceSetSelector' then reference_set_selector_contract(widget, props)
        end
      end

      def bound_attribute_path(widget, context)
        return reference_attribute_path(widget, context) if %w[
          Forms$ReferenceSelector Forms$InputReferenceSetSelector
        ].include?(widget['$Type'])

        "#{context[:entity]}/#{attribute_reference(widget).split('.').last}"
      end

      def text_box_contract(widget, attribute, language, props)
        props['placeholder'] = translated_input_text(widget, 'PlaceholderTemplate', 'Placeholder', language)
        type = attribute_definition(attribute)&.dig('NewType') ||
               attribute_definition(attribute)&.dig('Type') || {}
        input_type = if widget['IsPasswordBox'] == true
                       'mxui.widget.PasswordInput'
                     elsif numeric_attribute_type?(type)
                       'mxui.widget.NumberInput'
                     else
                       'mxui.widget.TextInput'
                     end
        max_length = positive_integer(widget['MaxLengthCode'], type['Length'].to_i)
        props['maxLength'] = max_length if input_type != 'mxui.widget.NumberInput' && max_length.positive?
        props['mask'] = widget['InputMask'].to_s unless widget['InputMask'].to_s.empty?
        [input_type, props]
      end

      def text_area_contract(widget, language, props)
        props['placeholder'] = translated_input_text(widget, 'PlaceholderTemplate', 'Placeholder', language)
        props['rows'] = positive_integer(widget['NumberOfLines'], 5)
        max_length = positive_integer(widget['MaxLengthCode'], 0)
        props['maxLength'] = max_length if max_length.positive?
        ['mxui.widget.TextArea', props]
      end

      def date_picker_contract(widget, language, props)
        props['placeholder'] = translated_input_text(widget, 'PlaceholderTemplate', 'Placeholder', language)
        format = widget.dig('FormattingInfo', 'DateFormat').to_s.downcase
        props['selector'] = %w[date time].include?(format) ? format : 'datetime'
        custom = widget.dig('FormattingInfo', 'CustomDateFormat').to_s
        props['format'] = custom unless custom.empty?
        ['mxui.widget.DateInput', props]
      end

      def radio_button_contract(widget, attribute, language, props)
        props['horizontal'] = widget.fetch('Orientation', 'Horizontal') != 'Vertical'
        props['options'] = enumeration_options(attribute, language)
        ['mxui.widget.RadioButtonGroup', props]
      end

      def reference_selector_contract(widget, props)
        props['datasource'] = selector_source(widget)
        settings = widget['GotoFormSettings'] || {}
        props['gotoPageSettings'] = page_settings(settings) unless settings['Form'].to_s.empty?
        ['mxui.widget.ReferenceSelector', props]
      end

      def reference_set_selector_contract(widget, props)
        props['datasource'] = selector_source(widget)
        settings = widget['PopupFormSettings'] || {}
        props['selectPageSettings'] = page_settings(settings) unless settings['Form'].to_s.empty?
        ['mxui.widget.InputReferenceSetSelector', props]
      end

      def selector_source(widget)
        source = widget['SelectorSource'] || {}
        target, caption = selector_target(widget)
        if source['$Type'] == 'Forms$SelectorMicroflowSource'
          return {
            'type' => 'microflow',
            'microflow' => source.dig('DataSourceMicroflowSettings', 'Microflow').to_s,
            'path' => target
          }
        end

        result = {
          'type' => 'xpath', 'path' => target, 'constrainedBy' => [],
          'sort' => [[caption, 'asc']], 'contextAction' => 'keep'
        }
        constraint = source['XPathConstraint'].to_s
        result['constraint'] = constraint unless constraint.empty?
        result
      end

      def selector_target(widget)
        attribute = attribute_reference(widget).split('/').last.to_s
        parts = attribute.split('.')
        [parts.first(2).join('.'), parts.last.to_s]
      end

      def reference_attribute_path(widget, context)
        legacy = widget['AttributePath'].to_s
        unless legacy.empty?
          segments = legacy.split('/')
          segments[-1] = segments.last.to_s.split('.').last
          return ([context[:entity]] + segments).join('/')
        end

        reference = widget.dig('AttributeRef', 'EntityRef') || {}
        steps = array(reference['Steps']).flat_map do |step|
          [step['Association'], step['DestinationEntity']]
        end
        ([context[:entity]] + steps + [attribute_reference(widget).split('.').last])
          .map(&:to_s).reject(&:empty?).join('/')
      end

      def required_properties(widget, language)
        return {} unless widget['Required'] == true

        {
          'required' => 'true',
          'requiredMsg' => translated_input_text(widget, 'RequiredMessageTemplate', 'RequiredMessage', language)
        }
      end

      def read_only_style(widget)
        style = widget['ReadOnlyStyle'].to_s.downcase
        %w[control text].include?(style) ? style : 'text'
      end

      def translated_input_text(widget, template_key, text_key, language)
        template = widget.dig(template_key, 'Template')
        translated(template || widget[text_key], language)
      end

      def render_label(widget, language)
        tag = widget['RenderMode'].to_s == 'Paragraph' ? 'p' : 'label'
        attributes = html_attributes(widget, base: nil, mendix_id: next_widget_id)
        "<#{tag}#{attributes}>#{escape(translated(widget['Caption'], language))}</#{tag}>"
      end

      def render_static_image(widget)
        props = { 'url' => image_uri(widget['Image']) }
        action = widget['ClickAction'] || {}
        props['action'] = legacy_client_action(action) unless action['$Type'] == 'Forms$NoAction'
        base = widget['Responsive'] == true ? 'img-responsive' : nil
        render_client_widget(
          widget, 'mxui.widget.StaticImage', props, base:, style: static_image_style(widget)
        )
      end

      def render_image_viewer(widget)
        source = widget['DataSource'] || {}
        props = {
          'datasource' => { 'type' => 'direct', 'path' => source['EntityPath'].to_s },
          'defaultUrl' => widget['DefaultImage'].to_s.empty? ? '' : image_uri(widget['DefaultImage']),
          'thumb' => widget['ShowAsThumbnail'] == true,
          'width' => image_dimension(widget['Width'], widget['WidthUnit']),
          'height' => image_dimension(widget['Height'], widget['HeightUnit'])
        }
        base = widget['Responsive'] == true ? 'img-responsive' : nil
        render_client_widget(widget, 'mxui.widget.Image', props, base:)
      end

      def render_image_uploader(widget)
        width, height = widget['ThumbnailSize'].to_s.split(';').map(&:to_i)
        props = {
          'thumbnailWidth' => width.positive? ? width : 100,
          'thumbnailHeight' => height.positive? ? height : 75,
          'maxFileSize' => widget['MaxFileSize'].to_i,
          'restrictions' => widget['AllowedExtensions'].to_s,
          'uploadable' => widget['Editable'] != 'Never'
        }
        render_client_widget(widget, 'mxui.widget.ImageUploader', props, base: nil)
      end

      def render_reference_set_selector(widget, page_name, language)
        compiler = LegacyDataGridCompiler.new(
          @source, page_name, widget, language:, sequence: next_widget_sequence
        )
        compiler.html.tap { @unsupported[page_name].concat(compiler.unsupported) }
      end

      def image_dimension(value, unit)
        number = value.to_i
        return '' unless number.positive?

        case unit
        when 'Pixels' then "#{number}px"
        when 'Percentage' then "#{number}%"
        else ''
        end
      end

      def static_image_style(widget)
        dimensions = [%w[Width WidthUnit width], %w[Height HeightUnit height]].filter_map do |value, unit, name|
          amount = widget[value].to_i
          suffix = { 'Pixels' => 'px', 'Percentage' => '%' }[widget[unit].to_s]
          "#{name}:#{amount}#{suffix}" if amount.positive? && suffix
        end
        [widget['Style'].to_s, *dimensions].reject(&:empty?).join(';')
      end

      def render_tab_control(widget, page_name, language)
        id = next_widget_id
        tabs = array(widget['TabPages'])
        selected = default_tab_index(widget, tabs)
        pages = tabs.each_with_index.map do |tab, index|
          tab_id = next_widget_id
          props = {
            'title' => translated(tab['Caption'], language), 'delayLoading' => index != selected,
            'tabName' => tab['Name'].to_s
          }
          [tab, tab_id, render_client_widget(
            tab, 'mxui.widget.TabContent', props, id: tab_id, base: nil,
                                                  widget_classes: false, tabindex: false
          )]
        end
        @templates << "<m:template widget-id='#{escape(id)}' name='pages'>" \
                      "#{pages.map(&:last).join}</m:template>"
        pages.each do |tab, tab_id, _html|
          content_index = @templates.length
          @templates << nil
          content = array(tab['Widgets']).map { render_widget(_1, page_name, language) }.join
          @templates[content_index] = "<m:template widget-id='#{escape(tab_id)}' " \
                                      "name='content'>#{content}</m:template>"
        end
        render_client_widget(widget, 'mxui.widget.TabContainer', {}, id:, base: nil)
      end

      def default_tab_index(widget, tabs)
        pointer = IO::BsonCodec.extract_id(widget['DefaultPagePointer'])
        tabs.index { IO::BsonCodec.extract_id(_1['$ID']) == pointer } || 0
      end

      def render_snippet_call(widget, page_name, language)
        qualified = widget.dig('FormCall', 'Form').to_s
        snippet = snippet_unit(qualified)
        @snippet_stack ||= []
        return '' unless snippet && !@snippet_stack.include?(qualified)

        @snippet_stack << qualified
        widget_children(snippet.document).map { render_widget(_1, page_name, language) }.join
      ensure
        @snippet_stack.pop if @snippet_stack&.last == qualified
      end

      def audit_snippet_call(widget, page_name, data_view_context)
        qualified = widget.dig('FormCall', 'Form').to_s
        snippet = snippet_unit(qualified)
        @snippet_audit_stack ||= []
        if !snippet || @snippet_audit_stack.include?(qualified)
          @unsupported[page_name] << 'Forms$SnippetCallWidget'
          return
        end

        @snippet_audit_stack << qualified
        audit_unsupported_widgets(
          snippet.document, page_name, initial_data_view_context: data_view_context
        )
      ensure
        @snippet_audit_stack.pop if @snippet_audit_stack&.last == qualified
      end

      def snippet_unit(qualified)
        @source.units_of('Forms$Snippet').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified
        end
      end

      def render_custom_widget(widget, language)
        compiler = LegacyCustomWidgetCompiler.new(@source, widget, language:)
        return '' unless compiler.supported?

        render_client_widget(widget, compiler.widget_id, compiler.properties_hash, base: nil)
      end

      def button_properties(widget, language)
        caption = translated(widget.dig('CaptionTemplate', 'Template'), language)
        render_type = widget['RenderType'].to_s.downcase
        props = {
          'caption' => { 'text' => caption },
          'renderType' => render_type.empty? ? 'button' : render_type
        }
        icon = image_uri(widget.dig('Icon', 'Image'))
        props['iconUrl'] = icon if icon
        props
      end

      def render_link_button(widget, action, props)
        address = action['Address'] || {}
        props['action'] = {
          'Web' => 'open', 'Email' => 'email', 'Call' => 'call', 'Text' => 'text'
        }.fetch(action['LinkType'].to_s, action['LinkType'].to_s.downcase)
        props['address'] = address['Value'].to_s
        render_client_widget(widget, 'mxui.widget.LinkButton', props)
      end

      def render_client_widget(widget, type, props, **options)
        attributes = client_widget_attributes(widget, type, props, **options)
        serialized = attributes.map { |key, value| "#{key}='#{escape(value)}'" }.join(' ')
        "<div #{serialized}></div>"
      end

      def render_client_container(widget, type, props, content, **options)
        attributes = client_widget_attributes(widget, type, props, **options)
        serialized = attributes.map { |key, value| "#{key}='#{escape(value)}'" }.join(' ')
        "<div #{serialized}>#{content}</div>"
      end

      def client_widget_attributes(widget, type, props, **options)
        id = options.key?(:id) ? options[:id] : next_widget_id
        @widget_ids_by_name ||= {}
        @widget_ids_by_name[widget['Name'].to_s] = id unless widget['Name'].to_s.empty?
        base = options.key?(:base) ? options[:base] : button_style(widget)
        widget_classes = options.fetch(:widget_classes, true)
        style = options.fetch(:style, widget['Style'].to_s)
        style = widget.dig('Appearance', 'Style').to_s if style.empty?
        tabindex = options.fetch(:tabindex, true)
        properties = options.fetch(:properties, true)
        {
          'data-mendix-id' => id,
          'data-mendix-type' => type,
          'data-mendix-props' => properties ? JSON.generate(props)[1..-2] : '',
          'class' => widget_classes ? css_classes(widget, base:) : base,
          'style' => style,
          'tabindex' => tabindex ? widget['TabIndex'].to_i : ''
        }.reject { |_key, value| value.to_s.empty? }
      end

      def legacy_client_action(action)
        case action['$Type']
        when 'Forms$MicroflowAction'
          microflow_action(action)
        when 'Forms$FormAction'
          settings = action['FormSettings'] || {}
          {
            'type' => 'openPage',
            'hasParameter' => !array(settings['ParameterMappings']).empty?,
            'params' => page_settings(settings)
          }
        when 'Forms$NoAction'
          { 'type' => 'doNothing', 'hasParameter' => false, 'params' => {} }
        end
      end

      def microflow_action(action)
        settings = action['MicroflowSettings'] || action
        name = settings['Microflow'].to_s
        has_parameter = microflow_has_parameter?(name)
        params = { 'name' => name }
        params['validate'] = 'view' unless settings['FormValidations'] == 'None'
        params['applyTo'] = 'selection' if has_parameter
        { 'type' => 'callMicroflow', 'hasParameter' => has_parameter, 'params' => params }
      end

      def microflow_has_parameter?(qualified_name)
        unit = @source.units_of('Microflows$Microflow').find do |candidate|
          "#{candidate.module_name}.#{candidate.document['Name']}" == qualified_name
        end
        descendants(unit&.document || {}).any? { _1['$Type'] == 'Microflows$MicroflowParameter' }
      end

      def page_settings(settings)
        form = settings['Form'].to_s
        location = settings['Location'].to_s
        result = {
          'path' => "#{form.tr('.', '/')}.page.xml",
          'location' => %w[Popup ModalPopup].include?(location) ? 'modal' : 'content'
        }
        target = @source.units_of('Forms$Page').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == form
        end
        result['resizable'] = true if target&.document&.fetch('PopupResizable', false) == true
        result
      end

      def image_uri(reference)
        module_name, collection_name, image_name = reference.to_s.split('.', 3)
        unit = @source.units_of('Images$ImageCollection').find do |candidate|
          candidate.module_name == module_name && candidate.document['Name'] == collection_name
        end
        image = array(unit&.document&.fetch('Images', nil)).find { _1['Name'] == image_name }
        unless image
          return system_image_uri(collection_name, image_name) if module_name == 'System'

          return
        end

        "img/#{module_name}$#{image_name}.#{image_format(image)}"
      end

      def system_image_uri(collection_name, image_name)
        return if collection_name != 'Images' || image_name.to_s.empty?

        extension = %w[Error Running Completed Module].include?(image_name) ? 'gif' : 'png'
        "img/System$#{image_name}.#{extension}"
      end

      def button_style(widget)
        style = widget['ButtonStyle'].to_s.downcase
        "btn-#{style.empty? ? 'default' : style}"
      end

      def render_dynamic_text(widget, language)
        content = widget['Content'] || {}
        text = translated(content['Template'], language)
        text = translated(content['Fallback'], language) if text.empty?
        parameters = array(content['Parameters'])
        unless parameters.empty?
          return render_client_widget(
            widget, 'mxui.widget.DynamicText',
            { 'content' => dynamic_text_template(text, parameters) }, base: 'mx-text'
          )
        end

        tag = widget['RenderMode'].to_s == 'Paragraph' ? 'p' : 'span'
        attributes = html_attributes(widget, base: 'mx-text', mendix_id: next_widget_id)
        "<#{tag}#{attributes}>#{escape(text)}</#{tag}>"
      end

      def dynamic_text_template(text, parameters)
        values = parameters.each_with_index.to_h do |parameter, index|
          [index.to_s, dynamic_text_attribute_path(parameter)]
        end
        formats = parameters.each_with_index.to_h do |parameter, index|
          [index.to_s, dynamic_text_format(parameter)]
        end
        elements = text.split(/(\{\d+\})/).filter_map do |part|
          next if part.empty?

          match = part.match(/\A\{(\d+)\}\z/)
          match ? match[1].to_i - 1 : part
        end
        { 'elements' => elements, 'parameters' => values, 'formats' => formats }
      end

      def dynamic_text_attribute_path(parameter)
        reference = parameter['AttributeRef'] || {}
        attribute = attribute_reference(parameter)
        steps = array(reference.dig('EntityRef', 'Steps')).flat_map do |step|
          [step['Association'], step['DestinationEntity']]
        end
        return (steps + [attribute.split('.').last]).reject(&:empty?).join('/') unless steps.empty?

        entity = Array(@data_view_stack).last&.fetch(:entity, '').to_s
        relative_list_attribute(attribute, entity)
      end

      def dynamic_text_format(parameter)
        formatting = parameter['FormattingInfo'] || {}
        type = attribute_definition(attribute_reference(parameter))&.dig('NewType', '$Type') ||
               attribute_definition(attribute_reference(parameter))&.dig('Type', '$Type')
        date = formatting['DateFormat'].to_s.downcase
        custom = formatting['CustomDateFormat'].to_s
        if type == 'DomainModels$DateTimeAttributeType'
          return { 'type' => 'custom', 'pattern' => custom } unless custom.empty?
          return { 'type' => date } if %w[date time datetime].include?(date)
        end

        return {} unless numeric_attribute_type?('$Type' => type)

        {
          'groupDigits' => formatting['GroupDigits'] == true,
          'decimalPrecision' => positive_integer(formatting['DecimalPrecision'], 2)
        }
      end

      def render_data_grid(widget, page_name, language)
        compiler = LegacyDataGridCompiler.new(
          @source, page_name, widget, language:, sequence: next_widget_sequence
        )
        compiler.html.tap { @unsupported[page_name].concat(compiler.unsupported) }
      end

      def html_attributes(widget, base:, mendix_id: nil)
        values = {}
        css = css_classes(widget, base:)
        values['class'] = css unless css.empty?
        style = widget['Style'].to_s
        style = widget.dig('Appearance', 'Style').to_s if style.empty?
        values['style'] = style unless style.empty?
        values['data-mendix-id'] = mendix_id if mendix_id
        values.map { |key, value| " #{key}='#{escape(value)}'" }.join
      end

      def css_classes(widget, base:)
        name = widget['Name'].to_s
        classes = [base, ("mx-name-#{name}" unless name.empty?), widget['Class'],
                   widget.dig('Appearance', 'Class')]
        classes.compact.flat_map { _1.to_s.split }.reject(&:empty?).uniq.join(' ')
      end

      def page_css_classes(page)
        layout = layout_unit(page.dig('FormCall', 'Form').to_s)&.document || {}
        [layout['Class'], layout.dig('Appearance', 'Class'), page['Class'],
         page.dig('Appearance', 'Class')].compact.flat_map { _1.to_s.split }
                                         .reject(&:empty?).uniq.join(' ')
      end

      def page_widgets(document)
        argument = array(document.dig('FormCall', 'Arguments')).first
        widget_children(argument || document)
      end

      def layout_widgets(document) = widget_children(document)

      def widget_children(value)
        return [] unless value.is_a?(Hash)

        plural = array(value['Widgets'])
        singular = value['Widget']
        plural.empty? && singular.is_a?(Hash) ? [singular] : plural
      end

      def supported_widget_type?(type)
        %w[
          Forms$ActionButton Forms$CheckBox Forms$DataGrid Forms$DataView Forms$DatePicker
          Forms$DivContainer Forms$DropDown Forms$DynamicText Forms$InputReferenceSetSelector
          Forms$Header Forms$ImageUploader Forms$ImageViewer Forms$Label Forms$LayoutGrid Forms$ListView
          Forms$MenuBar Forms$NavigationTree
          Forms$MobileBackButton Forms$MobileCancelButton Forms$MobileSaveButton
          Forms$RadioButtonGroup Forms$ReferenceSelector Forms$ReferenceSetSelector
          Forms$SnippetCallWidget
          Forms$ScrollContainer Forms$SidebarToggleButton Forms$SimpleMenuBar
          Forms$StaticImageViewer Forms$Table Forms$TabControl Forms$TemplateGrid
          Forms$TextArea Forms$TextBox
          CustomWidgets$CustomWidget
        ].include?(type)
      end

      def supported_action_button?(widget)
        action = widget['Action'] || {}
        return false unless ACTION_BUTTON_TYPES.include?(action['$Type'])
        return false if action['$Type'] == 'Forms$OpenLinkClientAction' && action.dig('Address', 'IsDynamic') == true

        true
      end

      def supported_data_view?(widget)
        source = widget['DataSource'] || {}
        return !data_view_entity(source).empty? if source['$Type'] == 'Forms$ListenTargetSource'
        return !data_view_entity(source).empty? if source['$Type'] == 'Forms$MicroflowSource'
        return false unless source['$Type'] == 'Forms$DataViewSource'

        !data_view_entity(source).empty?
      end

      def supported_list_view?(widget)
        %w[Forms$ListViewXPathSource Forms$NewListViewDatabaseSource].include?(
          widget.dig('DataSource', '$Type')
        ) &&
          !list_view_entity(widget).empty?
      end

      def supported_dynamic_text?(widget, data_view_context)
        parameters = array(widget.dig('Content', 'Parameters'))
        return true if parameters.empty?
        return false unless data_view_context

        parameters.all? do |parameter|
          !attribute_reference(parameter).empty? && parameter['Expression'].to_s.empty?
        end
      end

      def supported_static_image?(widget)
        return false unless image_uri(widget['Image'])

        %w[Forms$MicroflowAction Forms$NoAction].include?(widget.dig('ClickAction', '$Type'))
      end

      def supported_image_viewer?(widget, data_view_context)
        return false unless data_view_context
        return false unless widget.dig('DataSource', '$Type') == 'Forms$ImageViewerSource'
        return false if widget.dig('DataSource', 'EntityPath').to_s.empty?
        return false unless widget['DefaultImage'].to_s.empty? || image_uri(widget['DefaultImage'])

        widget.dig('OnClickBehavior', '$Type').to_s == 'Forms$OnClickNothing'
      end

      def supported_reference_set_selector?(widget, data_view_context, page_name)
        path = widget.dig('DataSource', 'EntityPath').to_s
        return false unless data_view_context && widget.dig('DataSource', '$Type') == 'Forms$ReferenceSetSource'
        return false unless path.split('/').size == 2

        compiler = LegacyDataGridCompiler.new(
          @source, page_name, widget, language: 'en_US', sequence: 1
        )
        compiler.html
        compiler.unsupported.empty?
      end

      def supported_custom_widget?(widget)
        LegacyCustomWidgetCompiler.new(@source, widget, language: 'en_US').supported?
      end

      def supported_bound_widget?(widget, data_view_context)
        return false unless data_view_context && !attribute_reference(widget).empty?
        return true unless %w[
          Forms$ReferenceSelector Forms$InputReferenceSetSelector
        ].include?(widget['$Type'])

        source = widget['SelectorSource'] || {}
        return false unless %w[
          Forms$NewSelectorDatabaseSource Forms$SelectorDatabaseSource Forms$SelectorMicroflowSource
          Forms$SelectorXPathSource
        ].include?(source['$Type'])
        return false if selector_target(widget).first.empty?

        source['$Type'] != 'Forms$SelectorMicroflowSource' ||
          !source.dig('DataSourceMicroflowSettings', 'Microflow').to_s.empty?
      end

      def attribute_reference(widget)
        (widget['AttributePath'] || widget.dig('AttributeRef', 'Attribute')).to_s
      end

      def attribute_definition(reference)
        module_name, entity_name, attribute_name = reference.to_s.split('.', 3)
        return unless module_name && entity_name && attribute_name

        domain = domain_document(module_name)
        entity = array(domain&.fetch('Entities', nil)).find do |candidate|
          (candidate['Name'] || candidate['UnqualifiedName']) == entity_name
        end
        array(entity&.fetch('Attributes', nil)).find { _1['Name'] == attribute_name }
      end

      def domain_document(module_name)
        application = @source.units_of('DomainModels$DomainModel').find do |unit|
          unit.module_name == module_name
        end
        return application.document if application
        return unless module_name == 'System' && @source.respond_to?(:version)

        @system_domain_document ||= SystemModelSeed.for(@source.version).domain_document
      rescue CompilationError
        nil
      end

      def numeric_attribute_type?(type)
        %w[
          DomainModels$AutoNumberAttributeType DomainModels$DecimalAttributeType
          DomainModels$IntegerAttributeType DomainModels$LongAttributeType
        ].include?(type['$Type'])
      end

      def enumeration_options(attribute, language)
        type = attribute_definition(attribute)&.dig('NewType') ||
               attribute_definition(attribute)&.dig('Type') || {}
        qualified_name = type['Enumeration'].to_s
        module_name, name = qualified_name.split('.', 2)
        enumeration = @source.units_of('Enumerations$Enumeration').find do |unit|
          unit.module_name == module_name && unit.document['Name'] == name
        end
        array(enumeration&.document&.fetch('Values', nil)).map do |value|
          { 'key' => value['Name'].to_s, 'caption' => translated(value['Caption'], language) }
        end
      end

      def positive_integer(value, fallback)
        number = Integer(value || 0)
        number.positive? ? number : fallback
      rescue ArgumentError, TypeError
        fallback
      end

      def grid_weight_class(size, weight)
        value = Integer(weight || -1)
        "col-#{size}-#{value}" if (1..12).cover?(value)
      end

      def layout_argument_id(parameter)
        module_name, layout_name, placeholder_name = parameter.split('.', 3)
        return parameter unless placeholder_name

        layout = layout_unit("#{module_name}.#{layout_name}")
        placeholder = descendants(layout&.document || {}).find do |value|
          value['$Type'] == 'Forms$Placeholder' && value['Name'] == placeholder_name
        end
        IO::BsonCodec.extract_id(placeholder&.fetch('$ID', nil)) || parameter
      end

      def layout_unit(qualified_name)
        module_name, layout_name = qualified_name.split('.', 2)
        @source.units_of('Forms$Layout').find do |unit|
          unit.module_name == module_name && unit.document['Name'] == layout_name
        end
      end

      def next_widget_sequence
        @widget_sequence += 1
      end

      def next_widget_id = "1_#{next_widget_sequence - 1}"

      def descendants(root)
        result = []
        visit = lambda do |value|
          case value
          when Hash
            result << value if value['$Type']
            value.each_value { visit.call(_1) }
          when Array then value.each { visit.call(_1) }
          end
        end
        visit.call(root)
        result
      end

      def languages
        found = @source.documents.flat_map do |document|
          descendants(document).filter_map do |value|
            value['LanguageCode'].to_s if value['$Type'] == 'Texts$Translation'
          end
        end.reject(&:empty?).uniq.sort
        found.empty? ? ['en_US'] : found
      end

      def translated(text, language)
        items = array(text&.fetch('Items', nil))
        items.find { _1['LanguageCode'] == language }&.fetch('Text', '') ||
          items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') || ''
      end

      def write_manifest
        manifest = { 'profiles' => @profiles.map(&:to_s), 'unsupportedWidgets' => frozen_unsupported }
        File.write(File.join(@web_root, 'mxrb-legacy-pages.json'), JSON.pretty_generate(manifest))
      end

      def frozen_unsupported
        @unsupported.transform_values { _1.reject(&:empty?).uniq.sort }.reject { |_key, value| value.empty? }.freeze
      end

      def escape(value)
        value.to_s.gsub('&', '&amp;').gsub("'", '&#39;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
