# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'rexml/document'
require 'zip'

module Mxrb
  module OfficialMarketplace
    WidgetInstallation = Data.define(
      :package, :destination, :sha256, :widget_name, :widget_ids, :archive
    )

    # Validates the two official Marketplace package envelopes MXRB accepts.
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    class PackageEnvelope
      def self.kind(path)
        Zip::File.open(path) do |archive|
          package = archive.find_entry('package.xml')
          raise MarketplaceError, 'package.xml is missing' unless package

          document = REXML::Document.new(package.get_input_stream.read)
          names = document.root&.elements&.map(&:name) || []
          return :module if names.include?('modelerProject')
          return :widget if names.include?('clientModule')

          raise MarketplaceError, 'package.xml does not declare a module or widget'
        end
      rescue Zip::Error, REXML::ParseException => e
        raise MarketplaceError, "invalid Mendix package: #{e.message}"
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    # Read-only, fail-closed inventory for a clientModule MPK.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    class WidgetPackageInventory
      attr_reader :name, :version, :widget_ids, :project_filename

      def initialize(name:, version:, widget_ids:, project_filename:)
        @name = name
        @version = version
        @widget_ids = widget_ids.freeze
        @project_filename = project_filename
      end

      def self.read(path)
        Zip::File.open(path) do |archive|
          validate_entries!(archive)
          document = package_document(archive)
          clients = elements(document.root, 'clientModule')
          raise MarketplaceError, 'package.xml must declare exactly one clientModule' unless clients.one?

          client = clients.first

          name = valid_name(client.attributes['name'])
          version = valid_version(client.attributes['version'])
          widget_paths = elements(client, 'widgetFile').map do |element|
            safe_relative_path(element.attributes['path'])
          end.uniq
          raise MarketplaceError, 'widget package does not declare widgetFiles' if widget_paths.empty?

          validate_declared_files!(archive, client)
          widget_ids = widget_paths.map { widget_id(archive, _1) }
          filename = project_filename(name, widget_ids)
          new(name:, version:, widget_ids:, project_filename: filename)
        end
      rescue Zip::Error, REXML::ParseException => e
        raise MarketplaceError, "invalid Mendix widget package: #{e.message}"
      end

      class << self
        private

        def package_document(archive)
          package = archive.find_entry('package.xml')
          raise MarketplaceError, 'package.xml is missing' unless package

          REXML::Document.new(package.get_input_stream.read)
        end

        def validate_entries!(archive)
          normalized = {}
          archive.each do |entry|
            path = safe_relative_path(entry.name, directory: true)
            key = path.downcase
            raise MarketplaceError, "duplicate widget package path #{entry.name.inspect}" if normalized[key]
            raise MarketplaceError, "symbolic link in widget package: #{entry.name}" if entry.symlink?

            normalized[key] = true
          end
        end

        def validate_declared_files!(archive, client)
          elements(client, 'file').each do |element|
            relative = safe_relative_path(element.attributes['path'], directory: true)
            present = archive.any? do |entry|
              normalized = entry.name.to_s.tr('\\', '/').delete_suffix('/')
              normalized == relative || normalized.start_with?("#{relative}/")
            end
            raise MarketplaceError, "declared widget file is missing: #{relative}" unless present
          end
        end

        def widget_id(archive, relative)
          entry = archive.find_entry(relative) || archive.find_entry(relative.tr('/', '\\'))
          raise MarketplaceError, "declared widget definition is missing: #{relative}" unless entry&.file?

          root = REXML::Document.new(entry.get_input_stream.read).root
          value = root&.name == 'widget' ? root.attributes['id'].to_s : ''
          return value if value.match?(/\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+\z/)

          raise MarketplaceError, "invalid widget ID #{value.inspect} in #{relative}"
        end

        def project_filename(name, widget_ids)
          namespaces = widget_ids.map { _1.split('.')[0...-2] }.uniq
          raise MarketplaceError, 'widget definitions do not share one package namespace' unless namespaces.one?

          "#{(namespaces.first + [name]).join('.')}.mpk"
        end

        def valid_name(value)
          name = value.to_s
          return name if name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)

          raise MarketplaceError, "invalid clientModule name #{name.inspect}"
        end

        def valid_version(value)
          version = value.to_s
          return version if version.match?(/\A[0-9A-Za-z][0-9A-Za-z.+_-]*\z/)

          raise MarketplaceError, "invalid clientModule version #{version.inspect}"
        end

        def safe_relative_path(value, directory: false)
          path = value.to_s.tr('\\', '/').delete_suffix('/')
          parts = path.split('/')
          unsafe = path.empty? || path.start_with?('/') || parts.include?('..') || parts.include?('') ||
                   path.include?("\0")
          raise MarketplaceError, "unsafe widget package path #{value.inspect}" if unsafe
          if !directory && File.extname(path).downcase != '.xml'
            raise MarketplaceError, "widget definition is not XML: #{value.inspect}"
          end

          path
        end

        def elements(root, name)
          found = []
          root&.each_recursive { found << _1 if _1.is_a?(REXML::Element) && _1.name == name }
          found
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

    # Enumerates widget identities delivered either directly or as declared
    # assets of a modelerProject package such as Data Widgets.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    class WidgetBundleInventory
      attr_reader :kind, :widget_ids

      def initialize(kind:, widget_ids:)
        @kind = kind
        @widget_ids = widget_ids.freeze
      end

      def self.read(path)
        kind = PackageEnvelope.kind(path)
        return new(kind:, widget_ids: WidgetPackageInventory.read(path).widget_ids) if kind == :widget

        ModulePackageInventory.read(path)
        ids = Dir.mktmpdir('mxrb-widget-bundle-') do |temporary|
          Zip::File.open(path) do |archive|
            reader = ModulePackageReader.new(archive)
            descriptor = reader.descriptor
            descriptor.files.grep(%r{\Awidgets/[^/]+\.mpk\z}i).flat_map do |relative|
              entry = archive.find_entry(relative) || archive.find_entry(relative.tr('/', '\\'))
              destination = File.join(temporary, File.basename(relative))
              File.open(destination, 'wb') { ::IO.copy_stream(entry.get_input_stream, _1) }
              WidgetPackageInventory.read(destination).widget_ids
            end
          end
        end
        new(kind:, widget_ids: ids.uniq.sort)
      rescue Zip::Error, REXML::ParseException => e
        raise MarketplaceError, "invalid Mendix widget bundle: #{e.message}"
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # Installs an already authenticated official widget archive as one project-owned MPK.
    # rubocop:disable Metrics
    class WidgetPackageInstaller
      def initialize(target:)
        @target = File.expand_path(target)
      end

      def install(archive, package)
        validate_target!
        inventory = WidgetPackageInventory.read(archive)
        validate_identity!(inventory, package)
        digest = Digest::SHA256.file(archive).hexdigest
        destination = safe_path(File.join('widgets', inventory.project_filename))
        cache = safe_path(cache_relative(inventory, package))
        lock_path = safe_path(File.join('.mxrb', 'marketplace.lock.json'))
        current = validate_boundaries!(package, destination, cache, lock_path)
        install_transaction(
          archive, package, inventory, digest, destination, cache, lock_path, current
        )
      end

      private

      def validate_target!
        raise MarketplaceError, "Marketplace target not found: #{@target}" unless File.directory?(@target)
        raise MarketplaceError, "Marketplace target is a symbolic link: #{@target}" if File.symlink?(@target)
      end

      def validate_identity!(inventory, package)
        return if inventory.version == package.version.to_s

        raise MarketplaceError,
              "widget package version #{inventory.version} does not match Marketplace #{package.version}"
      end

      def validate_boundaries!(package, destination, cache, lock_path)
        ensure_no_symlink_components(destination)
        ensure_no_symlink_components(cache)
        ensure_no_symlink_components(lock_path)
        raise MarketplaceError, "widget destination is a symbolic link: #{destination}" if File.symlink?(destination)
        raise MarketplaceError, "widget destination is a directory: #{destination}" if File.directory?(destination)

        lock = OfficialMarketplace.lock(@target)
        current = lock.fetch('packages').find do |name, entry|
          name.casecmp(package.name.to_s).zero? ||
            entry['content_id'].to_s == package.content_id.to_s
        end
        validate_current!(current, package, destination)
        validate_asset_owners!(lock, destination) unless current
        unless !File.exist?(cache) || current&.last&.[]('archive') == relative(cache)
          raise MarketplaceError, "widget cache destination already exists: #{cache}"
        end

        current
      end

      def validate_current!(current, package, destination)
        return unless current

        name, entry = current
        raise MarketplaceError, "Marketplace package #{name.inspect} is not a widget" unless entry['kind'] == 'widget'
        unless entry['destination'] == relative(destination)
          raise MarketplaceError, "Marketplace widget #{name.inspect} changed its destination"
        end
        unless OfficialMarketplace.verify_widget(@target, entry)[:valid]
          raise MarketplaceError, "installed Marketplace widget #{name.inspect} failed verification"
        end
        return unless entry['version'].to_s == package.version.to_s

        raise MarketplaceError, "widget version #{package.version} is already installed"
      end

      def validate_asset_owners!(lock, destination)
        relative_path = relative(destination)
        owners = lock.fetch('packages').select do |_name, entry|
          Array(entry['files']).include?(relative_path)
        end
        return if owners.empty? || !File.file?(destination)

        expected = owners.filter_map { |_name, entry| locked_asset_digest(entry, relative_path) }.uniq
        actual = Digest::SHA256.file(destination).hexdigest
        return if expected.include?(actual)

        raise MarketplaceError, "owned widget asset changed: #{relative_path}"
      end

      def locked_asset_digest(entry, relative_path)
        return entry['sha256'] if entry['kind'] == 'widget' && entry['destination'] == relative_path
        return unless entry['kind'] == 'module'

        archive = safe_path(entry.fetch('archive'))
        raise MarketplaceError, "cached Marketplace package is missing: #{archive}" unless File.file?(archive)

        ModulePackageInventory.read(archive).files[relative_path]
      end

      def install_transaction(archive, package, inventory, digest, destination, cache, lock_path, current)
        original = current&.last&.[]('asset_original')
        backup = original ? safe_path(original) : backup_path(package, destination)
        old_cache = safe_path(current.last.fetch('archive')) if current
        paths = [destination, cache, lock_path, backup, old_cache].compact.uniq
        with_rollback(paths) do
          preserve_original(destination, backup) unless original
          atomic_copy(archive, destination)
          atomic_copy(archive, cache)
          verify_copy!(destination, digest)
          verify_copy!(cache, digest)
          write_lock(
            lock_path, package, inventory, digest, destination, cache,
            asset_original: File.file?(backup) ? relative(backup) : nil,
            replaced_name: current&.first
          )
          FileUtils.rm_f(old_cache) if old_cache && old_cache != cache
        end
        WidgetInstallation.new(package, destination, digest, inventory.name, inventory.widget_ids, cache)
      end

      def preserve_original(destination, backup)
        return unless File.file?(destination)

        FileUtils.mkdir_p(File.dirname(backup))
        FileUtils.cp(destination, backup)
      end

      def backup_path(package, destination)
        owner = "Widget-#{package.content_id || package.name.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')}"
        safe_path(File.join('.mxrb', 'marketplace-originals', owner, relative(destination)))
      end

      def atomic_copy(source, destination)
        temporary = "#{destination}.tmp-#{Process.pid}"
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, temporary)
        File.rename(temporary, destination)
      ensure
        FileUtils.rm_f(temporary)
      end

      def verify_copy!(path, digest)
        return if Digest::SHA256.file(path).hexdigest == digest

        raise MarketplaceError, "widget package checksum mismatch: #{path}"
      end

      def write_lock(path, package, inventory, digest, destination, cache,
                     asset_original:, replaced_name: nil)
        lock = OfficialMarketplace.lock(@target)
        lock.fetch('packages').delete(replaced_name) if replaced_name && replaced_name != package.name
        lock.fetch('packages')[package.name] = {
          'kind' => 'widget', 'version' => package.version, 'source' => package.source,
          'repository' => package.repository, 'sha256' => digest,
          'destination' => relative(destination), 'archive' => relative(cache),
          'files' => [relative(destination)], 'asset_original' => asset_original,
          'widget_name' => inventory.name, 'widget_ids' => inventory.widget_ids,
          'content_id' => package.content_id, 'version_id' => package.version_id,
          'content_type' => package.content_type, 'version_type' => package.version_type,
          'security_issues' => package.security_issues, 'private' => package.private,
          'company_approved' => package.company_approved
        }.compact
        temporary = "#{path}.tmp-#{Process.pid}"
        FileUtils.mkdir_p(File.dirname(path))
        File.write(temporary, JSON.pretty_generate(lock) << "\n")
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary)
      end

      def with_rollback(paths)
        Dir.mktmpdir('mxrb-widget-rollback-') do |temporary|
          snapshots = paths.each_with_index.map { |path, index| snapshot(path, temporary, index) }
          yield
        rescue StandardError
          snapshots.reverse_each { restore_snapshot(_1) }
          raise
        end
      end

      def snapshot(path, temporary, index)
        backup = File.join(temporary, index.to_s)
        type = File.file?(path) ? :file : :missing
        FileUtils.cp(path, backup) if type == :file
        [path, backup, type]
      end

      def restore_snapshot(snapshot)
        path, backup, type = snapshot
        FileUtils.rm_f(path)
        return if type == :missing

        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.cp(backup, path)
      end

      def cache_relative(inventory, package)
        version = package.version.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
        stem = File.basename(inventory.project_filename, '.mpk')
        File.join('.mxrb', 'marketplace', "#{stem}-#{version}.mpk")
      end

      def safe_path(relative)
        path = File.expand_path(File.join(@target, relative))
        prefix = "#{@target}#{File::SEPARATOR}"
        raise MarketplaceError, "path is outside marketplace target: #{path}" unless path.start_with?(prefix)

        path
      end

      def relative(path) = path.delete_prefix("#{@target}#{File::SEPARATOR}")

      def ensure_no_symlink_components(path)
        current = @target
        relative(path).split(File::SEPARATOR)[0...-1].each do |part|
          current = File.join(current, part)
          raise MarketplaceError, "widget destination traverses a symbolic link: #{current}" if File.symlink?(current)
        end
      end
    end
    # rubocop:enable Metrics
  end
end
