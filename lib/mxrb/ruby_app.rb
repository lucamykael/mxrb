# frozen_string_literal: true

require 'digest'
require 'date'
require 'fileutils'
require 'json'
require 'monitor'
require 'uri'
require_relative 'native_fragment_store'
require_relative 'ruby_app/session_manager'
require_relative 'ruby_app/design_classes'
require_relative 'ruby_app/design_declarations'
require_relative 'ruby_app/widget_styles'
require_relative 'ruby_app/source_identity'
require_relative 'ruby_app/domain_rule_builders'
require_relative 'ruby_app/security_builders'
require_relative 'ruby_app/member_identity'
require_relative 'ruby_app/record_identity'
require_relative 'ruby_app/regular_expression'
require_relative 'ruby_app/dataset'
require_relative 'ruby_app/security_identity'
require_relative 'ruby_app/schedule_builder'
require_relative 'ruby_app/page_data_sources'
require_relative 'ruby_app/page_design_identity'
require_relative 'ruby_app/pluggable_properties'
require_relative 'ruby_app/runtime_project'
require_relative 'ruby_app/runtime_catalog'
require_relative 'ruby_app/presentation'
require_relative 'ruby_app/presentation_contracts'
require_relative 'ruby_app/async_invocations'
require_relative 'ruby_app/file_content'
require_relative 'ruby_app/record_inheritance'
require_relative 'ruby_app/record_validation'
require_relative 'ruby_app/known_java_actions'
require_relative 'ruby_app/known_oql_actions'
require_relative 'ruby_app/known_oql_module_actions'
require_relative 'runtime/xpath'
require_relative 'http/server'

module Mxrb
  # Runtime and reversible metadata contract for projects exported with
  # `mxrb export --mode ruby`.
  module RubyApp
    # rubocop:disable Metrics
    MANIFEST_PATH = File.join('.mxrb', 'ruby-app.json')
    SOURCE_GLOBS = [
      'app/**/*.rb', 'config/**/*', 'frontend/**/*', 'spec/**/*.rb',
      'db/migrate/**/*', 'bin/**/*', '.rspec', 'config.ru',
      'Gemfile', 'Rakefile', 'README.md', '.gitignore', '.env.example', '.ruby-version'
    ].freeze
    SOURCE_EXCLUSIONS = %w[frontend/node_modules/ frontend/dist/].freeze
    ARTIFACT_DIRECTORIES = %w[
      constants enumerations models dtos controllers services pages presentation security
      scheduled_events regular_expressions datasets
    ].freeze

    def self.application_files(root)
      ARTIFACT_DIRECTORIES.flat_map do |directory|
        files = Dir.glob(File.join(root, 'app', directory, '**', '*.rb'))
        next files unless directory == 'controllers'

        files.select { mxrb_controller_file?(_1) }
      end.sort
    end

    def self.mxrb_controller_file?(path)
      source = File.read(path)
      source.match?(/<\s*(?:::)?Mxrb::RubyApp::Controller\b/) ||
        source.match?(/^\s*controller_name\b/)
    end

    def self.with_native_fragments(root, &block)
      store = NativeFragmentStore.new(File.join(File.expand_path(root), '.mxrb', 'native_fragments'))
      NativeFragmentStore.with(store, &block)
    end

    def self.load_sources(manifest, member_identity_project: nil)
      SourceIdentity.with(manifest) do |identities|
        FlowMetadata.with(manifest) do
          PageDesignIdentity.with(manifest) do
            PluggableProperties.with(manifest) do
              with_native_fragments(manifest.root) do
                application_files(manifest.root).each do |path|
                  identities.load_file(path) { load path, true }
                end
                identities.rebase_member_identities!(member_identity_project) if member_identity_project
                identities.finalize!
              end
            end
          end
        end
      end
    end

    def self.source_bundle(root)
      expanded = File.expand_path(root)
      candidates = SOURCE_GLOBS.flat_map { Dir.glob(File.join(expanded, _1), File::FNM_DOTMATCH) }
                               .select { File.file?(_1) }
      files = candidates.filter_map do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(expanded)).cleanpath.to_s
        next if SOURCE_EXCLUSIONS.any? { relative.start_with?(_1) }

        contents = File.binread(path)
        {
          path: relative, contents:, sha256: Digest::SHA256.hexdigest(contents),
          mode: File.stat(path).mode & 0o777
        }
      end
      files.uniq { _1.fetch(:path) }.sort_by { _1.fetch(:path) }
    end

    def self.safe_source_path(root, relative)
      clean = Pathname.new(relative.to_s).cleanpath
      raise ValidationError, "unsafe embedded Ruby source path: #{relative}" \
        if clean.absolute? || clean.to_s == '..' || clean.to_s.start_with?('../')

      File.join(File.expand_path(root), clean.to_s)
    end

    def self.safe_source_mode(value, relative)
      fallback = relative.to_s.start_with?('bin/') ? 0o755 : 0o644
      mode = Integer(value || fallback)
      raise ValidationError, "unsafe embedded Ruby source mode: #{mode}" unless mode.between?(0, 0o777)

      mode
    end

    def self.compile(root, target = nil, mendix_version: nil)
      manifest = Manifest.load(root)
      destination = File.expand_path(
        target || ENV.fetch('MXRB_OUTPUT_PATH', File.join(root, 'build', manifest.mpr_name))
      )
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = destination
      runtime_mpr = manifest.absolute_path('runtime_mpr')
      if File.file?(runtime_mpr)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(runtime_mpr, destination)
        runtime_contents = File.join(File.dirname(runtime_mpr), 'mprcontents')
        if File.directory?(runtime_contents)
          FileUtils.cp_r(runtime_contents, File.dirname(destination), remove_destination: true)
        end
        restore_runtime_project(manifest, destination)
      else
        load manifest.absolute_path('mendix_project')
      end
      transitioned = mendix_version && manifest.data.dig('project', 'mendix_version') != mendix_version.to_s
      transition(destination, mendix_version) if mendix_version
      Synchronizer.new(root, destination, manifest:, rebase_member_identities: transitioned).synchronize!
      destination
    ensure
      if previous
        ENV['MXRB_OUTPUT_PATH'] = previous
      else
        ENV.delete('MXRB_OUTPUT_PATH')
      end
    end

    def self.restore_runtime_project(manifest, destination)
      source = manifest.absolute_path('runtime_project')
      return unless File.directory?(source)

      Dir.children(source).each do |name|
        FileUtils.cp_r(File.join(source, name), File.join(File.dirname(destination), name),
                       remove_destination: true)
      end
    rescue KeyError
      nil
    end

    def self.transition(path, version)
      project = Model::Project.open(path, readonly: false)
      project.migrate_to!(version) unless project.mendix_version == version.to_s
      # An explicit native target also normalizes legacy storage at the same
      # version. A plain lossless compile retains the source storage format.
      project.mpr.ensure_storage_for_version!(version)
    ensure
      project&.close
    end

    # rubocop:enable Metrics
  end
end

require_relative 'ruby_app/manifest'
require_relative 'ruby_app/source_reloader'
require_relative 'ruby_app/registry'
require_relative 'ruby_app/access_rule_builder'
require_relative 'ruby_app/record'
require_relative 'ruby_app/controller'
require_relative 'ruby_app/enumeration'
require_relative 'ruby_app/constant'
require_relative 'ruby_app/module_security'
require_relative 'ruby_app/project_security'
require_relative 'ruby_app/scheduled_event'
require_relative 'ruby_app/flow_metadata'
require_relative 'ruby_app/service'
require_relative 'ruby_app/page'
require_relative 'ruby_app/application'
require_relative 'ruby_app/native_bridge'
require_relative 'ruby_app/synchronizer'
require_relative 'ruby_app/server'
require_relative 'ruby_app/rack_adapter'
require_relative 'ruby_app/supervisor'
