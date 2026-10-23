# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'ripper'
require 'securerandom'
require 'tmpdir'
require_relative '../../mxrb'
require_relative 'snapshot'

module Mxrb
  module Studio
    # A saved native project and its Ruby representation are two explorers of
    # the same identity. Discovery inspects Ruby syntax; it never evaluates it.
    class RubyProject # rubocop:disable Metrics/ClassLength
      MAXIMUM_SOURCE_BYTES = 4 * 1024 * 1024
      attr_reader :source_model, :state_root

      def initialize(source_model, state_root:)
        @source_model = File.realpath(source_model)
        raise ArgumentError, 'source model must be a file' unless File.file?(@source_model)

        @state_root = File.expand_path(state_root)
      end

      def status
        with_lock { current_status }
      end

      def attach(root:)
        with_lock do
          candidate = validate_root(root)
          persist(candidate, discovered: false)
          representation(candidate, discovered: false)
        end
      end

      def convert(model: nil)
        with_lock do
          existing = current_status
          return existing if existing.fetch(:state) == 'ready'

          export_model = File.realpath(model || source_model)
          unless project_id(export_model) == project_id(source_model)
            raise ArgumentError, 'conversion model belongs to a different Mendix project'
          end

          create_conversion(export_model, snapshot: model.nil?)
        end
      end

      private

      def source_key = Digest::SHA256.hexdigest(source_model)
      def bindings_root = File.join(state_root, 'ruby-projects')
      def binding_path = File.join(bindings_root, "#{source_key}.json")

      def current_status # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        binding = read_binding
        if binding && binding['source_model'] == source_model && binding['project_id'] == project_id(source_model)
          candidate = valid_root(binding['root'])
          return representation(candidate, discovered: binding['discovered'] == true) if candidate
        end
        discovery_roots.each do |root|
          candidate = valid_root(root)
          next unless candidate

          persist(candidate, discovered: true)
          return representation(candidate, discovered: true)
        end
        { source_model:, root: nil, entrypoint: nil, state: 'missing', discovered: false }
      end

      def read_binding
        return unless File.file?(binding_path)

        value = JSON.parse(File.read(binding_path))
        value if value.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def discovery_roots
        directory = File.dirname(source_model)
        roots = [directory, File.join(directory, 'ruby')]
        roots << File.join(File.dirname(directory), 'ruby') if File.basename(directory) == 'model'
        roots.uniq
      end

      def valid_root(root)
        validate_root(root)
      rescue ArgumentError, Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def validate_root(root) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        raise ArgumentError, 'Ruby project root must be a directory path' unless root.is_a?(String) && !root.empty?

        candidate = File.realpath(root)
        raise ArgumentError, 'Ruby project root must be a directory' unless File.directory?(candidate)

        entrypoint = File.realpath(File.join(candidate, 'project.rb'))
        unless File.file?(entrypoint) && entrypoint.start_with?(candidate + File::SEPARATOR)
          raise ArgumentError, 'Ruby entrypoint must be inside the selected project'
        end
        unless ruby_project_id(entrypoint) == project_id(source_model)
          raise ArgumentError, 'Ruby project identity does not match the native Mendix project'
        end

        candidate
      end

      def project_id(model)
        mpr = IO::MprFile.open(model, readonly: true, apply_studio_compatibility: false)
        mpr.root_unit.fetch('UnitID').downcase
      ensure
        mpr&.close
      end

      def ruby_project_id(path)
        source = File.read(path, MAXIMUM_SOURCE_BYTES + 1, encoding: Encoding::UTF_8)
        raise ArgumentError, 'Ruby entrypoint exceeds 4 MiB' if source.bytesize > MAXIMUM_SOURCE_BYTES

        syntax = Ripper.sexp(source)
        raise ArgumentError, 'Ruby entrypoint has invalid syntax' unless syntax

        declarations = []
        collect_declarations(syntax, declarations)
        return declarations.first if declarations.length == 1 && declarations.first&.match?(IO::BsonCodec::UUID_PATTERN)

        raise ArgumentError, 'Ruby entrypoint needs one literal mendix_project_id declaration'
      end

      def collect_declarations(syntax, declarations)
        remaining = [syntax]
        until remaining.empty?
          node = remaining.pop
          arguments = declaration_arguments(node)
          declarations << literal_identity(arguments) if arguments
          remaining.concat(node.select { _1.is_a?(Array) })
        end
      end

      def declaration_arguments(node)
        case node[0]
        when :command
          node[2] if node.dig(1, 1) == 'mendix_project_id'
        when :method_add_arg
          call = node[1]
          return unless call[0] == :fcall && call.dig(1, 1) == 'mendix_project_id'

          node.dig(2, 1) # Ripper wraps call arguments in :arg_paren
        end
      end

      def literal_identity(arguments)
        return unless arguments[1]&.length == 1

        content = arguments.dig(1, 0, 1)
        return unless content.is_a?(Array) && content[0] == :string_content && content.length == 2 &&
                      content.dig(1, 0) == :@tstring_content

        content[1][1].downcase
      end

      def create_conversion(export_model, snapshot:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        conversions = File.join(state_root, 'ruby-conversions')
        FileUtils.mkdir_p(conversions, mode: 0o700)
        owned = Dir.mktmpdir('ruby-', conversions)
        root = File.join(owned, 'ruby')
        if snapshot
          copy = Snapshot.new(export_model, destination_root: File.join(owned, 'snapshot')).create
          export_model = copy.fetch(:model)
        end
        Exporter.new(export_model, root, mode: :mendix).export!(parallel: false)
        validate_root(root)
        result = representation(root, discovered: false)
        persist(root, discovered: false)
        owned = nil
        result
      ensure
        FileUtils.remove_entry(owned) if owned && File.directory?(owned)
      end

      def representation(root, discovered:)
        { source_model:, root:, entrypoint: File.realpath(File.join(root, 'project.rb')), state: 'ready', discovered: }
      end

      def persist(root, discovered:) # rubocop:disable Metrics/AbcSize
        data = { version: 1, source_model:, project_id: project_id(source_model), root:, discovered: }
        temporary = File.join(bindings_root, ".#{source_key}-#{SecureRandom.hex(12)}.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(data))
          file.flush
          file.fsync
        end
        File.rename(temporary, binding_path)
      ensure
        File.unlink(temporary) if temporary && File.exist?(temporary)
      end

      def with_lock
        FileUtils.mkdir_p(bindings_root, mode: 0o700)
        File.open(File.join(bindings_root, "#{source_key}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end
  end
end
