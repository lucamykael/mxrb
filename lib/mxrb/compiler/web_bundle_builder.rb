# frozen_string_literal: true

require 'json'
require 'open3'

module Mxrb
  module Compiler
    WebBundleResult = Data.define(:directory, :files, :bytes)

    # Generates the web-client entrypoint and runs the version-owned Rspack toolchain directly.
    # rubocop:disable Metrics
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
        profiles = Adapter.for(@source.version, source: @source).web_profiles
        return LegacyPageBuilder.new(@source, web, profiles:).build unless profiles.include?(:react)

        prepare(web)
        run_bundler(web)
        WebShellMaterializer.new(web, version: @source.version).materialize
        result(web)
      end

      private

      def run_bundler(web)
        output, status = Open3.capture2e(environment(web), node, *bundler_arguments, chdir: web)
        raise CompilationError, "#{bundler_name} web build failed:\n#{output}" unless status.success?
      end

      def prepare(web)
        WidgetPackageExtractor.new(File.dirname(@mpr_path), web).extract
        materialize_react_dom_compatibility(web)
        WebOperationCompiler.new(@source).write(File.join(@deployment, 'model', 'operations.json'))
        PageBundleBuilder.new(@source, web).build
        write_entry(File.join(web, 'index.js'))
      end

      def materialize_react_dom_compatibility(web)
        shim = File.join(web, 'react-dom-compat.mjs')
        react_dom = File.join(@version_root, 'modeler', 'tools', 'node', 'node_modules',
                              'react-dom', 'index.js')
        File.write(shim, <<~JS)
          import * as ReactDOM from #{JSON.generate(react_dom)};
          export * from #{JSON.generate(react_dom)};
          export default ReactDOM;
          export const findDOMNode = value => {
            if (typeof Element !== "undefined" && value instanceof Element) return value;
            const seen = new Set();
            const pending = [value?._reactInternals, value?._reactInternalFiber].filter(Boolean);
            while (pending.length) {
              const fiber = pending.shift();
              if (!fiber || seen.has(fiber)) continue;
              seen.add(fiber);
              if (typeof Element !== "undefined" && fiber.stateNode instanceof Element) {
                return fiber.stateNode;
              }
              pending.push(fiber.child, fiber.sibling);
            }
            return null;
          };
        JS
        config_path = File.join(web, 'rspack.config.mjs')
        return unless File.file?(config_path)

        config = File.read(config_path)
        return if config.include?(JSON.generate(shim))

        marker = 'alias: {'
        replacement = "#{marker}\n            \"react-dom\": #{JSON.generate(shim)},"
        raise CompilationError, 'Rspack config has no resolve alias block' unless config.include?(marker)

        File.write(config_path, config.sub(marker, replacement))
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
      def bundler_name = @source.version.to_i == 10 ? 'Rollup' : 'Rspack'

      def bundler_arguments
        return [File.join(node_modules, 'rollup', 'dist', 'bin', 'rollup'), '--config'] if @source.version.to_i == 10

        [File.join(@version_root, 'modeler', 'tools', 'node', 'rspack-runner.mjs')]
      end

      def node_modules = File.join(@version_root, 'modeler', 'tools', 'node', 'node_modules')

      def environment(web)
        {
          'NODE_ENV' => 'production', 'SOURCE_MAP_GENERATION' => 'disabled',
          'SHOULD_GENERATE_EMBEDDED_INDEX' => 'false',
          'MX_DEPLOYMENT_WEB_DIRECTORY' => web,
          'MX_WEB_CLIENT_BUILD_LOG' => File.join(@deployment, 'log', 'mxrb-web-build.log'),
          'NODE_PATH' => node_modules
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
    # rubocop:enable Metrics
  end
end
