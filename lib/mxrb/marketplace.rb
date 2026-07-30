# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "tmpdir"
require "uri"

module Mxrb
  module Marketplace
    Entry = Data.define(:name, :version, :description, :source, :ref)
    Installation = Data.define(:entry, :module_name, :destination, :digest)

    class Catalog
      DEFAULT_PATH = File.expand_path("../../marketplace/catalog.json", __dir__)

      def initialize(source = nil)
        @source = source || DEFAULT_PATH
      end

      def entries
        @entries ||= begin
          payload = JSON.parse(read_source)
          Array(payload.fetch("modules")).map do |item|
            Entry.new(
              item.fetch("name"), item.fetch("version"),
              item.fetch("description", ""), item.fetch("source"),
              item["ref"]
            )
          end.freeze
        rescue JSON::ParserError, KeyError => e
          raise MarketplaceError, "invalid marketplace catalog: #{e.message}"
        end
      end

      def search(query = nil)
        term = query.to_s.downcase
        return entries if term.empty?

        entries.select do |entry|
          [entry.name, entry.description].any? { _1.downcase.include?(term) }
        end
      end

      def find(name)
        entries.find { _1.name == name.to_s } ||
          raise(MarketplaceError, "module #{name.inspect} was not found in the catalog")
      end

      def find_version(name, version)
        entries.find { _1.name == name.to_s && _1.version == version.to_s } ||
          raise(MarketplaceError, "module #{name.inspect} version #{version.inspect} was not found in the catalog")
      end

      private

      def read_source
        uri = URI.parse(@source.to_s)
        return File.read(@source) unless uri.is_a?(URI::HTTP)
        raise MarketplaceError, "marketplace catalogs must use HTTPS" unless uri.is_a?(URI::HTTPS)

        response = Net::HTTP.get_response(uri)
        raise MarketplaceError, "catalog request failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body
      rescue URI::InvalidURIError, Errno::ENOENT => e
        raise MarketplaceError, "cannot read marketplace catalog: #{e.message}"
      end
    end

    class Installer
      MANIFEST = "mxrb-module.json"

      def initialize(target:, catalog: Catalog.new)
        @target = File.expand_path(target)
        @catalog = catalog
      end

      def install(identifier, version: nil)
        install_package(identifier, version: version, replace: false)
      end

      def update(identifier, version: nil)
        installed_module_name = resolve_installed_module_name(identifier)
        install_package(
          identifier,
          version: version,
          replace: true,
          installed_module_name: installed_module_name
        )
      end

      def remove(identifier)
        module_name = resolve_installed_module_name(identifier)
        destination = File.join(@target, "modules", module_name)
        FileUtils.rm_rf(destination) if File.exist?(destination)
        remove_from_lock(module_name)
        module_name
      end

      private

      def install_package(identifier, version:, replace:, installed_module_name: nil)
        entry, source = resolve(identifier, version: version)
        Dir.mktmpdir("mxrb-module-") do |workspace|
          package = materialize(source, entry, workspace)
          manifest = load_manifest(package)
          module_name = valid_name(manifest.fetch("module_name"))
          destination = File.join(@target, "modules", module_name)
          if installed_module_name && module_name != installed_module_name
            raise MarketplaceError,
                  "module update cannot change its name from #{installed_module_name.inspect} to #{module_name.inspect}"
          end
          if File.exist?(destination) && !replace
            raise MarketplaceError, "module destination already exists: #{destination}"
          end

          files = package_files(package, manifest)
          staging = File.join(@target, ".mxrb", "staging", "#{module_name}-#{Process.pid}")
          backup = nil
          FileUtils.mkdir_p(staging)
          files.each { copy_entry(package, staging, _1) }
          if replace && File.exist?(destination)
            backup = File.join(@target, ".mxrb", "backup", "#{module_name}-#{Process.pid}")
            FileUtils.mkdir_p(File.dirname(backup))
            FileUtils.mv(destination, backup)
          end
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.mv(staging, destination)
          FileUtils.rm_rf(backup) if backup
          backup = nil
          digest = tree_digest(destination)
          write_lock(entry, module_name, digest)
          Installation.new(entry, module_name, destination, digest)
        rescue StandardError
          FileUtils.mv(backup, destination) if backup && File.exist?(backup) && !File.exist?(destination)
          raise
        ensure
          FileUtils.rm_rf(staging) if staging && File.exist?(staging)
          FileUtils.rm_rf(backup) if backup && File.exist?(backup)
        end
      rescue KeyError, JSON::ParserError => e
        raise MarketplaceError, "invalid module manifest: #{e.message}"
      end

      def resolve(identifier, version: nil)
        path = File.expand_path(identifier.to_s)
        return [local_entry(path), path] if File.directory?(path)

        entry = version ? @catalog.find_version(identifier, version) : @catalog.find(identifier)
        [entry, entry.source]
      end

      def resolve_installed_module_name(identifier)
        lock_path = File.join(@target, ".mxrb", "modules.lock.json")
        raise MarketplaceError, "no modules are installed (lock file missing)" unless File.file?(lock_path)

        lock = JSON.parse(File.read(lock_path))
        locked = lock.fetch("modules", {})
        entry = locked.find { |_name, info| info["package"] == identifier.to_s }
        unless entry
          candidates = locked.select { |name, _| name.downcase == identifier.to_s.downcase }
          entry = candidates.first
        end
        raise MarketplaceError, "module #{identifier.inspect} is not installed" unless entry

        entry.first
      end

      def remove_from_lock(module_name)
        lock_path = File.join(@target, ".mxrb", "modules.lock.json")
        return unless File.file?(lock_path)

        lock = JSON.parse(File.read(lock_path))
        lock.fetch("modules", {}).delete(module_name)
        temporary = "#{lock_path}.tmp-#{Process.pid}"
        File.write(temporary, JSON.pretty_generate(lock) << "\n")
        File.rename(temporary, lock_path)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
      end

      def local_entry(path)
        Entry.new(File.basename(path), "local", "Local MXRB module", path, nil)
      end

      def materialize(source, entry, workspace)
        return builtin_path(source) if source.start_with?("builtin:")
        return File.expand_path(source) if File.directory?(source)

        destination = File.join(workspace, "repository")
        command = ["git", "clone", "--depth", "1"]
        command += ["--branch", entry.ref] if entry.ref
        command += [source, destination]
        output, status = Open3.capture2e(*command)
        raise MarketplaceError, "could not fetch #{entry.name}: #{output}" unless status.success?

        destination
      end

      def builtin_path(source)
        slug = source.delete_prefix("builtin:")
        unless slug.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
          raise MarketplaceError, "invalid built-in module slug #{slug.inspect}"
        end
        path = File.expand_path("../../marketplace/modules/#{slug}", __dir__)
        raise MarketplaceError, "built-in module #{slug.inspect} is unavailable" unless File.directory?(path)

        path
      end

      def load_manifest(package)
        JSON.parse(File.read(File.join(package, MANIFEST)))
      rescue Errno::ENOENT => e
        raise MarketplaceError, "module manifest is missing: #{e.message}"
      end

      def valid_name(value)
        name = value.to_s
        unless name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)
          raise MarketplaceError, "invalid module name #{name.inspect}"
        end

        name
      end

      def package_files(package, manifest)
        files = Array(manifest["files"] || Dir.children(package) - [MANIFEST])
        raise MarketplaceError, "module package has no files" if files.empty?

        files.each do |relative|
          path = Pathname.new(relative.to_s)
          if path.absolute? || path.each_filename.any? { _1 == ".." }
            raise MarketplaceError, "unsafe module path #{relative.inspect}"
          end
          raise MarketplaceError, "module file is missing: #{relative}" unless File.exist?(File.join(package, relative))
        end
        files
      end

      def copy_entry(package, staging, relative)
        source = File.join(package, relative)
        destination = File.join(staging, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp_r(source, destination)
      end

      def tree_digest(path)
        digest = Digest::SHA256.new
        Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.each do |file|
          next unless File.file?(file)

          digest << file.delete_prefix("#{path}/") << "\0" << File.binread(file)
        end
        digest.hexdigest
      end

      def write_lock(entry, module_name, digest)
        lock_path = File.join(@target, ".mxrb", "modules.lock.json")
        FileUtils.mkdir_p(File.dirname(lock_path))
        lock = File.file?(lock_path) ? JSON.parse(File.read(lock_path)) : { "modules" => {} }
        lock["modules"][module_name] = {
          "package" => entry.name, "version" => entry.version,
          "source" => entry.source, "ref" => entry.ref, "sha256" => digest
        }.compact
        temporary = "#{lock_path}.tmp-#{Process.pid}"
        File.write(temporary, JSON.pretty_generate(lock) << "\n")
        File.rename(temporary, lock_path)
      ensure
        FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
      end
    end
  end
end
