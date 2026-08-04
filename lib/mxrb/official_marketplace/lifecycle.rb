# frozen_string_literal: true

module Mxrb
  module OfficialMarketplace
    # Immutable preview whose mutation is guarded by explicit apply and blockers.
    class LifecyclePlan
      attr_reader :action, :name, :installed_version, :target_version, :changes, :blockers

      # rubocop:disable Metrics/ParameterLists
      def initialize(action:, name:, installed_version:, target_version:, changes:, blockers:, &operation)
        @action = action
        @name = name
        @installed_version = installed_version
        @target_version = target_version
        @changes = changes.freeze
        @blockers = blockers.freeze
        @operation = operation
        @applied = false
      end
      # rubocop:enable Metrics/ParameterLists

      def safe? = blockers.empty?
      def applied? = @applied

      def apply!
        raise MarketplaceError, 'Marketplace lifecycle plan was already applied' if applied?
        raise MarketplaceError, "Marketplace lifecycle plan is blocked: #{blockers.join('; ')}" unless safe?

        @operation.call
        @applied = true
        self
      end
    end

    # Read-only view of a module package used to compare update boundaries.
    class ModulePackageInventory
      attr_reader :name, :version, :module_id, :unit_ids, :files

      def initialize(name:, version:, module_id:, unit_ids:, files:)
        @name = name
        @version = version
        @module_id = module_id
        @unit_ids = unit_ids.freeze
        @files = files.freeze
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def self.read(path)
        Dir.mktmpdir('mxrb-marketplace-inspect-') do |temporary|
          Zip::File.open(path) do |archive|
            reader = ModulePackageReader.new(archive)
            descriptor = reader.descriptor
            source_path = reader.extract_project(descriptor, temporary)
            staged = reader.stage_files(descriptor.files, temporary)
            source = IO::MprFile.open(source_path, readonly: true)
            module_unit = find_module(source, descriptor.name)
            raise MarketplaceError, "module #{descriptor.name.inspect} is absent from package MPR" unless module_unit

            ids = subtree_ids(source, module_unit.fetch('UnitID'))
            files = staged.transform_values { Digest::SHA256.file(_1).hexdigest }
            return new(
              name: descriptor.name, version: descriptor.version,
              module_id: module_unit.fetch('UnitID'), unit_ids: ids, files:
            )
          ensure
            source&.close
          end
        end
      rescue Zip::Error, REXML::ParseException => e
        raise MarketplaceError, "invalid Mendix module package: #{e.message}"
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def self.find_module(mpr, name)
        mpr.units_by_containment('Modules').find { mpr.parse_contents(_1)['Name'] == name }
      end

      def self.subtree_ids(mpr, root_id)
        ids = [root_id]
        loop do
          children = mpr.all_units.filter_map do |unit|
            unit.fetch('UnitID') if ids.include?(unit['ContainerID']) && !ids.include?(unit.fetch('UnitID'))
          end
          break if children.empty?

          ids.concat(children)
        end
        ids
      end
    end

    # Transactional lifecycle for modules already recorded in marketplace.lock.json.
    class Lifecycle # rubocop:disable Metrics/ClassLength
      def initialize(target:, mpr:, installer:)
        @target = File.expand_path(target)
        @mpr = mpr && File.expand_path(mpr)
        @installer = installer
      end

      def installed(identifier)
        pair = packages.find do |name, entry|
          name.casecmp(identifier.to_s).zero? || entry['content_id'].to_s == identifier.to_s
        end
        raise MarketplaceError, "Marketplace package #{identifier.inspect} is not installed" unless pair
        raise MarketplaceError, "Marketplace package #{pair.first.inspect} is not an imported module" \
          unless pair.last['kind'] == 'module'

        pair
      end

      def mpr_path(entry)
        path = safe_path(entry.fetch('destination'))
        raise MarketplaceError, 'selected MPR does not match the Marketplace lock' if @mpr && @mpr != path

        path
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def plan_remove(identifier)
        name, entry = installed(identifier)
        mpr = mpr_path(entry)
        ids = target_unit_ids(mpr, entry)
        inventory = cached_inventory(entry)
        shared = shared_files(name)
        blockers = base_blockers(entry, inventory, ids)
        blockers << "locked module name does not match cached package #{inventory.name}" if inventory.name != name
        blockers.concat(external_reference_blockers(mpr, ids))
        blockers.concat(modified_asset_blockers(inventory, name))
        removable = inventory.files.keys - shared
        changes = ["delete #{ids.size} MPR units", "delete #{removable.size} package assets",
                   'delete cached package and lock entry']
        LifecyclePlan.new(
          action: :remove, name:, installed_version: entry['version'], target_version: nil,
          changes:, blockers:
        ) { apply_remove(name, entry, mpr, ids, removable) }
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def plan_update(identifier, archive, package)
        name, entry = installed(identifier)
        mpr = mpr_path(entry)
        current_ids = target_unit_ids(mpr, entry)
        current = cached_inventory(entry)
        replacement = ModulePackageInventory.read(archive)
        missing_ids = current_ids - replacement.unit_ids
        blockers = base_blockers(entry, current, current_ids)
        blockers << "replacement module name changed from #{name} to #{replacement.name}" if replacement.name != name
        blockers << 'replacement module identity changed' if replacement.module_id != entry['module_id']
        blockers << "downloaded package version #{replacement.version} does not match #{package.version}" \
          unless package_version_matches?(replacement.version, package.version)
        blockers << "version #{package.version} is already installed" if package.version.to_s == entry['version'].to_s
        blockers.concat(external_reference_blockers(mpr, missing_ids))
        blockers.concat(modified_asset_blockers(current, name))
        obsolete = current.files.keys - replacement.files.keys - shared_files(name)
        changes = ["replace #{current_ids.size} MPR units with #{replacement.unit_ids.size}",
                   "install #{replacement.files.size} package assets",
                   "delete #{obsolete.size} obsolete package assets", 'replace cache and lock metadata']
        LifecyclePlan.new(
          action: :update, name:, installed_version: entry['version'], target_version: package.version,
          changes:, blockers:
        ) { apply_update(entry, mpr, current_ids, obsolete, archive, package, replacement) }
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

      def packages = OfficialMarketplace.lock(@target).fetch('packages')

      def safe_path(relative)
        path = File.expand_path(File.join(@target, relative.to_s))
        prefix = "#{@target}#{File::SEPARATOR}"
        raise MarketplaceError, "path is outside marketplace target: #{path}" unless path.start_with?(prefix)

        path
      end

      def cached_inventory(entry)
        archive = safe_path(entry.fetch('archive'))
        raise MarketplaceError, "cached Marketplace package is missing: #{archive}" unless File.file?(archive)

        ModulePackageInventory.read(archive)
      end

      def target_unit_ids(mpr_path, entry)
        raise MarketplaceError, "MPR not found: #{mpr_path}" unless File.file?(mpr_path)

        mpr = IO::MprFile.open(mpr_path, readonly: true)
        root = mpr.unit(entry.fetch('module_id'))
        raise MarketplaceError, "module #{entry.fetch('module_id')} is absent from target MPR" unless root

        ModulePackageInventory.subtree_ids(mpr, root.fetch('UnitID'))
      ensure
        mpr&.close
      end

      def base_blockers(entry, inventory, ids)
        blockers = []
        blockers << 'locked module identity does not match cached package' if inventory.module_id != entry['module_id']
        blockers << 'locked unit count does not match target module tree' if entry['units'].to_i != ids.size
        blockers
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def external_reference_blockers(mpr_path, ids)
        return [] if ids.empty?

        id_set = ids.map(&:downcase)
        mpr = IO::MprFile.open(mpr_path, readonly: true)
        mpr.all_units.filter_map do |unit|
          next if id_set.include?(unit.fetch('UnitID').downcase)

          document = mpr.parse_contents(unit)
          matches = id_set.select { JSON.generate(document).downcase.include?(_1) }
          next if matches.empty?

          "#{document['Name'] || document['$Type'] || unit.fetch('UnitID')} references " \
            "#{matches.size} unit(s) scheduled for removal"
        end
      ensure
        mpr&.close
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      def modified_asset_blockers(inventory, owner_name)
        shared = shared_files(owner_name)
        inventory.files.filter_map do |relative, expected|
          next if shared.include?(relative)

          path = safe_path(relative)
          actual = Digest::SHA256.file(path).hexdigest if File.file?(path) && !File.symlink?(path)
          "package asset changed or missing: #{relative}" unless actual == expected
        end
      end

      def shared_files(name)
        packages.filter_map do |other_name, entry|
          Array(entry['files']) unless other_name == name
        end.flatten.uniq
      end

      def package_version_matches?(manifest_version, official_version)
        value = manifest_version.to_s
        value.empty? || value == 'unknown' || value == official_version.to_s
      end

      def apply_remove(name, entry, mpr, ids, files)
        paths = lifecycle_paths(entry, mpr, files)
        with_rollback(paths) do
          delete_units(mpr, ids)
          restore_assets(entry, files)
          remove_atlas_variables if name == 'Atlas_Core'
          FileUtils.rm_f(safe_path(entry.fetch('archive')))
          delete_asset_backups(entry)
          delete_lock_entry(name)
        end
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
      def apply_update(entry, mpr, ids, obsolete, archive, package, replacement)
        new_cache = cache_path(replacement)
        files = (Array(entry['files']) + replacement.files.keys).uniq
        paths = lifecycle_paths(entry, mpr, files) + [new_cache]
        with_rollback(paths.uniq) do
          delete_units(mpr, ids)
          @installer.send(:import_module, archive, package, mpr)
          restore_assets(entry, obsolete)
          delete_asset_backups(entry, obsolete)
          old_cache = safe_path(entry.fetch('archive'))
          FileUtils.rm_f(old_cache) unless old_cache == new_cache
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists

      def delete_units(mpr_path, ids)
        mpr = IO::MprFile.open(mpr_path)
        mpr.transaction { ids.reverse_each { mpr.delete_unit(_1) } }
      ensure
        mpr&.close
      end

      def lifecycle_paths(entry, mpr, files)
        contents = File.join(File.dirname(mpr), 'mprcontents')
        lock = File.join(@target, '.mxrb', 'marketplace.lock.json')
        custom = File.join(@target, 'theme', 'web', 'custom-variables.scss')
        originals = File.join(@target, '.mxrb', 'marketplace-originals')
        [mpr, contents, lock, custom, originals, safe_path(entry.fetch('archive'))] + files.map { safe_path(_1) }
      end

      def cache_path(inventory)
        version = inventory.version.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
        File.join(@target, '.mxrb', 'marketplace', "#{inventory.name}-#{version}.mpk")
      end

      def with_rollback(paths)
        Dir.mktmpdir('mxrb-marketplace-rollback-') do |temporary|
          snapshots = []
          paths.uniq.each_with_index { |path, index| snapshots << snapshot(path, temporary, index) }
          yield
        rescue StandardError
          snapshots.reverse_each { restore_snapshot(_1) }
          raise
        end
      end

      def snapshot(path, temporary, index)
        backup = File.join(temporary, index.to_s)
        type = snapshot_type(path)
        FileUtils.cp_r(path, backup) if type == :directory
        FileUtils.cp(path, backup) if type == :file
        [path, backup, type]
      end

      def snapshot_type(path)
        return :directory if File.directory?(path)
        return :file if File.file?(path)

        :missing
      end

      def restore_snapshot(snapshot)
        path, backup, type = snapshot
        FileUtils.rm_rf(path) if File.directory?(path)
        FileUtils.rm_f(path) if File.file?(path)
        return if type == :missing

        FileUtils.mkdir_p(File.dirname(path))
        type == :directory ? FileUtils.cp_r(backup, path) : FileUtils.cp(backup, path)
      end

      def delete_lock_entry(name)
        path = File.join(@target, '.mxrb', 'marketplace.lock.json')
        lock = OfficialMarketplace.lock(@target)
        lock.fetch('packages').delete(name)
        @installer.send(:write_lock_atomically, path, lock)
      end

      def restore_assets(entry, files) # rubocop:disable Metrics/MethodLength
        originals = entry.fetch('asset_originals', {})
        files.each do |relative|
          destination = safe_path(relative)
          backup = originals[relative]
          if backup && File.file?(safe_path(backup))
            FileUtils.mkdir_p(File.dirname(destination))
            FileUtils.cp(safe_path(backup), destination)
          else
            FileUtils.rm_f(destination)
          end
        end
      end

      def delete_asset_backups(entry, files = nil)
        originals = entry.fetch('asset_originals', {})
        selected = files ? originals.slice(*files) : originals
        selected.each_value { FileUtils.rm_f(safe_path(_1)) if _1 }
      end

      def remove_atlas_variables
        path = File.join(@target, 'theme', 'web', 'custom-variables.scss')
        return unless File.file?(path)

        lines = File.readlines(path).reject { _1.strip == Installer::ATLAS_VARIABLES_IMPORT }
        File.write(path, lines.join)
      end
    end
  end
end
