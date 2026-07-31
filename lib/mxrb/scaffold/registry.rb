# frozen_string_literal: true

require 'digest'
require 'json'

module Mxrb
  module Scaffold
    Removal = Data.define(:key, :files)

    # Records generated files so scaffold removal never relies on guessing paths.
    class Registry
      RELATIVE_PATH = File.join('.mxrb', 'scaffolds.json')

      def self.stage(transaction, root:, key:, files:) # rubocop:disable Metrics/MethodLength
        path = File.join(root, RELATIVE_PATH)
        payload = transaction.content(path) ? JSON.parse(transaction.content(path)) : { 'scaffolds' => {} }
        payload['scaffolds'][key] = {
          'files' => files.map do |file|
            { 'path' => file.delete_prefix("#{root}/"),
              'sha256' => Digest::SHA256.hexdigest(transaction.content(file)) }
          end
        }
        transaction.write(path, JSON.pretty_generate(payload) << "\n")
        path
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid scaffold registry: #{e.message}"
      end

      def initialize(root)
        @root = File.expand_path(root)
        @path = File.join(@root, RELATIVE_PATH)
      end

      def entries
        return {} unless File.file?(@path)

        JSON.parse(File.read(@path)).fetch('scaffolds', {})
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid scaffold registry: #{e.message}"
      end

      def remove(key)
        registry = entries
        entry = registry.fetch(key) { raise ArgumentError, "scaffold not registered: #{key}" }
        paths = entry.fetch('files').map { safe_path(_1.fetch('path')) }
        verify_unchanged!(entry.fetch('files'), paths)
        paths.each { FileUtils.rm_f(_1) }
        registry.delete(key)
        write('scaffolds' => registry)
        Removal.new(key, paths.freeze)
      end

      private

      def safe_path(relative)
        path = File.expand_path(File.join(@root, relative))
        prefix = "#{@root}#{File::SEPARATOR}"
        raise ArgumentError, "unsafe scaffold path: #{relative}" unless path.start_with?(prefix)

        path
      end

      def verify_unchanged!(files, paths)
        files.zip(paths).each do |entry, path|
          actual = File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
          next if actual == entry['sha256']

          raise ArgumentError, "refusing to remove changed scaffold file: #{path}"
        end
      end

      def write(payload)
        FileUtils.mkdir_p(File.dirname(@path))
        temporary = "#{@path}.tmp-#{Process.pid}"
        File.write(temporary, JSON.pretty_generate(payload) << "\n")
        File.rename(temporary, @path)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
      end
    end
  end
end
