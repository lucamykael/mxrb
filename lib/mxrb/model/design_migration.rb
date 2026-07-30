# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Mxrb
  module Model
    DesignMigrationChange = Data.define(:path, :before, :after, :occurrences)

    # Immutable preview of literal-to-token stylesheet replacements.
    class DesignMigrationPlan
      attr_reader :changes

      def self.build(root, replacements)
        pairs = replacements.to_h.transform_keys(&:to_s).transform_values(&:to_s)
        changes = stylesheet_paths(root).filter_map { migration_change(root, _1, pairs) }
        new(root, changes)
      end

      def self.stylesheet_paths(root)
        paths = DesignSystem::ASSET_DIRECTORIES.flat_map do |directory|
          Dir.glob(File.join(root, directory, '**', '*.{css,scss}'))
        end
        paths.select { File.file?(_1) && !File.symlink?(_1) }.sort
      end

      def self.migration_change(root, path, pairs)
        before = File.binread(path)
        after = pairs.reduce(before) { |text, (literal, token)| text.gsub(literal, token) }
        return if after == before

        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        occurrences = pairs.sum { |literal, _| before.scan(literal).size }
        DesignMigrationChange.new(relative, before, after, occurrences)
      end
      private_class_method :stylesheet_paths, :migration_change

      def initialize(root, changes)
        @root = File.expand_path(root)
        @changes = changes.freeze
        @digests = changes.to_h { [_1.path, Digest::SHA256.hexdigest(_1.before)] }.freeze
        @applied = false
      end

      def empty? = @changes.empty?
      def applied? = @applied

      def apply!
        raise ArgumentError, 'design migration plan was already applied' if @applied

        @changes.each { apply_change(_1) }
        @applied = true
        self
      end

      private

      def apply_change(change)
        temporary = nil
        target = File.join(@root, change.path)
        unless Digest::SHA256.file(target).hexdigest == @digests.fetch(change.path)
          raise SerializationError, "design asset changed after preview: #{change.path}"
        end

        temporary = "#{target}.mxrb-#{Process.pid}"
        File.binwrite(temporary, change.after)
        FileUtils.mv(temporary, target)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end
    end
  end
end
