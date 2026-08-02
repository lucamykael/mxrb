# frozen_string_literal: true

require 'fileutils'
require 'zip'

module Mxrb
  module Compiler
    # Expands project-owned pluggable widget packages into the web build tree.
    class WidgetPackageExtractor
      def initialize(project_root, web_root)
        @source = File.join(project_root, 'widgets')
        @destination = File.join(web_root, 'widgets')
      end

      def extract
        return 0 unless File.directory?(@source)

        FileUtils.mkdir_p(@destination)
        Dir.glob(File.join(@source, '*.mpk')).sort.sum { extract_package(_1) }
      end

      private

      def extract_package(path)
        Zip::File.open(path) do |archive|
          entries = archive.reject(&:directory?)
          entries.each { write_entry(_1) }
          return entries.length
        end
      rescue Zip::Error => e
        raise CompilationError, "invalid widget package #{path}: #{e.message}"
      end

      def write_entry(entry)
        destination = safe_destination(entry.name)
        FileUtils.mkdir_p(File.dirname(destination))
        File.binwrite(destination, entry.get_input_stream.read)
      end

      def safe_destination(name)
        destination = File.expand_path(name, @destination)
        prefix = "#{File.expand_path(@destination)}#{File::SEPARATOR}"
        return destination if destination.start_with?(prefix)

        raise CompilationError, "unsafe widget package entry #{name}"
      end
    end
  end
end
