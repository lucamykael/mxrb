# frozen_string_literal: true

require 'digest'
require 'rbconfig'
require 'fileutils'
require 'open3'
require 'securerandom'
require_relative 'write_lock'

module Mxrb
  module Studio
    class Conflict < StandardError; end

    # Filesystem backend shared by the explorer and code editor. Linux directory
    # handles anchor operations even when another process replaces a parent path.
    # Writers using this API share a lock; arbitrary external editors must still
    # cooperate to provide strict, cross-process compare-and-swap semantics.
    class Files # rubocop:disable Metrics/ClassLength
      MAXIMUM_BYTES = 4 * 1024 * 1024
      HIDDEN_DIRECTORIES = %w[.git node_modules vendor .bundle coverage].freeze
      attr_reader :root

      # Atomic no-replace rename, without an optional native gem dependency.
      module NativeRename
        def self.call(*arguments)
          raise NotImplementedError, 'Studio file operations require Linux' unless RUBY_PLATFORM.include?('linux')

          number = { 'x86_64' => 316, 'aarch64' => 276 }.fetch(RbConfig::CONFIG['host_cpu']) do
            raise NotImplementedError, 'atomic Studio moves require Linux x86_64 or aarch64'
          end
          syscall(number, *arguments)
        end
      end
      private_constant :NativeRename

      def initialize(root)
        @root = File.realpath(root)
        raise ArgumentError, 'workspace root must be a directory' unless File.directory?(@root)
      end

      def list(path = '.', include_ignored: false) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        entries = with_directory(path) do |directory|
          Dir.children(handle_path(directory)).filter_map do |name|
            next if name == '.git' || (!include_ignored && HIDDEN_DIRECTORIES.include?(name))

            stat = File.lstat(File.join(handle_path(directory), name))
            next if stat.symlink? || (!stat.directory? && !stat.file?)

            { name:, path: relative(File.join(normalize(path), name)), directory: stat.directory?, size: stat.size }
          rescue Errno::ENOENT
            # An external editor may remove a directory entry while it is listed.
            nil
          end
        end
        entries.sort_by { [_1[:directory] ? 0 : 1, _1[:name].downcase] }
      end

      def read(path)
        with_parent(path) { |parent, name, target| read_at(parent, name, target) }
      end

      def write(path, text:, revision:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        text = validate_text(text)
        with_lock do
          with_parent(path) do |parent, name, target|
            current = read_at(parent, name, target)
            check_revision(current, revision)
            mode = File.lstat(File.join(handle_path(parent), name)).mode & 0o777
            temporary = ".mxrb-#{SecureRandom.hex(16)}"
            begin
              File.open(File.join(handle_path(parent), temporary), File::WRONLY | File::CREAT | File::EXCL,
                        mode) do |file|
                file.chmod(mode)
                file.write(text)
                file.flush
                file.fsync
              end
              check_revision(read_at(parent, name, target), revision)
              rename(parent, temporary, parent, name)
            ensure
              FileUtils.rm_f(File.join(handle_path(parent), temporary))
            end
            { path: relative(target), revision: Digest::SHA256.hexdigest(text) }
          end
        end
      end

      def create(path, directory: false, text: '') # rubocop:disable Metrics/MethodLength
        text = validate_text(text)
        with_lock do
          with_parent(path) do |parent, name, target|
            destination = File.join(handle_path(parent), name)
            if directory
              Dir.mkdir(destination)
            else
              File.open(destination, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o644) { _1.write(text) }
            end
            { path: relative(target), directory: }
          rescue Errno::EEXIST
            raise Conflict, 'destination already exists'
          end
        end
      end

      def move(path, destination:)
        with_lock do
          with_parent(path) do |source_parent, source_name, source|
            source_entry = File.join(handle_path(source_parent), source_name)
            raise ArgumentError, 'symlink traversal is not supported' if File.symlink?(source_entry)

            with_parent(destination) do |target_parent, target_name, target|
              rename(source_parent, source_name, target_parent, target_name, no_replace: true)
              { path: relative(target), previous_path: relative(source) }
            end
          end
        end
      end

      # Deletes a file, or a folder when `recursive` is set (an empty folder
      # otherwise). A file revision, when given, must still match: deleting a
      # file that changed after the caller read it would discard those edits.
      def delete(path, recursive: false, revision: nil) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        with_lock do
          with_parent(path) do |parent, name, target|
            raise ArgumentError, 'Git metadata cannot be deleted from the explorer' if name == '.git'

            entry = File.join(handle_path(parent), name)
            stat = File.lstat(entry)
            raise ArgumentError, 'symlink traversal is not supported' if stat.symlink?

            if stat.directory?
              recursive ? FileUtils.rm_r(entry, secure: true) : Dir.rmdir(entry)
            else
              check_revision(read_at(parent, name, target), revision) if revision
              File.unlink(entry)
            end
            { path: relative(target), directory: stat.directory?, deleted: true }
          rescue Errno::ENOTEMPTY, Errno::EEXIST
            raise Conflict, 'folder is not empty'
          rescue Errno::ENOENT
            raise Conflict, 'the file no longer exists'
          end
        end
      end

      def worktrees # rubocop:disable Metrics/AbcSize
        output, _errors, status = Open3.capture3('git', '-C', root, 'worktree', 'list', '--porcelain', '-z')
        return [] unless status.success?

        output.split("\0\0").filter_map do |block|
          fields = block.split("\0").to_h { |line| line.split(' ', 2).then { [_1[0], _1[1] || true] } }
          next unless fields['worktree']

          { path: fields['worktree'], branch: fields['branch'], head: fields['HEAD'],
            detached: fields.key?('detached'), current: File.expand_path(fields['worktree']) == root }
        end
      rescue Errno::ENOENT
        []
      end

      # Adds a Git worktree next to the workspace, on a new or existing branch.
      # The destination must be absolute and outside the current worktree.
      def add_worktree(destination, branch:, base: nil)
        repository!
        target = absolute_outside(destination)
        branch = branch_name(branch)
        arguments = if git_success?('show-ref', '--verify', '--quiet', "refs/heads/#{branch}")
                      [target, branch]
                    else
                      ['-b', branch, target, *([revision_name(base)] if base)]
                    end
        git!('worktree', 'add', *arguments)
        worktrees.find { File.expand_path(_1[:path]) == target } || { path: target, branch: "refs/heads/#{branch}" }
      end

      # Removes a linked worktree. Git refuses one with local changes; this
      # API never forces removal, so uncommitted work is preserved.
      def remove_worktree(destination)
        repository!
        target = File.expand_path(destination)
        known = worktrees
        entry = known.find { File.expand_path(_1[:path]) == target }
        raise ArgumentError, 'not a worktree of this repository' unless entry
        raise ArgumentError, 'the main worktree cannot be removed' if entry == known.first
        raise ArgumentError, 'the open worktree cannot be removed' if entry[:current]

        git!('worktree', 'remove', target)
        { path: target, removed: true }
      end

      private

      def repository!
        raise ArgumentError, 'the Ruby project is not a Git repository' unless git_success?('rev-parse', '--git-dir')
      end

      def absolute_outside(destination)
        unless destination.is_a?(String) && destination.start_with?('/') && !destination.include?("\0")
          raise ArgumentError, 'worktree path must be absolute'
        end

        target = File.expand_path(destination)
        if target == root || target.start_with?(root.delete_suffix(File::SEPARATOR) + File::SEPARATOR)
          raise ArgumentError, 'worktree path must be outside the current worktree'
        end
        raise Conflict, 'worktree path already exists' if File.exist?(target)

        target
      end

      def branch_name(branch)
        valid = branch.is_a?(String) && !branch.start_with?('-') &&
                git_success?('check-ref-format', '--branch', branch)
        raise ArgumentError, 'invalid branch name' unless valid

        branch
      end

      def revision_name(base)
        raise ArgumentError, 'invalid base revision' if !base.is_a?(String) || base.start_with?('-') || base.empty?

        known = git_success?('rev-parse', '--verify', '--quiet', "#{base}^{commit}")
        raise ArgumentError, "unknown base revision: #{base}" unless known

        base
      end

      def git_success?(*arguments)
        Open3.capture3('git', '-C', root, *arguments)[2].success?
      rescue Errno::ENOENT
        false
      end

      def git!(*arguments)
        output, error, status = Open3.capture3('git', '-C', root, *arguments)
        raise Conflict, (error.strip.empty? ? output : error).strip.lines.last.to_s.strip unless status.success?

        output
      rescue Errno::ENOENT
        raise ArgumentError, 'Git is not installed'
      end

      def validate_text(text)
        if text.is_a?(String) && [Encoding::UTF_8, Encoding::US_ASCII, Encoding::ASCII_8BIT].include?(text.encoding)
          text = text.dup.force_encoding(Encoding::UTF_8)
          return text if text.valid_encoding? && !text.include?("\0") && text.bytesize <= MAXIMUM_BYTES
        end

        raise ArgumentError, 'text must be UTF-8, without NUL, at most 4 MiB'
      end

      def relative(path)
        path == root ? '.' : path.delete_prefix(root.delete_suffix(File::SEPARATOR) + File::SEPARATOR)
      end

      def normalize(path)
        if !path.is_a?(String) || path.empty? || path.start_with?('/') || path.include?("\0")
          raise ArgumentError, 'path must be relative to the workspace'
        end

        target = File.expand_path(path, root)
        unless target == root || target.start_with?(root.delete_suffix(File::SEPARATOR) + File::SEPARATOR)
          raise ArgumentError, 'path escapes the workspace'
        end

        target
      end

      def handle_path(file) = "/proc/self/fd/#{file.fileno}"

      def with_directory(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        parts = relative(normalize(path)).split(File::SEPARATOR).reject { _1 == '.' }
        handles = [File.open(root, File::RDONLY | File::NOFOLLOW)]
        parts.each do |part|
          handles << File.open(File.join(handle_path(handles.last), part), File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
          raise ArgumentError, 'not a directory' unless handles.last.stat.directory?
        end
        yield handles.last
      rescue Errno::ELOOP
        raise ArgumentError, 'symlink traversal is not supported'
      ensure
        handles&.reverse_each(&:close)
      end

      def with_parent(path)
        target = normalize(path)
        raise ArgumentError, 'operation requires a path below the workspace root' if target == root

        with_directory(relative(File.dirname(target))) { |parent| yield parent, File.basename(target), target }
      end

      def read_at(parent, name, target) # rubocop:disable Metrics/AbcSize
        File.open(File.join(handle_path(parent), name), File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          raise ArgumentError, 'not a file' unless file.stat.file?

          bytes = file.read(MAXIMUM_BYTES + 1) || ''
          raise ArgumentError, 'file exceeds editor limit (4 MiB)' if bytes.bytesize > MAXIMUM_BYTES

          text = validate_text(bytes)
          { path: relative(target), text:, revision: Digest::SHA256.hexdigest(text) }
        end
      rescue Errno::ELOOP
        raise ArgumentError, 'symlink traversal is not supported'
      end

      def check_revision(current, revision)
        return if current[:revision] == revision

        raise Conflict, 'file changed outside the editor; both versions are preserved'
      end

      def rename(source_parent, source_name, target_parent, target_name, no_replace: false)
        NativeRename.call(source_parent.fileno, source_name, target_parent.fileno, target_name, no_replace ? 1 : 0)
      rescue Errno::EEXIST
        raise Conflict, 'destination already exists'
      end

      def with_lock(&) = WriteLock.synchronize(root, &)
    end
  end
end
