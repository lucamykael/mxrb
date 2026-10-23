# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'securerandom'
require 'sqlite3'
require 'tmpdir'
require_relative '../io/mpr_file'
require_relative 'files'

module Mxrb
  module Studio
    # A private, byte-preserving working copy of the saved native project.
    # SQLite's backup API includes committed WAL contents without opening the
    # source writable. Native unit payloads are copied without BSON conversion.
    # rubocop:disable Metrics
    class Snapshot
      ASSETS = %w[theme themesource widgets userlib javasource resources javascriptsource .mxrb].freeze
      attr_reader :source_model, :destination_root

      def initialize(source_model, destination_root:)
        @source_model = File.realpath(source_model)
        raise ArgumentError, 'source model must be a file' unless File.file?(@source_model)

        @destination_root = File.expand_path(destination_root)
      end

      def create
        validate_destination
        FileUtils.mkdir_p(destination_root)
        temporary = Dir.mktmpdir('.building-', destination_root)
        model_directory = File.join(temporary, 'model')
        Dir.mkdir(model_directory)
        destination = File.join(model_directory, File.basename(source_model))
        before = fingerprint(source_model)
        backup_database(destination)
        copy_storage(model_directory, before.fetch(:format))
        ASSETS.each { copy_entry(File.join(source_directory, _1), File.join(model_directory, _1)) }
        after = fingerprint(source_model)
        copied = fingerprint(destination)
        unless before == after && before == copied
          raise Conflict, 'saved model changed while its working copy was being created; retry snapshot'
        end

        identifier = "workspace-#{SecureRandom.hex(16)}"
        Files.new(destination_root).move(File.basename(temporary), destination: identifier)
        temporary = nil
        directory = File.join(destination_root, identifier)
        { root: directory, model: File.join(directory, 'model', File.basename(source_model)), source: source_model,
          format: before.fetch(:format).to_s, fingerprint: before.fetch(:digest), units: before.fetch(:units) }
      ensure
        FileUtils.remove_entry(temporary) if temporary && File.directory?(temporary)
      end

      private

      def source_directory = File.dirname(source_model)

      def validate_destination
        protected = (ASSETS + ['mprcontents', "#{File.basename(source_model)}.mprcontents"]).map do |name|
          File.join(source_directory, name)
        end
        candidate = canonical_parent(destination_root)
        return unless protected.any? { candidate == _1 || candidate.start_with?(_1 + File::SEPARATOR) }

        raise ArgumentError, 'snapshot destination cannot be inside source assets or native storage'
      end

      def canonical_parent(path)
        return File.realpath(path) if File.exist?(path)

        parent = File.dirname(path)
        raise ArgumentError, 'invalid snapshot destination' if parent == path

        File.join(canonical_parent(parent), File.basename(path))
      end

      def fingerprint(path)
        contents = File.join(File.dirname(path), 'mprcontents')
        reject_symlink(contents)
        reject_symlink(File.join(contents, 'mprname')) if File.directory?(contents)
        mpr = IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
        digest = Digest::SHA256.new
        mpr.query('BEGIN')
        reading = true
        rows = mpr.query('SELECT * FROM Unit ORDER BY hex(UnitID)')
        digest.update(Marshal.dump(rows))
        units = mpr.all_units.sort_by { _1.fetch('UnitID') }
        units.each do |unit|
          native_path = mpr.content_path(unit)
          reject_symlink_chain(contents, native_path) if native_path
          bytes = mpr.content_bytes(unit)
          raise IncompletePackageError, "unit #{unit.fetch('UnitID')} has no content bytes" unless bytes

          digest.update([bytes.bytesize].pack('Q<'))
          digest.update(bytes)
        end
        { format: mpr.format_version, digest: digest.hexdigest, units: units.length }
      ensure
        mpr.query('ROLLBACK') if reading
        mpr&.close
      end

      def reject_symlink(path)
        raise ArgumentError, 'snapshot does not follow native-storage symlinks' if File.symlink?(path)
      end

      def reject_symlink_chain(root, path)
        relative = path.delete_prefix(root + File::SEPARATOR)
        relative.split(File::SEPARATOR).reduce(root) do |parent, part|
          File.join(parent, part).tap { reject_symlink(_1) }
        end
      end

      def backup_database(destination)
        source_db = SQLite3::Database.new(source_model, flags: SQLite3::Constants::Open::READONLY)
        target_db = SQLite3::Database.new(destination)
        backup = SQLite3::Backup.new(target_db, 'main', source_db, 'main')
        status = backup.step(-1)
        unless status == SQLite3::Constants::ErrorCode::DONE
          raise Conflict, 'saved model is busy; retry snapshot after saving completes'
        end
      ensure
        backup&.finish
        target_db&.close
        source_db&.close
      end

      def copy_storage(destination, format)
        if format == :v2
          source = File.join(source_directory, 'mprcontents')
          copy_entry(source, File.join(destination, 'mprcontents'))
        end
        sidecar = "#{source_model}.mprcontents"
        copy_entry(sidecar, File.join(destination, "#{File.basename(source_model)}.mprcontents"))
      end

      def copy_entry(source, destination)
        return if File.basename(source) == '.git'
        return unless File.exist?(source)
        return if File.symlink?(source)

        File.open(source, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
          stat = input.stat
          if stat.directory?
            Dir.mkdir(destination)
            Dir.children("/proc/self/fd/#{input.fileno}").each do |name|
              copy_entry("/proc/self/fd/#{input.fileno}/#{name}", File.join(destination, name))
            end
          elsif stat.file?
            File.open(destination, File::WRONLY | File::CREAT | File::EXCL, stat.mode & 0o777) do |output|
              output.chmod(stat.mode & 0o777)
              ::IO.copy_stream(input, output)
            end
          end
        end
      rescue Errno::ELOOP
        # A regular asset was replaced with a symlink after enumeration.
        nil
      end
    end
    # rubocop:enable Metrics
  end
end
