# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'zip'

module Mxrb
  module Compiler
    DeploymentBootstrap = Data.define(:deployment, :created, :template_root)

    # Creates a deployment workspace from versioned Studio Pro templates without invoking its builders.
    class DeploymentBootstrapper # rubocop:disable Metrics/ClassLength
      COMMON_TEMPLATE_ROOTS = %w[data log model native run tmp].freeze
      REQUIRED_DIRECTORIES = %w[
        data/database data/files data/tmp log model/bundles model/lib/userlib model/resources run tmp web/img
      ].freeze

      def initialize(mpr_path, deployment:, mendix_home: nil)
        @mpr_path = File.expand_path(mpr_path)
        @project_root = File.dirname(@mpr_path)
        @deployment = File.expand_path(deployment)
        @source = SourceModel.read(@mpr_path)
        @version_root = resolve_version_root(mendix_home)
        @template_root = File.join(@version_root, 'modeler', 'runtemplates', 'deployment')
      end

      def prepare
        return prepare_existing if ready?

        validate_templates!
        prepare_fresh
      end

      def prepare_existing
        ensure_web_build_templates if modern_react_web?
        ensure_required_directories
        copy_project_assets
        finalize_web_shell
        DeploymentBootstrap.new(deployment: @deployment, created: false, template_root: @template_root)
      end

      def prepare_fresh
        FileUtils.mkdir_p(@deployment)
        copy_version_templates
        ensure_required_directories
        render_templates
        initialize_model
        copy_project_assets
        finalize_web_shell
        DeploymentBootstrap.new(deployment: @deployment, created: true, template_root: @template_root)
      end

      private

      def ready?
        Adapter::REQUIRED_FILES.all? { File.file?(File.join(@deployment, _1)) }
      end

      def resolve_version_root(mendix_home)
        root = File.expand_path(mendix_home || File.join(Dir.home, '.local', 'share', 'mendix', @source.version))
        File.basename(root) == 'runtime' ? File.dirname(root) : root
      end

      def validate_templates!
        return if File.directory?(@template_root) || File.file?(deployment_archive)

        raise CompilationError, "Mendix #{@source.version} deployment templates not found at #{@template_root}"
      end

      def copy_version_templates
        extract_deployment_archive if legacy_archive?
        COMMON_TEMPLATE_ROOTS.each { copy_tree(File.join(@template_root, _1), File.join(@deployment, _1)) }
        web_template_roots.each do |source_name, destination_name|
          copy_tree(File.join(@template_root, source_name), File.join(@deployment, destination_name))
        end
      end

      def web_template_roots
        return { 'react-web' => 'web' } if modern_react_web?
        return { 'dojo-web' => 'web' } if @source.version.to_i == 10
        return { 'web' => 'web', 'modern-web' => 'modern-web' } if @source.version.to_i == 9

        { 'web' => 'web' }
      end

      def modern_react_web?
        @source.version.to_i >= 11 || (@source.version.to_i == 10 && @source.optimized_web_client?)
      end

      def legacy_archive? = @source.version.to_i <= 7 && File.file?(deployment_archive)
      def deployment_archive = File.join(@version_root, 'modeler', 'deployment.mxz')

      def extract_deployment_archive # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        root = "#{File.expand_path(@deployment)}#{File::SEPARATOR}"
        Zip::File.open(deployment_archive) do |archive|
          archive.each do |entry|
            destination = File.expand_path(entry.name, @deployment)
            unless destination.start_with?(root)
              raise CompilationError, "unsafe deployment template entry #{entry.name.inspect}"
            end

            entry.directory? ? FileUtils.mkdir_p(destination) : extract_template_entry(entry, destination)
          end
        end
      rescue Zip::Error => e
        raise CompilationError, "invalid deployment template #{deployment_archive}: #{e.message}"
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def extract_template_entry(entry, destination)
        return if File.exist?(destination)

        FileUtils.mkdir_p(File.dirname(destination))
        entry.get_input_stream do |input|
          File.open(destination, 'wb') { |output| ::IO.copy_stream(input, output) }
        end
      end

      def copy_tree(source, destination)
        return unless File.directory?(source)

        FileUtils.mkdir_p(destination)
        Dir.children(source).sort.each do |name|
          from = File.join(source, name)
          to = File.join(destination, name)
          next if File.exist?(to)

          File.directory?(from) ? copy_tree(from, to) : FileUtils.cp(from, to)
        end
      end

      def render_templates
        Dir.glob(File.join(@deployment, '**', '*.template')).sort.each do |source|
          destination = source.delete_suffix('.template')
          File.write(destination, render(File.read(source)))
          FileUtils.rm_f(source)
        end
      end

      def ensure_web_build_templates
        validate_templates!
        %w[rspack.config.mjs.template rollup.config.mjs.template].each do |name|
          source = File.join(@template_root, 'react-web', name)
          destination = File.join(@deployment, 'web', name)
          FileUtils.cp(source, destination) unless File.exist?(destination.delete_suffix('.template'))
        end
        render_templates
      end

      def render(content)
        replacements.reduce(content) { |result, (token, value)| result.gsub(token, value) }
                    .gsub('\\{', '{').gsub('\\}', '}')
      end

      def replacements
        {
          '{InstallDir:JsStringEncode}' => @version_root,
          '{InstallDir:HtmlAttributeEncode}' => @version_root,
          '{DeploymentDir:JsStringEncode}' => @deployment,
          '{DeploymentDir:HtmlAttributeEncode}' => @deployment,
          '{ProjectDir:HtmlAttributeEncode}' => @project_root,
          '{ProjectName:HtmlAttributeEncode}' => project_name,
          '{EnableWatchman:true|false}' => 'false', '{MxBuildNumber}' => "mxrb-#{@source.version}"
        }
      end

      def initialize_model
        model = File.join(@deployment, 'model')
        FileUtils.mkdir_p(model)
        SystemModelSeed.for(@source.version).package.write(File.join(model, 'model.mdp'))
        initialize_json_files(model)
        ProjectJarArchive.new(@mpr_path, @project_root, @deployment)
                         .write(File.join(model, 'bundles', 'project.jar'), empty_classes)
      end

      def initialize_json_files(model)
        metadata = DeploymentMetadata.new(@mpr_path, @source)
        write_json(File.join(model, 'metadata.json'), metadata.document)
        write_json(File.join(model, 'dependencies.json'), metadata.dependencies)
        write_json(File.join(model, 'microflows.json'), {})
        write_json(File.join(model, 'operations.json'), [])
      end

      def empty_classes
        path = File.join(@deployment, 'tmp', 'mxrb-empty-classes')
        FileUtils.mkdir_p(path)
        path
      end

      def project_name = File.basename(@mpr_path, File.extname(@mpr_path))

      def write_json(path, value) = File.write(path, JSON.pretty_generate(value))

      def copy_project_assets
        DeploymentAssetCopier.new(
          @project_root, @deployment, method(:copy_tree), source: @source
        ).copy
      end

      def ensure_required_directories
        REQUIRED_DIRECTORIES.each { FileUtils.mkdir_p(File.join(@deployment, _1)) }
      end

      def finalize_web_shell
        WebShellMaterializer.new(File.join(@deployment, 'web'), version: @source.version).materialize
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
