# frozen_string_literal: true

require 'fileutils'
require 'json'

module Mxrb
  module Compiler
    LegacyPageBuild = Data.define(:directory, :files, :bytes, :unsupported_widgets)

    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength
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
        Forms$TextBox Forms$InputReferenceSetSelector
      ].freeze

      def initialize(source, web_root, profiles: [:dojo])
        @source = source
        @web_root = web_root
        @profiles = profiles
        @unsupported = Hash.new { |hash, key| hash[key] = [] }
      end

      def build
        pages = @source.units_of('Forms$Page')
        languages.each { |language| pages.each { write_page(_1, language) } }
        write_manifest
        files = Dir.glob(File.join(@web_root, 'pages', '**', '*.page.xml')).select { File.file?(_1) }
        LegacyPageBuild.new(
          directory: File.join(@web_root, 'pages'), files: files.length,
          bytes: files.sum { File.size(_1) }, unsupported_widgets: frozen_unsupported
        )
      end

      private

      def write_page(unit, language)
        name = "#{unit.module_name}.#{unit.document['Name']}"
        audit_unsupported_widgets(unit.document, name)
        grids = descendants(unit.document).select { _1['$Type'] == 'Forms$DataGrid' }
        rendered = grids.each_with_index.map do |grid, index|
          compiler = LegacyDataGridCompiler.new(@source, name, grid, language:, sequence: index + 1)
          compiler.html.tap { @unsupported[name].concat(compiler.unsupported) }
        end.join
        path = File.join(@web_root, 'pages', language, unit.module_name, "#{unit.document['Name']}.page.xml")
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, page_xml(unit, language, rendered))
      end

      def audit_unsupported_widgets(root, page_name)
        visit = lambda do |value|
          case value
          when Hash
            type = value['$Type'].to_s
            if type == 'Forms$DataGrid'
              return
            elsif VISUAL_WIDGET_TYPES.include?(type)
              @unsupported[page_name] << type
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
        parameter = argument&.fetch('Parameter', '').to_s
        "\uFEFF<?xml version='1.0' encoding='utf-8'?>" \
          "<m:page id='#{unit.id}' xmlns='http://www.w3.org/1999/xhtml' " \
          "title='#{escape(title)}' xmlns:m='http://schemas.mendix.com/forms/1.0'>" \
          "<m:layouts>#{layout.empty? ? '' : "<m:layout path='#{escape(layout)}.layout.xml'></m:layout>"}</m:layouts>" \
          "<m:arguments><m:argument parameterName='#{escape(parameter)}'>#{content}</m:argument></m:arguments>" \
          '</m:page>'
      end

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
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength
  end
end
