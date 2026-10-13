# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Cheap request-boundary change detector for editable Ruby application code.
    # Vite owns frontend HMR; this detector deliberately ignores generated and
    # dependency directories and never invokes the Mendix compiler.
    class SourceReloader
      attr_reader :revision

      def initialize(root)
        @root = File.expand_path(root)
        @revision = capture
      end

      def changed_revision
        current = capture
        current == revision ? nil : current
      end

      def commit(revision) = (@revision = revision.freeze)

      private

      def capture
        paths.to_h do |path|
          stat = File.stat(path)
          [path, [stat.size, stat.mtime.to_i, stat.mtime.nsec].freeze]
        end.freeze
      end

      def paths
        adapters = File.join(@root, 'config', 'adapters.rb')
        [*RubyApp.application_files(@root), *(File.file?(adapters) ? [adapters] : [])].sort
      end
    end
  end
end
