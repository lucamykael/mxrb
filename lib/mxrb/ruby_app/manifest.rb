# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Reads and validates paths before runtime or reverse compilation uses them.
    class Manifest
      attr_reader :root, :data

      def self.load(root)
        expanded = File.expand_path(root)
        path = File.join(expanded, MANIFEST_PATH)
        raise ArgumentError, "not an MXRB Ruby application: #{expanded}" unless File.file?(path)

        new(expanded, JSON.parse(File.read(path)))
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid MXRB Ruby application manifest: #{e.message}"
      end

      def initialize(root, data)
        @root = root
        @data = data
        raise ArgumentError, 'MXRB Ruby application manifest must use mode ruby' unless data['mode'] == 'ruby'
      end

      def mpr_name = data.fetch('source').fetch('name')
      def modules = data.fetch('modules')
      def coverage = data.fetch('coverage')

      def absolute_path(key)
        relative = data.fetch('round_trip').fetch(key)
        clean = Pathname.new(relative).cleanpath
        if clean.absolute? || clean.to_s.start_with?('../')
          raise ArgumentError,
                "unsafe Ruby application path: #{relative}"
        end

        File.join(root, clean.to_s)
      end
    end
  end
end
