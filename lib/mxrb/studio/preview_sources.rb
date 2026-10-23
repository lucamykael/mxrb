# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Mxrb
  module Studio
    # Copies and hashes source files through anchored directory handles. A
    # symlink is an unsupported dependency, never permission to leave the tree.
    class PreviewSources
      SKIPPED = %w[.git node_modules vendor .bundle coverage build deployment tmp].freeze
      MAXIMUM_FILES = 25_000
      MAXIMUM_BYTES = 512 * 1024 * 1024

      def initialize(root, context:)
        @root = File.realpath(root)
        @context = context
      end

      def revision(destination: nil)
        @files = 0
        @bytes = 0
        @digest = Digest::SHA256.new
        FileUtils.mkdir_p(destination) if destination
        File.open(@root, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |directory|
          visit(directory, '', destination)
        end
        @digest.hexdigest
      end

      private

      def visit(directory, relative, destination) # rubocop:disable Metrics/MethodLength
        anchored = "/proc/self/fd/#{directory.fileno}"
        Dir.children(anchored).sort.each do |name|
          @context.check!
          next if SKIPPED.include?(name) || name.start_with?('.mxrb-')

          path = relative.empty? ? name : "#{relative}/#{name}"
          File.open("#{anchored}/#{name}", File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
            visit_entry(input, path, destination && File.join(destination, name))
          end
        rescue Errno::ELOOP
          raise ArgumentError, "Ruby preview cannot follow source symlinks: #{path}"
        end
      end

      def visit_entry(input, relative, destination) # rubocop:disable Metrics/MethodLength
        stat = input.stat
        if stat.directory?
          FileUtils.mkdir_p(destination) if destination
          visit(input, relative, destination)
        elsif stat.file?
          @files += 1
          raise ArgumentError, 'Ruby preview exceeds 25000 source files' if @files > MAXIMUM_FILES

          @digest.update([relative.bytesize].pack('Q<')).update(relative)
          @digest.update([stat.size].pack('Q<'))
          copy_file(input, destination)
        else
          raise ArgumentError, "Ruby preview requires regular source files: #{relative}"
        end
      end

      def copy_file(input, destination)
        output = File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) if destination
        while (chunk = input.read(1024 * 1024))
          @context.check!
          @bytes += chunk.bytesize
          raise ArgumentError, 'Ruby preview exceeds 512 MiB of sources' if @bytes > MAXIMUM_BYTES

          @digest.update(chunk)
          output&.write(chunk)
        end
      ensure
        output&.close
      end
    end
  end
end
