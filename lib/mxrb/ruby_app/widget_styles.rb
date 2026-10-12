# frozen_string_literal: true

require 'fileutils'
require 'zip'

module Mxrb
  module RubyApp
    # The styles pluggable widget packages carry for themselves. MxBuild bundles
    # those of the widgets a project uses, with the assets they refer to, into
    # dist/widgets.css, which the client loads after the theme; the exported
    # frontend does the same from the project's own widget packages. A widget's
    # stylesheet sits at its id as a path ("com/x/y/Widget.css").
    module WidgetStyles
      FILE = 'widgets.css'

      module_function

      def write(project_dir, destination, widget_ids)
        FileUtils.rm_rf(destination)
        FileUtils.mkdir_p(destination)
        sheets = widget_ids.to_set { "#{_1.tr('.', '/')}.css" }
        styles = Dir.glob(File.join(project_dir, 'widgets', '*.mpk')).sort.flat_map do |path|
          package(path, destination, sheets)
        end
        File.write(File.join(destination, FILE), styles.join("\n"))
      end

      # The ids of the pluggable widgets in the pages, snippets and layouts.
      def widget_ids(project)
        project.modules.flat_map { DesignClasses.documents(_1) }.each_with_object(Set.new) do |(_name, document), ids|
          collect_ids(document, ids)
        end
      end

      def collect_ids(node, ids)
        case node
        when Hash
          ids << node.dig('Type', 'WidgetId') if node['$Type'] == 'CustomWidgets$CustomWidget'
          node.each_value { collect_ids(_1, ids) }
        when Array then node.each { collect_ids(_1, ids) }
        end
      end

      # The stylesheets of the used widgets of one package; their assets are
      # copied beside them.
      def package(path, destination, sheets)
        Zip::File.open(path) do |archive|
          files = archive.entries.select { _1.file? && safe?(_1.name) }
          used = files.select { sheets.include?(_1.name) }
          copy_assets(files, used, destination)
          used.map { _1.get_input_stream.read.force_encoding(Encoding::UTF_8) }
        end
      rescue Zip::Error
        []
      end

      def copy_assets(files, sheets, destination)
        directories = sheets.map { "#{File.dirname(_1.name)}/assets/" }
        files.each { |file| copy_asset(file, destination) if directories.any? { file.name.start_with?(_1) } }
      end

      def copy_asset(file, destination)
        target = File.join(destination, file.name)
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, file.get_input_stream.read)
      end

      def safe?(name)
        !name.start_with?('/') && !name.split('/').include?('..')
      end
    end
  end
end
