# frozen_string_literal: true

module Mxrb
  module OfficialMarketplace
    Dependency = Data.define(:module_name, :package, :archive, :dependencies)
    WidgetDependency = Data.define(:package, :archive, :widget_ids, :required_ids)

    # Preview for a recursively verified dependency installation.
    class DependencyPlan
      attr_reader :root, :dependencies, :widget_dependencies, :blockers

      def initialize(root:, dependencies:, blockers:, widget_dependencies: [], &operation)
        @root = root
        @dependencies = dependencies.freeze
        @widget_dependencies = widget_dependencies.freeze
        @blockers = blockers.freeze
        @operation = operation
        @applied = false
      end

      def safe? = blockers.empty?
      def applied? = @applied

      def changes
        dependencies.map { "install #{_1.module_name} #{_1.package.version}" } +
          widget_dependencies.map { "install widget bundle #{_1.package.name} #{_1.package.version}" }
      end

      def apply!
        raise MarketplaceError, 'Marketplace dependency plan was already applied' if applied?
        raise MarketplaceError, "Marketplace dependency plan is blocked: #{blockers.join('; ')}" unless safe?
        raise MarketplaceError, 'Marketplace dependency preview expired; rerun with apply enabled' unless @operation

        apply_operation
      end

      def apply_resolved!
        raise MarketplaceError, 'Marketplace dependency plan was already applied' if applied?
        raise MarketplaceError, 'Marketplace dependency preview expired; rerun with apply enabled' unless @operation

        apply_operation
      end

      def apply_operation
        @operation.call
        @applied = true
        self
      end

      def expire!
        @operation = nil unless applied?
        self
      end
    end

    # Discovers dependencies from unresolved qualified references inside the
    # package MPR, then verifies Content API candidates against the MPK module.
    class DependencyResolver # rubocop:disable Metrics/ClassLength
      PLATFORM_MODULES = %w[System].freeze
      OFFICIAL_CONTENT_IDS = {
        'FeedbackModule' => 205_506,
        'DataWidgets' => 116_540,
        'Administration' => 23_513
      }.freeze
      DATA_WIDGET_PATTERN = /
        \Acom\.mendix\.widget\.web\.
        (?:datagrid|datagriddatefilter|datagriddropdownfilter|datagridnumberfilter|
        datagridtextfilter|dropdownsort|gallery|selectionhelper|treenode)\.
      /ix
      OFFICIAL_WIDGET_CONTENT_IDS = {
        DATA_WIDGET_PATTERN => 116_540,
        /\Acom\.mendix\.widget\.web\.combobox\.Combobox\z/i => 219_304
      }.freeze

      def initialize(target:, mpr:, installer:, api:, mendix_version:)
        @target = File.expand_path(target)
        @mpr = File.expand_path(mpr)
        @installer = installer
        @api = api
        @mendix_version = mendix_version
        @resolved = {}
        @visited = {}
        @blockers = []
        @project_modules = Mxrb.open(@mpr) { _1.modules.map(&:name) }
        @required_widget_ids = widget_ids(@mpr)
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def resolve(identifier, apply: false, apply_resolved: false)
        lifecycle = Lifecycle.new(target: @target, mpr: @mpr, installer: @installer)
        root, entry = lifecycle.installed(identifier)
        Dir.mktmpdir('mxrb-marketplace-dependencies-') do |temporary|
          @temporary = temporary
          visit(root, safe_path(entry.fetch('archive')))
          dependencies = @resolved.values.freeze
          widget_dependencies = resolve_widget_dependencies
          plan = DependencyPlan.new(
            root:, dependencies:, widget_dependencies:, blockers: @blockers.uniq
          ) do
            apply_dependencies(dependencies, widget_dependencies)
          end
          plan.apply! if apply
          plan.apply_resolved! if apply_resolved
          plan.expire! unless apply || apply_resolved
          return plan
        end
      ensure
        @temporary = nil
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def visit(module_name, archive)
        return if @visited[module_name]

        @visited[module_name] = true
        dependency_names(archive).each do |dependency_name|
          next if PLATFORM_MODULES.include?(dependency_name) || dependency_name == module_name
          next if @project_modules.include?(dependency_name) && !packages.key?(dependency_name)

          dependency = installed_dependency(dependency_name) || resolve_dependency(dependency_name)
          next unless dependency

          visit(dependency.module_name, dependency.archive)
          @resolved[dependency.module_name] ||= dependency unless installed?(dependency.module_name)
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def dependency_names(archive)
        Dir.mktmpdir('mxrb-marketplace-dependency-model-') do |temporary|
          project = extract_project(archive, temporary)
          @required_widget_ids.concat(widget_ids(project)).uniq!
          Mxrb.open(project) do |model|
            return model.analyze.unresolved_references.filter_map do |reference|
              reference.qualified_name.to_s.split(%r{[./]}, 2).first
            end.uniq.sort
          end
        end
      end

      def extract_project(archive_path, temporary)
        Zip::File.open(archive_path) do |archive|
          reader = ModulePackageReader.new(archive)
          descriptor = reader.descriptor
          reader.extract_project(descriptor, temporary)
        end
      rescue Zip::Error, REXML::ParseException => e
        raise MarketplaceError, "invalid Mendix dependency package: #{e.message}"
      end

      def installed_dependency(name)
        pair = packages.find { |module_name, _entry| module_name.casecmp(name).zero? }
        return unless pair

        module_name, entry = pair
        Dependency.new(module_name, nil, safe_path(entry.fetch('archive')), dependency_names_for(entry))
      end

      def dependency_names_for(entry)
        Array(entry['dependencies'])
      end

      def resolve_dependency(name) # rubocop:disable Metrics/MethodLength
        failures = []
        candidates(name).each do |content|
          package = resolve_candidate(content)
          next unless package

          archive = download_candidate(package)
          inventory = ModulePackageInventory.read(archive)
          next unless inventory.name == name

          dependencies = dependency_names(archive)
          return Dependency.new(name, package, archive, dependencies)
        rescue MarketplaceError => e
          failures << "#{name}: candidate #{content['contentId']} failed: #{e.message}"
        end
        @blockers.concat(failures)
        @blockers << "#{name}: no official Marketplace package matched the module identity"
        nil
      end

      def candidates(name)
        (official_candidates(name) + queries(name).flat_map { @api.search(name: _1, limit: 100) })
          .select { Installer::IMPORTABLE_CONTENT_TYPES.include?(_1['type']) }
          .uniq { _1['contentId'] }
      end

      def official_candidates(name)
        pair = OFFICIAL_CONTENT_IDS.find { |module_name, _content_id| module_name.casecmp(name).zero? }
        pair ? [@api.content(pair.last)] : []
      end

      def queries(name)
        humanized = name.gsub('_', ' ').gsub(/([a-z\d])([A-Z])/, '\\1 \\2')
        [humanized, name].uniq
      end

      def resolve_candidate(content)
        @api.resolve(content.fetch('contentId'), mendix_version: @mendix_version)
      end

      def download_candidate(package)
        destination = File.join(@temporary, "#{package.content_id}-#{package.version_id}.mpk")
        return destination if File.file?(destination)

        @api.download(package.version_id, destination, download_url: package.download_url)
      end

      def resolve_widget_dependencies # rubocop:disable Metrics/MethodLength
        missing = @required_widget_ids.reject { widget_installed?(_1) }
        grouped = missing.group_by { official_widget_content_id(_1) }
        Array(grouped.delete(nil)).each do |widget_id|
          @blockers << "#{widget_id}: no verified official Marketplace widget mapping"
        end
        grouped.filter_map do |content_id, required_ids|
          resolve_widget_dependency(content_id, required_ids)
        rescue MarketplaceError => e
          @blockers << "widget content #{content_id}: #{e.message}"
          nil
        end
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def resolve_widget_dependency(content_id, required_ids)
        if package_installed?(content_id)
          raise MarketplaceError,
                "locked official package is present but does not provide #{required_ids.join(', ')}"
        end

        existing = @resolved.values.find { _1.package&.content_id == content_id }
        package = existing&.package || @api.resolve(content_id, mendix_version: @mendix_version)
        @installer.validate_official_package!(package)
        archive = existing&.archive || download_candidate(package)
        inventory = WidgetBundleInventory.read(archive)
        missing = required_ids - inventory.widget_ids
        unless missing.empty?
          raise MarketplaceError,
                "downloaded package does not provide #{missing.join(', ')}"
        end

        WidgetDependency.new(package, archive, inventory.widget_ids, required_ids.sort)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def official_widget_content_id(widget_id)
        pair = OFFICIAL_WIDGET_CONTENT_IDS.find { |pattern, _content_id| pattern.match?(widget_id) }
        pair&.last
      end

      def widget_installed?(widget_id)
        !Mxrb::WidgetPackage.find(@target, widget_id).nil?
      end

      def widget_ids(mpr_path)
        Mxrb.open(mpr_path) do |model|
          model.all_units.flat_map do |unit|
            collect_widget_ids(model.parse_bson(unit))
          end.uniq.sort
        end
      end

      def collect_widget_ids(value)
        case value
        when Hash
          own = value['WidgetId'].to_s
          nested = value.values.flat_map { collect_widget_ids(_1) }
          own.empty? ? nested : [own] + nested
        when Array
          value.flat_map { collect_widget_ids(_1) }
        else
          []
        end
      end

      def apply_dependencies(dependencies, widget_dependencies) # rubocop:disable Metrics/MethodLength
        paths = rollback_paths(dependencies, widget_dependencies)
        lifecycle = Lifecycle.new(target: @target, mpr: @mpr, installer: @installer)
        lifecycle.send(:with_rollback, paths) do
          dependencies.each do |dependency|
            @installer.send(:import_module, dependency.archive, dependency.package, @mpr)
          end
          widget_dependencies.each do |dependency|
            next if package_installed?(dependency.package.content_id)

            @installer.send(:install_official_archive, dependency.archive, dependency.package, @mpr)
          end
        end
      end

      def rollback_paths(dependencies, widget_dependencies)
        archives = (dependencies + widget_dependencies).map(&:archive)
        assets = archives.flat_map { package_asset_paths(_1) }
        [
          @mpr, File.join(File.dirname(@mpr), 'mprcontents'),
          File.join(@target, '.mxrb', 'marketplace.lock.json'),
          File.join(@target, '.mxrb', 'marketplace'),
          File.join(@target, '.mxrb', 'marketplace-originals'),
          File.join(@target, 'theme', 'web', 'custom-variables.scss')
        ] + assets.map { safe_path(_1) }
      end

      def package_asset_paths(archive)
        return [File.join('widgets', WidgetPackageInventory.read(archive).project_filename)] \
          if PackageEnvelope.kind(archive) == :widget

        ModulePackageInventory.read(archive).files.keys
      end

      def package_installed?(content_id)
        packages.any? { |_name, entry| entry['content_id'].to_s == content_id.to_s }
      end

      def packages = OfficialMarketplace.lock(@target).fetch('packages')
      def installed?(name) = packages.key?(name)

      def safe_path(relative)
        path = File.expand_path(File.join(@target, relative.to_s))
        prefix = "#{@target}#{File::SEPARATOR}"
        raise MarketplaceError, "path is outside marketplace target: #{path}" unless path.start_with?(prefix)

        path
      end
    end
  end
end
