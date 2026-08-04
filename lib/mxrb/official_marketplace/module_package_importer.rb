# frozen_string_literal: true

require 'fileutils'
require 'rexml/document'
require 'tmpdir'
require 'zip'

module Mxrb
  module OfficialMarketplace
    # Parses and safely stages a Mendix module package archive.
    class ModulePackageReader
      Descriptor = Data.define(:name, :version, :model_version, :project_file, :files)

      def initialize(archive)
        @archive = archive
      end

      def descriptor
        package_xml = @archive.find_entry('package.xml')
        raise MarketplaceError, 'package.xml is missing' unless package_xml

        document = REXML::Document.new(package_xml.get_input_stream.read)
        build_descriptor(document, parse_manifest)
      end

      def extract_project(descriptor, temporary)
        entry = @archive.find_entry(descriptor.project_file)
        raise MarketplaceError, "package project not found: #{descriptor.project_file}" unless entry

        copy_entry(entry, File.join(temporary, 'source.mpr'))
      end

      def stage_files(files, temporary)
        root = File.join(temporary, 'assets')
        files.to_h do |relative|
          entry = @archive.find_entry(relative) || @archive.find_entry(relative.tr('/', '\\'))
          raise MarketplaceError, "declared package file is missing: #{relative}" unless entry&.file?

          [relative, copy_entry(entry, File.join(root, relative))]
        end
      end

      private

      # Package metadata is intentionally validated as one boundary.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def build_descriptor(document, manifest)
        module_element = element(document, 'module')
        project_element = element(document, 'projectFile')
        raise MarketplaceError, 'package does not contain a Mendix module' unless module_element
        raise MarketplaceError, 'package does not declare project.mpr' unless project_element

        name = valid_module_name(module_element.attributes['name'])
        validate_package_type!(manifest.dig('package', 'type'))
        Descriptor.new(
          name, manifest.dig('package', 'version') || 'unknown', manifest['model-version'],
          safe_relative_path(project_element.attributes['path']),
          elements(document, 'file').map { safe_relative_path(_1.attributes['path']) }.uniq
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def valid_module_name(value)
        name = value.to_s
        return name if name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)

        raise MarketplaceError, "invalid module name #{name.inspect}"
      end

      def validate_package_type!(value)
        package_type = value.to_s
        return if package_type.empty? || package_type.casecmp('Module').zero?

        raise MarketplaceError, "unsupported marketplace package type #{package_type.inspect}"
      end

      def parse_manifest
        entry = @archive.find_entry('manifest.json')
        entry ? JSON.parse(entry.get_input_stream.read) : {}
      rescue JSON::ParserError => e
        raise MarketplaceError, "invalid module manifest: #{e.message}"
      end

      def elements(document, name)
        found = []
        document.root&.each_recursive { found << _1 if _1.is_a?(REXML::Element) && _1.name == name }
        found
      end

      def element(document, name) = elements(document, name).first

      def safe_relative_path(value)
        path = value.to_s.tr('\\', '/')
        parts = path.split('/')
        unsafe = path.empty? || path.start_with?('/') || parts.include?('..') || parts.include?('')
        raise MarketplaceError, "unsafe package path #{value.inspect}" if unsafe
        raise MarketplaceError, "protected package path #{value.inspect}" if protected_path?(parts)

        parts.join('/')
      end

      def protected_path?(parts)
        %w[.git .mxrb mprcontents].include?(parts.first.downcase) ||
          parts.last.downcase.end_with?('.mpr') && parts.length > 1
      end

      def copy_entry(entry, destination)
        FileUtils.mkdir_p(File.dirname(destination))
        File.open(destination, 'wb') { ::IO.copy_stream(entry.get_input_stream, _1) }
        destination
      end
    end

    # Installs declared package files with rollback support.
    class ModulePackageAssets
      def initialize(target_root, temporary)
        @target_root = target_root
        @backup_root = File.join(temporary, 'backups')
        @changes = []
      end

      def install(staged_files, protected_files = [])
        staged_files.each do |relative, source|
          install_file(relative, source) unless protected_files.include?(relative)
        end
      end

      def rollback
        @changes.reverse_each do |destination, backup|
          backup ? FileUtils.cp(backup, destination) : FileUtils.rm_f(destination)
        end
      end

      private

      def install_file(relative, source)
        destination = safe_destination(relative)
        raise MarketplaceError, "asset destination is a symbolic link: #{relative}" if File.symlink?(destination)
        raise MarketplaceError, "asset destination is a directory: #{relative}" if File.directory?(destination)

        backup = backup_file(relative, destination)
        @changes << [destination, backup]
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination)
      end

      def safe_destination(relative)
        destination = File.expand_path(File.join(@target_root, relative))
        prefix = "#{@target_root}#{File::SEPARATOR}"
        raise MarketplaceError, "unsafe asset destination: #{relative}" unless destination.start_with?(prefix)

        destination
      end

      def backup_file(relative, destination)
        return unless File.file?(destination)

        backup = File.join(@backup_root, relative)
        FileUtils.mkdir_p(File.dirname(backup))
        FileUtils.cp(destination, backup)
        backup
      end
    end

    # Imports a Mendix module package directly into an MPR without Studio Pro.
    class ModulePackageImporter # rubocop:disable Metrics/ClassLength
      Result = Data.define(
        :module_name, :package_version, :module_id, :units, :files,
        :source_version, :target_version
      )

      def initialize(package_path, mpr_path, target_root: nil, allow_model_upgrade: false,
                     protected_files: [])
        @package_path = File.expand_path(package_path)
        @mpr_path = File.expand_path(mpr_path)
        @target_root = File.expand_path(target_root || File.dirname(@mpr_path))
        @allow_model_upgrade = allow_model_upgrade
        @protected_files = protected_files
      end

      def import!
        validate_inputs!
        Dir.mktmpdir('mxrb-module-import-') do |temporary|
          Zip::File.open(@package_path) { import_archive(_1, temporary) }
        end
      rescue Zip::Error, REXML::ParseException => e
        raise MarketplaceError, "invalid Mendix module package: #{e.message}"
      end

      private

      def import_archive(archive, temporary)
        reader = ModulePackageReader.new(archive)
        descriptor = reader.descriptor
        source_path = reader.extract_project(descriptor, temporary)
        staged_files = reader.stage_files(descriptor.files, temporary)
        import_project(source_path, descriptor, staged_files, temporary)
      end

      def validate_inputs!
        raise MarketplaceError, "package not found: #{@package_path}" unless File.file?(@package_path)
        raise MarketplaceError, "MPR not found: #{@mpr_path}" unless File.file?(@mpr_path)
        raise MarketplaceError, "target root not found: #{@target_root}" unless File.directory?(@target_root)
      end

      def import_project(source_path, descriptor, staged_files, temporary) # rubocop:disable Metrics/MethodLength
        source = IO::MprFile.open(source_path, readonly: true)
        target = IO::MprFile.open(@mpr_path)
        assets = ModulePackageAssets.new(@target_root, temporary)
        imported_ids = []
        import_transaction(source, target, descriptor, staged_files, assets, imported_ids)
        import_result(source, target, descriptor, staged_files, imported_ids)
      rescue StandardError
        assets&.rollback
        cleanup_v2_units(target, imported_ids)
        raise
      ensure
        source&.close
        target&.close
      end

      # rubocop:disable Metrics/ParameterLists
      def import_transaction(source, target, descriptor, staged_files, assets, imported_ids)
        validate_versions!(source, target, descriptor)
        module_unit, units = package_units(source, descriptor.name)
        validate_target!(target, descriptor.name, units)
        target.transaction do
          imported_ids.concat(insert_units(source, target, module_unit, units))
          assets.install(staged_files, @protected_files)
        end
      end
      # rubocop:enable Metrics/ParameterLists

      def insert_units(source, target, module_unit, units)
        units.map do |unit|
          container = unit == module_unit ? target.root_unit.fetch('UnitID') : unit.fetch('ContainerID')
          target.insert_unit(
            container_uuid: container, containment_name: unit.fetch('ContainmentName'),
            contents_doc: source.parse_contents(unit)
          )
        end
      end

      def import_result(source, target, descriptor, staged_files, imported_ids)
        Result.new(
          descriptor.name, descriptor.version, imported_ids.first, imported_ids.size,
          staged_files.keys, source.mendix_version, target.mendix_version
        )
      end

      def validate_versions!(source, target, descriptor)
        package_version = descriptor.model_version.to_s
        if !package_version.empty? && package_version != source.mendix_version
          raise MarketplaceError,
                "module manifest version #{package_version} does not match package MPR #{source.mendix_version}"
        end
        return if source.mendix_version == target.mendix_version
        return if @allow_model_upgrade && forward_version?(source.mendix_version, target.mendix_version)

        raise MarketplaceError,
              "module uses Mendix #{source.mendix_version}, target uses #{target.mendix_version}; " \
              'pure-Ruby import requires matching model versions'
      end

      def forward_version?(source, target)
        Gem::Version.new(numeric_version(target)) >= Gem::Version.new(numeric_version(source))
      end

      def numeric_version(value)
        value.to_s[/\A\d+(?:\.\d+){0,3}/] || '0'
      end

      def package_units(source, module_name) # rubocop:disable Metrics/MethodLength
        module_unit = find_module_unit(source, module_name)
        raise MarketplaceError, "module #{module_name.inspect} is absent from package MPR" unless module_unit

        units = [module_unit]
        loop do
          ids = units.map { _1.fetch('UnitID') }
          children = source.all_units.select do |unit|
            ids.include?(unit['ContainerID']) && !ids.include?(unit['UnitID'])
          end
          break if children.empty?

          units.concat(children)
        end
        [module_unit, units]
      end

      def find_module_unit(source, module_name)
        source.units_by_containment('Modules').find do |unit|
          document = source.parse_contents(unit)
          %w[Projects$ModuleImpl Projects$Module].include?(document['$Type']) &&
            document['Name'] == module_name
        end
      end

      def validate_target!(target, module_name, units)
        duplicate = target.units_by_containment('Modules').any? do |unit|
          target.parse_contents(unit)['Name'] == module_name
        end
        raise MarketplaceError, "module #{module_name} already exists in target MPR" if duplicate

        existing_ids = target.all_units.to_h { [_1.fetch('UnitID'), true] }
        collision = units.find { existing_ids[_1.fetch('UnitID')] }
        return unless collision

        raise MarketplaceError, "module unit ID already exists: #{collision.fetch('UnitID')}"
      end

      def cleanup_v2_units(target, ids)
        return unless target&.format_version == :v2

        Array(ids).each { FileUtils.rm_f(target.content_path('UnitID' => _1)) }
      end
    end
  end
end
