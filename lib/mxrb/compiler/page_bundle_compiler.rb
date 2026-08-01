# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    PageBundle = Data.define(:qualified_name, :source, :unsupported_widgets)

    # Converts the web-page subset of the source model into a Runtime-loadable ES module.
    class PageBundleCompiler # rubocop:disable Metrics/ClassLength
      include ModelValues

      def initialize(source)
        @source = source
        @unsupported = []
      end

      def compile(unit)
        @unit = unit
        @qualified_name = "#{unit.module_name}.#{unit.document['Name']}"
        content = arguments.to_h do |argument|
          [argument['Parameter'].to_s, content_function(array(argument['Widgets']))]
        end
        PageBundle.new(
          qualified_name: @qualified_name, source: module_source(content),
          unsupported_widgets: @unsupported.uniq.sort.freeze
        )
      end

      private

      def arguments = array(@unit.document.dig('FormCall', 'Arguments'))

      def content_function(widgets)
        "renderKey => React.createElement(PageFragment, { renderKey }, #{children(widgets)})"
      end

      def children(widgets) = "[#{widgets.map { render_widget(_1) }.join(', ')}]"

      def render_widget(widget)
        case widget['$Type']
        when 'Forms$DivContainer' then render_container(widget)
        when 'Forms$DynamicText' then render_text(widget)
        when 'CustomWidgets$CustomWidget' then render_custom_widget(widget)
        else render_unsupported(widget)
        end
      end

      def render_custom_widget(widget)
        compiler = DataGridBundleCompiler.new(@source, @qualified_name, widget)
        return render_unsupported(widget) unless compiler.supported?

        @uses_data_grid = true
        compiler.render
      end

      def render_container(widget)
        props = common_props(widget).merge(
          className: css_class(widget), children: array(widget['Widgets']).map { render_widget(_1) }
        )
        "React.createElement(#{JSON.generate(render_mode(widget))}, #{js_props(props)})"
      end

      def render_text(widget)
        props = common_props(widget).merge(className: css_class(widget))
        caption = translated_text(widget.dig('Content', 'Template'))
        "React.createElement(#{JSON.generate(text_mode(widget))}, #{js_props(props)}, #{JSON.generate(caption)})"
      end

      def render_unsupported(widget)
        type = widget['$Type'].to_s
        @unsupported << type
        props = common_props(widget).merge(
          className: "#{css_class(widget)} mxrb-unsupported-widget".strip,
          'data-mxrb-widget-type': type
        )
        "React.createElement(\"div\", #{js_props(props)})"
      end

      def common_props(widget)
        { key: widget_key(widget), 'data-widget-id': widget_key(widget) }
      end

      def widget_key(widget) = "p.#{@qualified_name}.#{widget['Name']}"

      def css_class(widget)
        name = widget['Name'].to_s
        appearance = widget.dig('Appearance', 'Class').to_s
        ["mx-name-#{name}", widget['Class'], appearance].map(&:to_s).reject(&:empty?).uniq.join(' ')
      end

      def render_mode(widget) = widget['RenderMode'].to_s.downcase.then { _1.empty? ? 'div' : _1 }

      def text_mode(widget)
        { 'Text' => 'span', 'Paragraph' => 'p', 'Heading1' => 'h1', 'Heading2' => 'h2',
          'Heading3' => 'h3', 'Heading4' => 'h4', 'Heading5' => 'h5', 'Heading6' => 'h6' }
          .fetch(widget['RenderMode'].to_s, 'span')
      end

      def translated_text(text)
        array(text&.fetch('Items', nil)).find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          array(text&.fetch('Items', nil)).first&.fetch('Text', '') || ''
      end

      def js_props(props)
        pairs = props.map do |key, value|
          rendered = value.is_a?(Array) ? "[#{value.join(', ')}]" : JSON.generate(value)
          "#{JSON.generate(key)}: #{rendered}"
        end
        "{ #{pairs.join(', ')} }"
      end

      def module_source(content)
        <<~JS
          import React from "react";
          import { PageFragment } from "mendix/PageFragment";
          #{data_grid_imports}

          export const title = #{JSON.generate(page_title)};
          export const classes = #{JSON.generate(page_classes)};
          export const autofocus = "off";
          export const style = {};
          export const parameters = {};
          export const content = #{render_content(content)};
        JS
      end

      def data_grid_imports
        return '' unless @uses_data_grid

        <<~JS.chomp
          import { asPluginWidgets } from "mendix";
          import { DatabaseObjectListProperty } from "mendix/DatabaseObjectListProperty";
          import { AttributeProperty } from "mendix/AttributeProperty";
          import { ExpressionProperty } from "mendix/ExpressionProperty";
          import Datagrid from "../widgets/com/mendix/widget/web/datagrid/Datagrid.mjs";
          const { $Datagrid } = asPluginWidgets({ Datagrid });
        JS
      end

      def page_title = translated_text(@unit.document['Title'])
      def page_classes = layout&.document&.dig('Appearance', 'Class').to_s

      def render_content(content)
        JSON.pretty_generate(content).sub(/\A\{/, '{').sub(/\}\z/, '}')
            .gsub(/"(renderKey =>[^\n]+)"/) { Regexp.last_match(1).gsub('\\"', '"') }
      end

      def layout
        qualified = @unit.document.dig('FormCall', 'Form').to_s
        @source.units_of('Forms$Layout').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified
        end
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
