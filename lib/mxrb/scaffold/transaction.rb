# frozen_string_literal: true

module Mxrb
  module Scaffold
    # Applies a set of file creations and replacements with rollback on failure.
    class Transaction
      Change = Data.define(:path, :content, :original, :mode)

      attr_reader :created, :updated

      def initialize
        @changes = {}
        @created = []
        @updated = []
      end

      def content(path)
        return @changes.fetch(path).content if @changes.key?(path)
        return File.binread(path) if File.file?(path)

        nil
      end

      def create(path, content)
        abort "#{path}: file already exists" if File.exist?(path) || @changes.key?(path)

        @created << path
        @changes[path] = Change.new(path, content, nil, 0o644)
      end

      def write(path, new_content)
        original = content(path)
        return create(path, new_content) unless original
        return if original == new_content

        @updated << path unless @updated.include?(path)
        mode = File.stat(path).mode
        @changes[path] = Change.new(path, new_content, File.binread(path), mode)
      end

      def commit
        applied = []
        @changes.each_value do |change|
          apply(change)
          applied << change
        end
      rescue StandardError
        applied.reverse_each { rollback(_1) }
        raise
      ensure
        cleanup_staging
      end

      private

      def apply(change)
        FileUtils.mkdir_p(File.dirname(change.path))
        staging = staging_path(change.path)
        @staging_paths ||= []
        @staging_paths << staging
        File.binwrite(staging, change.content)
        File.chmod(change.mode, staging)
        File.rename(staging, change.path)
      end

      def rollback(change)
        if change.original
          File.binwrite(change.path, change.original)
          File.chmod(change.mode, change.path)
        else
          FileUtils.rm_f(change.path)
        end
      end

      def staging_path(path)
        File.join(File.dirname(path), ".#{File.basename(path)}.mxrb-#{Process.pid}-#{@changes.size}")
      end

      def cleanup_staging
        Array(@staging_paths).each { FileUtils.rm_f(_1) }
      end
    end
  end
end
