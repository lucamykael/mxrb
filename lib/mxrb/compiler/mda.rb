# frozen_string_literal: true

require 'digest'
require 'json'
require 'zip'

module Mxrb
  module Compiler
    # Safe inspection and content-level comparison of Mendix deployment archives.
    module Mda
      Entry = Data.define(:path, :size, :crc, :sha256, :directory)
      Inspection = Data.define(:path, :metadata, :entries, :sha256) do
        def files = entries.reject(&:directory)
        def roots = entries.map { _1.path.split('/').first }.uniq.sort
      end
      Difference = Data.define(:path, :status, :left_sha256, :right_sha256)

      module_function

      def inspect(path)
        archive_path = File.expand_path(path)
        entries = read_entries(archive_path)
        metadata_entry = entries.find { _1.path == 'model/metadata.json' }
        metadata = read_metadata(archive_path, metadata_entry)
        raise CompilationError, 'MDA has no model/metadata.json' unless metadata

        build_inspection(archive_path, metadata, entries)
      rescue Zip::Error, JSON::ParserError => e
        raise CompilationError, "invalid MDA #{archive_path}: #{e.message}"
      end

      def compare(left, right)
        left_entries = entry_map(left)
        right_entries = entry_map(right)
        (left_entries.keys | right_entries.keys).sort.filter_map do |path|
          lhs = left_entries[path]
          rhs = right_entries[path]
          status = difference_status(lhs, rhs)
          next unless status

          Difference.new(path:, status:, left_sha256: lhs&.sha256, right_sha256: rhs&.sha256)
        end
      end

      def read_entries(archive_path)
        Zip::File.open(archive_path) do |archive|
          archive.map { build_entry(_1) }
        end
      end

      def build_inspection(path, metadata, entries)
        Inspection.new(
          path:, metadata:, entries: entries.sort_by(&:path),
          sha256: Digest::SHA256.file(path).hexdigest
        )
      end

      def build_entry(entry)
        path = safe_path(entry.name)
        directory = entry.directory?
        bytes = directory ? '' : entry.get_input_stream.read
        Entry.new(
          path:, size: entry.size, crc: entry.crc,
          sha256: directory ? nil : Digest::SHA256.hexdigest(bytes), directory:
        )
      end

      def read_metadata(archive_path, entry)
        return unless entry

        Zip::File.open(archive_path) do |archive|
          JSON.parse(archive.get_entry(entry.path).get_input_stream.read)
        end
      end

      def entry_map(path)
        inspect(path).files.to_h { [_1.path, _1] }
      end

      def difference_status(left, right)
        return :added unless left
        return :removed unless right
        return :changed if left.sha256 != right.sha256

        nil
      end

      def safe_path(path)
        clean = path.to_s.tr('\\', '/').sub(%r{\A/+}, '')
        parts = clean.split('/')
        if clean.empty? || parts.include?('..') || parts.include?('.')
          raise CompilationError, "unsafe MDA entry #{path.inspect}"
        end

        clean
      end
    end
  end
end
