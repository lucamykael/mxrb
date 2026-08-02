# frozen_string_literal: true

require 'json'
require 'open3'

module Mxrb
  module Compiler
    WebBundleResult = Data.define(:directory, :files, :bytes)

    # Generates the web-client entrypoint and runs the version-owned Rspack toolchain directly.
    class WebBundleBuilder
      include ModelValues

      def initialize(mpr_path, deployment:, mendix_home:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
        @source = SourceModel.read(@mpr_path)
        @version_root = version_root(mendix_home)
      end

      def build
        web = File.join(@deployment, 'web')
        profiles = Adapter.for(@source.version).web_profiles
        return LegacyPageBuilder.new(@source, web, profiles:).build unless profiles.include?(:react)

        prepare(web)
        run_rspack(web)
        WebShellMaterializer.new(web, version: @source.version).materialize_dynamic_imports
        result(web)
      end

      private

      def run_rspack(web)
        output, status = Open3.capture2e(environment(web), node, runner, chdir: web)
        raise CompilationError, "Rspack web build failed:\n#{output}" unless status.success?
      end

      def prepare(web)
        WidgetPackageExtractor.new(File.dirname(@mpr_path), web).extract
        WebOperationCompiler.new(@source).write(File.join(@deployment, 'model', 'operations.json'))
        PageBundleBuilder.new(@source, web).build
        write_entry(File.join(web, 'index.js'))
      end

      def version_root(path)
        root = File.expand_path(path)
        File.basename(root) == 'runtime' ? File.dirname(root) : root
      end

      def result(web)
        directory = File.join(web, 'dist')
        files = Dir.glob(File.join(directory, '**', '*')).select { File.file?(_1) }
        WebBundleResult.new(directory:, files: files.length, bytes: files.sum { File.size(_1) })
      end

      def node = File.join(@version_root, 'modeler', 'tools', 'node', 'linux-x64', 'node')
      def runner = File.join(@version_root, 'modeler', 'tools', 'node', 'rspack-runner.mjs')

      def environment(web)
        {
          'NODE_ENV' => 'production', 'SOURCE_MAP_GENERATION' => 'disabled',
          'SHOULD_GENERATE_EMBEDDED_INDEX' => 'false',
          'MX_DEPLOYMENT_WEB_DIRECTORY' => web,
          'MX_WEB_CLIENT_BUILD_LOG' => File.join(@deployment, 'log', 'mxrb-web-build.log'),
          'NODE_PATH' => File.join(@version_root, 'modeler', 'tools', 'node', 'node_modules')
        }
      end

      def write_entry(path)
        payload = {
          languages: languages, systemTexts: rendered_system_texts,
          constants: { LAYOUT_SCOPE_ID_PREFIX: 'l' },
          registerServiceWorker: false, enableServiceWorkerCaching: true
        }
        File.write(path, "import { startApp } from \"mendix\";\n\nstartApp(#{JSON.pretty_generate(payload)});\n")
      end

      def languages
        values = translations.values.flat_map(&:keys).uniq.sort
        values.empty? ? ['en_US'] : values
      end

      def rendered_system_texts
        translations.transform_values do |values|
          languages.map { values.fetch(_1, '') }
        end
      end

      def translations
        @translations ||= collect_translations
      end

      def collect_translations
        collection = @source.documents('Texts$SystemTextCollection').first
        return {} unless collection

        array(collection['SystemTexts']).to_h do |text|
          translations = array(text.dig('Text', 'Items')).to_h do |item|
            [item['LanguageCode'].to_s, item['Text'].to_s]
          end
          [text['InternalKey'].to_s, translations]
        end
      end
    end
  end
end
