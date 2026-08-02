# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
    # Compiles the built-in Data Grid 1 widget to the Dojo web-client contract.
    class LegacyDataGridCompiler
      include ModelValues

      SOURCE_TYPES = {
        'Forms$GridDatabaseSource' => 'database',
        'Forms$NewGridDatabaseSource' => 'database',
        'Forms$GridXPathSource' => 'xpath',
        'Forms$MicroflowSource' => 'microflow'
      }.freeze
      BUTTON_FUNCTIONS = {
        'Forms$GridSearchButton' => 'ToggleSearch',
        'Forms$DataGridSelectButton' => 'ReturnSelection',
        'Forms$GridNewButton' => 'InsertNew',
        'Forms$GridEditButton' => 'EditSelection',
        'Forms$GridDeleteButton' => 'DeleteSelection',
        'Forms$GridActionButton' => 'InvokeAction'
      }.freeze

      attr_reader :unsupported

      def initialize(source, page_name, widget, language:, sequence:)
        @source = source
        @page_name = page_name
        @widget = widget
        @language = language
        @sequence = sequence
        @unsupported = []
      end

      def html
        props = JSON.generate(properties)[1..-2]
        attributes = {
          'data-mendix-id' => widget_id, 'data-mendix-type' => 'mxui.widget.DataGrid',
          'data-mendix-props' => props, 'class' => css_class, 'tabindex' => @widget['TabIndex'].to_i
        }
        "<div #{attributes.map { |key, value| "#{key}='#{escape(value)}'" }.join(' ')}></div>"
      end

      private

      def properties
        {
          'friendlyId' => friendly_id, 'entity' => entity, 'schema' => entity_schema,
          'config' => {
            'locale' => @language, 'gridType' => 'Standalone',
            'gridpresentation' => presentation, 'datasource' => datasource,
            'searchOptions' => search_options, 'searchElements' => search_elements,
            'controlBar' => control_bar, 'defaultButton' => default_button,
            'griddata' => columns.map { compile_column(_1) }, 'plugins' => {}
          }
        }
      end

      def presentation
        {
          'rows' => @widget['NumberOfRows'].to_i, 'columns' => 1,
          'controlbar' => @widget['IsControlBarVisible'] == true,
          'pagingbar' => @widget['IsPagingEnabled'] == true,
          'sortparams' => sort_items, 'searchbar' => !search_elements.empty?,
          'waitforsearch' => data_source.dig('SearchBar', 'WaitForSearch') == true,
          'selectionmode' => @widget['SelectionMode'].to_s.downcase,
          'editable' => columns.any? { _1['Editable'] == true }, 'sortable' => true,
          'refresh' => @widget['RefreshTime'].to_i, 'selectfirst' => @widget['SelectFirst'] == true,
          'showemptyrows' => @widget['ShowEmptyRows'] == true
        }
      end

      def datasource
        type = SOURCE_TYPES[data_source['$Type']]
        @unsupported << data_source['$Type'].to_s unless type
        result = { 'friendlyId' => friendly_id, 'type' => type || 'unsupported', 'path' => entity }
        constraint = data_source['XPathConstraint'].to_s
        result['xpathConstraints'] = constraint if type == 'database' || !constraint.empty?
        result['offlineConstraints'] = [] if type == 'database'
        result['microflow'] = data_source.dig('MicroflowSettings', 'Microflow').to_s if type == 'microflow'
        result
      end

      def search_options
        kind = data_source.dig('SearchBar', 'Type').to_s
        {
          'searchBar' => !search_elements.empty?, 'toggleable' => kind.start_with?('Foldable'),
          'toggledByDefault' => kind != 'FoldableOpen'
        }
      end

      def search_elements
        array(data_source.dig('SearchBar', 'NewButtons')).filter_map do |field|
          unless %w[Forms$ComparisonSearchField Forms$DropDownSearchField].include?(field['$Type'])
            @unsupported << field['$Type'].to_s
            next
          end

          {
            'searchInputName' => field['Name'].to_s, 'defaults' => default_search_value(field),
            'defaultsParser' => 'Simple', 'caption' => translated(field['Caption']),
            'path' => relative_attribute(attribute_path(field)),
            'operator' => field.fetch('Operator', 'Equal').to_s.downcase
          }
        end
      end

      def control_bar
        tools = buttons.each_with_index.map { |button, index| compile_button(button, index) }
        {
          'gridTools' => tools.map(&:first),
          'gridActions' => tools.filter_map(&:last)
        }
      end

      def compile_button(button, index)
        id = "#{@sequence}_#{index}"
        type = button['$Type'].to_s
        function = BUTTON_FUNCTIONS[type]
        @unsupported << type unless function
        tool = {
          'mxid' => id, 'friendlyId' => "#{@page_name}.#{button['Name']}",
          'name' => button['Name'].to_s,
          'caption' => { '$type' => 'textTemplate', 'text' => button_caption(button),
                         'friendlyId' => "#{@page_name}.#{button['Name']}" },
          'title' => translated(button['Tooltip']), 'cssClass' => button_class(button)
        }
        action = function && { 'keyValue' => id, 'gridFunction' => function }
        params = button_params(button)
        action['params'] = params if action && params
        [tool, action]
      end

      def button_params(button)
        case button['$Type']
        when 'Forms$GridNewButton', 'Forms$GridEditButton'
          { entity => { 'pageSettings' => page_settings(button['FormSettings']) } }
        when 'Forms$GridActionButton'
          { entity => { 'action' => client_action(button['Action']),
                        'maintainSelection' => button['MaintainSelectionAfterMicroflow'] == true } }
        end
      end

      def client_action(action)
        case action&.fetch('$Type', nil)
        when 'Forms$MicroflowAction'
          microflow = action.dig('MicroflowSettings', 'Microflow').to_s
          { 'type' => 'callMicroflow', 'hasParameter' => true,
            'params' => { 'name' => microflow, 'validate' => 'view', 'applyTo' => 'selection' } }
        when 'Forms$FormAction'
          { 'type' => 'openPage', 'params' => page_settings(action['FormSettings']) }
        when 'Forms$DeleteClientAction'
          { 'type' => 'deleteObject', 'params' => { 'applyTo' => 'selection' } }
        when 'Forms$NoAction', nil then { 'type' => 'noAction' }
        else
          @unsupported << action['$Type'].to_s
          { 'type' => 'unsupported' }
        end
      end

      def page_settings(settings)
        form = settings&.fetch('Form', '').to_s
        location = settings&.fetch('Location', '').to_s
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

      def default_button
        pointer = IO::BsonCodec.extract_id(@widget.dig('ControlBar', 'DefaultButtonPointer'))
        index = buttons.index { IO::BsonCodec.extract_id(_1['$ID']) == pointer }
        return nil unless index

        { 'clickType' => @widget['DefaultButtonTrigger'].to_s.downcase, 'mxid' => "#{@sequence}_#{index}" }
      end

      def compile_column(column)
        path = relative_attribute(attribute_path(column))
        {
          'tag' => path, 'name' => column['Name'].to_s, 'editable' => column['Editable'] == true,
          'render' => render_type(column),
          'display' => { 'width' => "#{column['WidthValue'].to_i}%", 'string' => translated(column['Caption']) }
        }
      end

      def sort_items
        array(data_source.dig('SortBar', 'SortItems')).map do |item|
          [relative_attribute(attribute_path(item)), item['SortOrder'].to_s.downcase.sub('ending', '')]
        end
      end

      def entity
        direct = data_source['EntityPath'] || data_source.dig('EntityRef', 'Entity')
        direct.to_s.empty? ? attribute_path(columns.first).to_s.rpartition('.').first : direct.to_s
      end

      def entity_schema
        IO::BsonCodec.extract_id(@widget['$ID']).to_s
      end

      def render_type(column)
        format = column.dig('FormattingInfo', 'EnumFormat')
        format == 'Image' ? 'EnumImage' : 'String'
      end

      def attribute_path(value)
        value['AttributePath'] || value.dig('AttributeRef', 'Attribute')
      end

      def relative_attribute(path)
        path.to_s.delete_prefix("#{entity}.")
      end

      def buttons
        @buttons ||= begin
          control = @widget['ControlBar'] || {}
          [control['SearchButton'], *array(control['NewButtons'])].compact
        end
      end

      def data_source = @widget['DataSource'] || {}
      def columns = array(@widget['Columns'])
      def friendly_id = "#{@page_name}.#{@widget['Name']}"
      def widget_id = "#{@sequence}_#{buttons.length}"

      def css_class
        ['mx-datagrid', "mx-name-#{@widget['Name']}", @widget['Class']]
          .map(&:to_s).reject(&:empty?).uniq.join(' ')
      end

      def translated(text)
        items = array(text&.fetch('Items', nil))
        items.find { _1['LanguageCode'] == @language }&.fetch('Text', '') ||
          items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          items.first&.fetch('Text', '') || ''
      end

      def button_caption(button)
        translated(button.dig('CaptionTemplate', 'Template'))
      end

      def button_class(button)
        style = button['ButtonStyle'].to_s.downcase
        "btn-#{style.empty? ? 'default' : style}"
      end

      def default_search_value(field)
        value = field['DefaultValue']
        value.nil? || value.to_s.empty? ? nil : value
      end

      def escape(value)
        value.to_s.gsub('&', '&amp;').gsub("'", '&#39;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
  end
end
