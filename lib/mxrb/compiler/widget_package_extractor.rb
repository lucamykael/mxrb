# frozen_string_literal: true

require 'fileutils'
require 'zip'

module Mxrb
  module Compiler
    # Expands project-owned pluggable widget packages into the web build tree.
    # rubocop:disable Metrics
    class WidgetPackageExtractor
      def initialize(project_root, web_root)
        @source = File.join(project_root, 'widgets')
        @web_root = web_root
        @destination = File.join(web_root, 'widgets')
      end

      def extract
        FileUtils.rm_f(File.join(@web_root, 'mxrb-widgets.css'))
        FileUtils.rm_f(File.join(@destination, 'mxrb-widgets.css'))
        return 0 unless File.directory?(@source)

        FileUtils.mkdir_p(@destination)
        Dir.glob(File.join(@source, '*.mpk')).sort.sum { extract_package(_1) }
      end

      private

      def extract_package(path)
        Zip::File.open(path) do |archive|
          entries = archive.reject(&:directory?)
          entries.each { safe_destination(_1.name) }
          runtime_roots = entries.select { _1.name.end_with?('.mjs') }
                                 .map { File.dirname(_1.name) }.uniq
          runtime_entries = entries.select do |entry|
            runtime_roots.any? do |root|
              if root == '.'
                entry.name.match?(/\.(?:m?js|css)\z/) || entry.name.start_with?('assets/')
              else
                entry.name.start_with?("#{root}/")
              end
            end
          end
          runtime_entries.each { write_entry(_1) }
          return runtime_entries.length
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
    # rubocop:enable Metrics
  end
end
