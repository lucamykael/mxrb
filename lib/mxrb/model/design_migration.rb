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
        @after_digests = changes.to_h { [_1.path, Digest::SHA256.hexdigest(_1.after)] }.freeze
        @applied = false
      end

      def empty? = @changes.empty?
      def applied? = @applied

      def apply!
        raise ArgumentError, 'design migration plan was already applied' if @applied

        verify_changes!(@digests, 'changed after preview')
        replace_all!(fallback: :before, &:after)
        @applied = true
        self
      end

      # Restores the previewed contents when a surrounding batch fails.
      def rollback!
        return self unless @applied

        verify_changes!(@after_digests, 'changed after migration')
        replace_all!(fallback: :after, &:before)
        @applied = false
        self
      end

      private

      def verify_changes!(digests, reason)
        @changes.each do |change|
          target = File.join(@root, change.path)
          unless File.file?(target) && Digest::SHA256.file(target).hexdigest == digests.fetch(change.path)
            raise SerializationError, "design asset #{reason}: #{change.path}"
          end
        end
      end

      def replace_all!(fallback:)
        staged = {}
        staged = stage_changes { yield(_1) }
        commit_staged!(staged, fallback)
      ensure
        staged.each_value { FileUtils.rm_f(_1) }
      end

      def stage_changes
        @changes.to_h do |change|
          temporary = temporary_path(change.path)
          File.binwrite(temporary, yield(change))
          [change.path, temporary]
        end
      end

      def commit_staged!(staged, fallback)
        committed = []
        @changes.each do |change|
          FileUtils.mv(staged.fetch(change.path), File.join(@root, change.path))
          committed << change
        end
      rescue StandardError
        restore_committed!(committed, fallback)
        raise
      end

      def restore_committed!(committed, fallback)
        committed.reverse_each do |change|
          target = File.join(@root, change.path)
          temporary = "#{target}.mxrb-rollback-#{Process.pid}-#{staged_suffix(change.path)}"
          File.binwrite(temporary, change.public_send(fallback))
          FileUtils.mv(temporary, target)
        ensure
          FileUtils.rm_f(temporary)
        end
      end

      def staged_suffix(path)
        Digest::SHA256.hexdigest(path)[0, 12]
      end

      def temporary_path(path)
        "#{File.join(@root, path)}.mxrb-#{Process.pid}-#{staged_suffix(path)}"
      end
    end
  end
end
