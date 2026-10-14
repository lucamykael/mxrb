# frozen_string_literal: true

require 'zip'
require_relative '../widget_package'

module Mxrb
  module RubyApp
    # The web build of one of the project's own pluggable widgets: its ES module,
    # styles and assets, read from the project's widgets/*.mpk together with the
    # widget's property definitions. MXRB distributes none of this code.
    module ProjectWidgetBundle
      Bundle = Data.define(:widget_id, :name, :entry, :files, :definition)

      module_function

      def find(root, widget_id)
        Dir.glob(File.join(File.expand_path(root), 'widgets', '*.mpk')).sort.each do |path|
          definition = WidgetPackage.new(path).definition(widget_id)
          next unless definition&.plugin && definition.platform != 'Native'

          bundle = read(path, definition)
          return bundle if bundle
        rescue Zip::Error, REXML::ParseException
          next
        end
        nil
      end

      # The widget's directory holds <Name>.mjs, the AMD <Name>.js the ES module
      # replaces, and the stylesheet and assets both builds share.
      def read(path, definition)
        *packages, name = definition.id.split('.')
        directory = "#{packages.join('/')}/"
        Zip::File.open(path) do |archive|
          next unless archive.find_entry("#{directory}#{name}.mjs")

          Bundle.new(widget_id: definition.id, name:, entry: "#{name}.mjs",
                     files: files(archive, directory, skip: "#{name}.js"), definition:)
        end
      end

      def files(archive, directory, skip:)
        archive.select { _1.file? && _1.name.start_with?(directory) }.filter_map do |entry|
          relative = entry.name.delete_prefix(directory)
          [relative, entry.get_input_stream.read] unless relative == skip
        end.to_h
      end

      # The property definitions the frontend host maps to the pluggable widget API.
      def properties(definition_properties)
        definition_properties.reject { _1[:system] }.map do |property|
          {
            key: property[:key], type: property[:type], list: property[:list],
            data_source: property[:data_source], default: property[:default],
            properties: properties(property[:children] || [])
          }.reject { |_key, value| value.respond_to?(:empty?) && value.empty? }
        end
      end
    end
  end
end
