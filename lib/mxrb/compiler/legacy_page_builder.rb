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
        Forms$DivContainer Forms$DropDown Forms$DynamicText Forms$ImageViewer Forms$Label
        Forms$LayoutGrid Forms$ListView Forms$RadioButtonGroup Forms$ReferenceSelector
        Forms$SnippetCallWidget Forms$StaticImageViewer Forms$TabControl Forms$TextArea
        Forms$TextBox Forms$InputReferenceSetSelector CustomWidgets$CustomWidget
      ].freeze

      def initialize(source, web_root, profiles: [:dojo])
        @source = source
        @web_root = web_root
        @profiles = profiles
        @unsupported = Hash.new { |hash, key| hash[key] = [] }
      end

      def build
        pages = @source.units_of('Forms$Page')
        layouts = @source.units_of('Forms$Layout')
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
        (@source.units_of('Forms$Layout') + @source.units_of('Forms$Page')).each do |unit|
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

      def write_page(unit, language)
        name = "#{unit.module_name}.#{unit.document['Name']}"
        audit_unsupported_widgets(unit.document, name)
        @widget_sequence = 0
        rendered = page_widgets(unit.document).map { render_widget(_1, name, language) }.join
        path = File.join(@web_root, 'pages', language, unit.module_name, "#{unit.document['Name']}.page.xml")
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, page_xml(unit, language, rendered))
      end

      def write_layout(unit, language)
        name = "#{unit.module_name}.#{unit.document['Name']}"
        audit_unsupported_widgets(unit.document, name)
        @widget_sequence = 0
        rendered = layout_widgets(unit.document).map { render_widget(_1, name, language) }.join
        path = File.join(@web_root, 'pages', language, unit.module_name, "#{unit.document['Name']}.layout.xml")
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, layout_xml(unit, rendered))
      end

      def audit_unsupported_widgets(root, page_name)
        visit = lambda do |value|
          case value
          when Hash
            type = value['$Type'].to_s
            if type == 'Forms$DataGrid'
              return
            elsif VISUAL_WIDGET_TYPES.include?(type) && !supported_widget_type?(type)
              @unsupported[page_name] << type
            elsif type == 'Forms$DynamicText' && !array(value.dig('Content', 'Parameters')).empty?
              @unsupported[page_name] << 'Forms$DynamicText(parameters)'
            elsif type == 'Forms$DivContainer'
              action_type = value.dig('OnClickAction', '$Type').to_s
              @unsupported[page_name] << 'Forms$DivContainer(onClick)' \
                unless action_type.empty? || action_type == 'Forms$NoAction'
            end

            value.each_value { visit.call(_1) }
          when Array then value.each { visit.call(_1) }
          end
        end
        visit.call(root)
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
          '</m:page>'
      end

      def layout_xml(unit, content)
        "\uFEFF<?xml version='1.0' encoding='utf-8'?>" \
          "<m:layout id='#{unit.id}' xmlns='http://www.w3.org/1999/xhtml' " \
          "xmlns:m='http://schemas.mendix.com/forms/1.0'>" \
          "<m:arguments><m:argument>#{content}</m:argument></m:arguments></m:layout>"
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
        when 'Forms$DynamicText'
          render_dynamic_text(widget, language)
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

      def render_dynamic_text(widget, language)
        content = widget['Content'] || {}
        text = translated(content['Template'], language)
        text = translated(content['Fallback'], language) if text.empty?
        tag = widget['RenderMode'].to_s == 'Paragraph' ? 'p' : 'span'
        attributes = html_attributes(widget, base: 'mx-text', mendix_id: next_widget_id)
        "<#{tag}#{attributes}>#{escape(text)}</#{tag}>"
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
        %w[Forms$DataGrid Forms$DivContainer Forms$DynamicText].include?(type)
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
        @unsupported.transform_values { _1.reject(&:empty?).uniq.sort }.freeze
      end

      def escape(value)
        value.to_s.gsub('&', '&amp;').gsub("'", '&#39;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
