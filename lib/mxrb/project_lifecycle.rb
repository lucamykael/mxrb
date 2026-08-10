# frozen_string_literal: true

require 'tmpdir'

module Mxrb
  UpgradeResult = Data.define(:path, :from, :to, :applied)
  MigrationResult = Data.define(:current, :generated, :diff) do
    def clean? = diff.added.empty? && diff.removed.empty? && diff.changed.empty?
  end

  # Inspects, previews upgrades, and compares generated definitions with an MPR.
  class ProjectLifecycle
    VERSION = /\A\d+\.\d+\.\d+\z/
    VERSION_DECLARATION = /(?<prefix>mendix_version(?:\s+|\s*=\s*))["'](?<version>[^"']+)["']/

    def initialize(root = Dir.pwd)
      @root = File.expand_path(root)
      @project_file = File.join(@root, 'project.rb')
    end

    def inspect
      {
        root: @root, project_file: File.file?(@project_file),
        declared_version: declared_version,
        modules: Dir[File.join(@root, 'modules', '*', 'module.rb')].map { File.basename(File.dirname(_1)) },
        mprs: Dir[File.join(@root, '*.mpr')].sort,
        registered_scaffolds: Scaffold::Registry.new(@root).entries.keys.sort
      }
    end

    def upgrade(version, apply: false) # rubocop:disable Metrics/MethodLength
      target = version.to_s
      raise ArgumentError, 'Mendix version must use MAJOR.MINOR.PATCH' unless VERSION.match?(target)

      source = project_source
      current = declared_version
      raise ArgumentError, 'project.rb has no mendix_version declaration' unless current

      if apply
        updated = source.sub(VERSION_DECLARATION) do
          "#{Regexp.last_match(:prefix)}\"#{target}\""
        end
        transaction = Scaffold::Transaction.new
        transaction.write(@project_file, updated)
        transaction.commit
      end
      UpgradeResult.new(@project_file, current, target, apply)
    end

    def migration_plan # rubocop:disable Metrics/MethodLength
      current = Dir[File.join(@root, '*.mpr')].first
      raise ArgumentError, 'no current MPR found' unless current

      Dir.mktmpdir('mxrb-migration-') do |dir|
        generated = File.join(dir, File.basename(current))
        previous = ENV['MXRB_OUTPUT_PATH']
        ENV['MXRB_OUTPUT_PATH'] = generated
        load @project_file
        MigrationResult.new(current, generated, Mxrb.diff(current, generated))
      ensure
        previous.nil? ? ENV.delete('MXRB_OUTPUT_PATH') : ENV['MXRB_OUTPUT_PATH'] = previous
      end
    end

    private

    def project_source
      raise ArgumentError, "#{@project_file}: project.rb not found" unless File.file?(@project_file)

      File.read(@project_file)
    end

    def declared_version
      return unless File.file?(@project_file)

      File.read(@project_file).match(VERSION_DECLARATION)&.[](:version)
    end
  end
end
