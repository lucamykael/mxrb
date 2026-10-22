# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Writes the frontend template, theme, assets, manifest and coverage files.
      module SupportFiles
        private

        def write_support_files
          write('Gemfile', gemfile)
          write('.ruby-version', "4.0\n")
          write('.gitignore', ruby_gitignore)
          write('.env.example', ruby_env_example)
          %w[development qa staging production].each do |name|
            write(File.join('config', 'environments', "#{name}.env.example"), environment_example(name))
          end
          write('project.rb', project_source)
          write(File.join('config', 'application.rb'), application_source)
          write(File.join('config', 'adapters.rb'), adapters_source)
          write(File.join('config', RubyApp::VERIFIED_ADAPTERS), verified_adapters_source)
          write(File.join('bin', 'server'), server_source)
          File.chmod(0o755, File.join(@output_dir, 'bin', 'server'))
          write(File.join('frontend', 'package.json'), frontend_package)
          write(File.join('frontend', 'vite.config.ts'), vite_config)
          write(File.join('frontend', 'eslint.config.js'), frontend_eslint_config)
          write(File.join('frontend', 'index.html'), frontend_index)
          write(File.join('frontend', 'src', 'vite-env.d.ts'), "/// <reference types=\"vite/client\" />\n")
          copy_frontend_template
          write(File.join('frontend', 'package-lock.json'), frontend_package_lock)
          write_generated_frontend_contract
          write('README.md', readme)
        end

        def copy_frontend_template
          source = FRONTEND_TEMPLATE_DIR
          Find.find(source) do |path|
            next if path == source || File.directory?(path)

            write(File.join('frontend', Pathname.new(path).relative_path_from(Pathname.new(source)).to_s),
                  File.binread(path))
          end
        end

        def write_generated_frontend_contract
          write_feedback_widget
          write_project_widgets
          write_project_javascript_actions
          decimal_settings = JSON.generate(Runtime::DecimalContext.settings(@project))
          write(File.join('frontend', 'src', 'generated', 'decimalConfig.ts'),
                "export default #{decimal_settings} as { rounding?: string };\n")
          write(File.join('frontend', 'src', 'generated', 'types.ts'), frontend_types)
          write(File.join('frontend', 'src', 'generated', 'pages.ts'), generated_frontend_pages)
          write(File.join('frontend', 'src', 'generated', 'nanoflows.ts'), generated_frontend_nanoflows)
          write(File.join('frontend', 'src', 'generated', 'README.md'), <<~MARKDOWN)
            # Generated bridge

            This directory is owned by MXRB and is the only frontend area regenerated from the
            portable model. Build application code in `features`, `components`, `hooks`, `layouts`,
            `core`, and `styles`; those directories survive every Ruby/TypeScript/MPR round-trip.
          MARKDOWN
        end

        def write_feedback_widget
          source = KnownFeedbackWidget.source(File.dirname(@mpr_path))
          registration = "export {};\n"
          if source
            root = File.join('frontend', 'src', 'generated', 'bridge', 'vendor', 'feedback')
            write(File.join(root, 'Feedback.mjs'), source.fetch(:bundle))
            write(File.join(root, 'LICENSE'), source.fetch(:license))
            write(File.join(root, 'Feedback.d.mts'), <<~TS)
              import type { ComponentType } from 'react';
              import type { NativeFeedbackProps } from '../../feedbackCaptureWidget';
              declare const Feedback: ComponentType<NativeFeedbackProps>;
              export default Feedback;
            TS
            registration = <<~TS
              import Feedback from './bridge/vendor/feedback/Feedback.mjs';
              import { registerFeedbackWidget } from './bridge/feedbackCaptureWidget';
              registerFeedbackWidget(Feedback);
            TS
          end
          write(File.join('frontend', 'src', 'generated', 'feedbackWidget.ts'), registration)
        end

        # The project's JavaScript actions the nanoflows call and no verified adapter
        # covers run their own source: their actions directory is copied, with its
        # node_modules only when an action imports a package the frontend lacks.
        # An action written for React Native cannot run in the browser: without
        # a verified adapter the export fails rather than ship a nanoflow that
        # breaks at the call.
        def write_project_javascript_actions
          root = File.dirname(@mpr_path)
          called = (@called_javascript_actions || []).to_a - KnownJavaScriptActions.adapted(root)
          unsupported = ProjectJavaScriptActions.react_native(root, called)
          unless unsupported.empty?
            raise SerializationError, 'JavaScript actions target React Native and have no web adapter: ' \
                                      "#{unsupported.join(', ')}"
          end

          @project_javascript_actions = ProjectJavaScriptActions.find(root, called)
          vendor = File.join('frontend', 'src', 'generated', 'bridge', 'vendor', 'javascriptsource')
          @project_javascript_actions.group_by(&:directory).each do |directory, actions|
            target = File.join(vendor, File.basename(File.dirname(directory)), 'actions')
            packages = actions.any? { _1.packages.any? }
            Dir.glob('**/*', base: directory).each do |entry|
              path = File.join(directory, entry)
              next unless File.file?(path)
              next if !packages && entry.start_with?('node_modules/')

              write(File.join(target, entry), File.binread(path))
            end
          end
        end

        # Widgets of the rendered pages the bridge does not render itself run their
        # own web build from the project's widgets/*.mpk: a pluggable widget through
        # the pluggable host, a Dojo widget through the legacy widget host. A verified
        # adapter keeps precedence over a pluggable build.
        def write_project_widgets
          bundles = (@rendered_widget_ids || []).sort.filter_map do |widget_id|
            next if WidgetSupport.family(widget_id)&.fetch('support') == 'full'

            bundle = ProjectWidgetBundle.find(File.dirname(@mpr_path), widget_id)
            bundle unless bundle.nil? || (WidgetSupport::ADAPTERS.key?(widget_id) && !bundle.legacy)
          end
          registrations = bundles.each_with_index.map do |bundle, index|
            bundle.legacy ? write_legacy_widget(bundle, index) : write_project_widget(bundle, index)
          end
          imports = []
          imports << "import { registerProjectWidget } from './bridge/pluggableHost';" unless bundles.all?(&:legacy)
          legacy = "import { registerLegacyWidget } from './bridge/legacy/LegacyWidgetHost';"
          imports << legacy if bundles.any?(&:legacy)
          source = registrations.empty? ? "export {};\n" : "#{imports.join("\n")}\n\n#{registrations.join("\n")}\n"
          write(File.join('frontend', 'src', 'generated', 'projectWidgets.ts'), source)
        end

        def write_project_widget(bundle, index)
          root = File.join('frontend', 'src', 'generated', 'bridge', 'vendor', 'widgets', bundle.widget_id)
          bundle.files.each { |relative, contents| write(File.join(root, relative), contents) }
          write(File.join(root, "#{bundle.name}.d.mts"), <<~TS)
            import type { ComponentType } from 'react';
            declare const Widget: ComponentType<Record<string, unknown>>;
            export default Widget;
            export { Widget as #{bundle.name} };
          TS
          path = "./bridge/vendor/widgets/#{bundle.widget_id}/#{bundle.name}"
          style = bundle.files.key?("#{bundle.name}.css") ? "import '#{path}.css';\n" : ''
          definition = JSON.generate(ProjectWidgetBundle.properties(bundle.definition.properties))
          "#{style}import * as widget#{index} from '#{path}.mjs';\n" \
            "registerProjectWidget(#{bundle.widget_id.inspect}, widget#{index}, #{bundle.name.inspect}, #{definition});"
        end

        # A Dojo widget's scripts and templates load as text into the AMD loader;
        # its stylesheets are imported, and its other files are also served under
        # /widgets/, where the Mendix client serves them.
        def write_legacy_widget(bundle, index)
          root = File.join('frontend', 'src', 'generated', 'bridge', 'vendor', 'widgets', bundle.widget_id)
          bundle.files.each do |relative, contents|
            write(File.join(root, relative), contents)
            write(File.join('frontend', 'public', 'widgets', relative), contents) unless
              relative.match?(/\.(?:js|html|css|xml)\z/i)
          end
          path = "./bridge/vendor/widgets/#{bundle.widget_id}/"
          styles = bundle.files.keys.grep(/\.css\z/i).sort.map { "import '#{path}#{_1}';\n" }.join
          definition = JSON.generate(ProjectWidgetBundle.properties(bundle.definition.properties))
          "#{styles}const sources#{index} = import.meta.glob<string>('#{path}**/*.{js,html}', " \
            "{ query: '?raw', import: 'default', eager: true });\n" \
            "registerLegacyWidget(#{bundle.widget_id.inspect}, sources#{index}, #{path.inspect}, " \
            "#{bundle.entry.inspect}, #{definition});"
        end

        def generated_frontend_pages
          frontend_pages.gsub("from './generated/pages/", "from './pages/")
        end

        def generated_frontend_nanoflows
          frontend_nanoflows.gsub("from './generated/nanoflows/", "from './nanoflows/")
        end

        def copy_frontend_theme
          root = File.join(@output_dir, 'frontend', 'src', 'generated', 'platform')
          FileUtils.mkdir_p(root)
          %w[theme themesource theme-cache].each do |directory|
            source = File.join(@mendix_sidecar, directory)
            next unless File.directory?(source)

            copy_frontend_web_assets(source, File.join(root, directory))
          end
          copy_frontend_public_theme_assets(root)
          WidgetStyles.write(@mendix_sidecar, File.join(root, 'widgets'), @widget_ids || [])
          fallback_scss = File.join(root, 'theme', 'web', 'main.scss')
          write(relative(fallback_scss), '') unless File.file?(fallback_scss)
          fallback_css = File.join(root, 'theme-cache', 'web', 'theme.compiled.css')
          write(relative(fallback_css), '') unless File.file?(fallback_css)
          fallback_logo = File.join(root, 'theme', 'web', 'logo.png')
          return if File.file?(fallback_logo)

          FileUtils.mkdir_p(File.dirname(fallback_logo))
          File.binwrite(
            fallback_logo,
            Base64.strict_decode64(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
            )
          )
        end

        def copy_frontend_public_theme_assets(root)
          destination = File.join(root, 'theme-cache', 'web')
          sources = Dir.glob(File.join(@mendix_sidecar, 'themesource', '*', 'public')).sort
          sources << File.join(@mendix_sidecar, 'theme', 'web')
          sources.select { File.directory?(_1) }.each do |source|
            overlay_frontend_web_assets(source, destination)
            overlay_frontend_web_assets(source, File.join(@output_dir, 'frontend', 'public'), public: true)
          end
        end

        # The npm files of a theme that was once an npm package of its own
        # (package.json, a lockfile, node_modules) must not reach the frontend,
        # where Vite and TypeScript would read them in place of the generated
        # frontend/package.json.
        NPM_PACKAGE_FILES = %w[
          package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml .npmrc
        ].freeze

        def npm_package_file?(path)
          NPM_PACKAGE_FILES.include?(File.basename(path))
        end

        def overlay_frontend_web_assets(source, destination, public: false)
          Find.find(source) do |path|
            relative_path = path.delete_prefix("#{source}/")
            Find.prune if File.directory?(path) && File.basename(path) == 'node_modules'
            next if path == source || File.directory?(path)
            next if npm_package_file?(path)
            next if %w[.js .jsx .scss].include?(File.extname(path).downcase)
            next if public && %w[.html .htm].include?(File.extname(path).downcase)

            target = File.join(destination, relative_path)
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp(path, target)
          end
        end

        def copy_frontend_web_assets(source, destination)
          FileUtils.rm_rf(destination)
          Find.find(source) do |path|
            relative_path = path.delete_prefix("#{source}/")
            Find.prune if File.directory?(path) && relative_path.split(File::SEPARATOR).include?('native')
            Find.prune if File.directory?(path) && File.basename(path) == 'node_modules'
            next if path == source
            next if File.file?(path) && npm_package_file?(path)
            next if File.file?(path) && %w[.js .jsx].include?(File.extname(path).downcase)

            target = File.join(destination, relative_path)
            if File.directory?(path)
              FileUtils.mkdir_p(target)
            else
              FileUtils.mkdir_p(File.dirname(target))
              FileUtils.cp(path, target)
            end
          end
        end

        def java_action_parameters(project)
          project.modules.flat_map do |mod|
            mod.application_documents.filter_map do |entry|
              next unless entry[:type] == 'JavaActions$JavaAction'

              parameters = IO::BsonCodec.parse_array(entry.fetch(:doc)['Parameters'])[:items].to_h do |parameter|
                [IO::BsonCodec.extract_id(parameter['$ID']).to_s, parameter.fetch('Name')]
              end
              ["#{mod.name}.#{entry[:name]}", parameters]
            end
          end.to_h
        end

        # The JSON import mappings the Ruby runtime applies, by qualified name.
        def import_mapping_definitions(project)
          project.modules.flat_map do |mod|
            mod.infrastructure_documents.select { _1[:type] == 'ImportMappings$ImportMapping' }.map do |document|
              ["#{mod.name}.#{document.fetch(:name)}", Runtime::ImportMapping.definition(document.fetch(:doc))]
            end
          end.sort.to_h
        end

        def write_manifest(project, modules, runtime_mpr)
          native_coverage(project)
          payload = {
            'format_version' => 1, 'mode' => 'ruby',
            'project' => { 'name' => project.name, 'mendix_version' => project.mendix_version },
            'decimal' => Runtime::DecimalContext.settings(project),
            'time_zone' => Runtime::TimeZones.settings(project),
            'languages' => Runtime::Languages.settings(project),
            'lifecycle' => Runtime::Lifecycle.settings(project),
            'security' => @security_manifest,
            'navigation' => runtime_value(project.navigation.to_h),
            'source' => {
              'name' => File.basename(@mpr_path),
              'sha256' => Digest::SHA256.file(@mpr_path).hexdigest
            },
            'modules' => modules, 'coverage' => @coverage, 'runtime_model' => 'ruby',
            'java_action_parameters' => java_action_parameters(project),
            'import_mappings' => import_mapping_definitions(project),
            'frontend' => {
              'framework' => 'react', 'language' => 'typescript', 'bundler' => 'vite',
              'source' => 'frontend/src', 'generated' => 'frontend/src/generated',
              'application_owned' => %w[
                frontend/src/app frontend/src/components frontend/src/core frontend/src/features
                frontend/src/hooks frontend/src/layouts frontend/src/styles
              ],
              'types' => 'frontend/src/generated/types.ts',
              'typecheck' => 'npm run typecheck', 'lint' => 'npm run lint',
              'test' => 'npm run test', 'format_check' => 'npm run format:check',
              'build' => 'frontend/dist'
            },
            'round_trip' => {
              'compiler' => 'project.rb',
              'mendix_project' => relative(File.join(@mendix_sidecar, 'project.rb')),
              'runtime_mpr' => relative(runtime_mpr),
              'runtime_project' => relative(File.join(File.dirname(runtime_mpr), 'project')),
              'editable_mendix_source' => relative(@mendix_sidecar)
            }
          }
          preset = Preset.detect(@output_dir)
          payload['ruby_stack'] = Preset.manifest(preset) if preset
          write(MANIFEST_PATH, JSON.pretty_generate(payload) << "\n")
        end

        def native_coverage(project)
          known_ids = @coverage.to_h { [_1.fetch('id').to_s, true] }
          project.all_units.each do |unit|
            next if known_ids[unit.fetch('UnitID').to_s]

            document = project.parse_bson(unit)
            name = document['Name'] || document['name'] || document['$Type']
            projected = Mxrb::Exporter.ruby_projected_document_type?(document['$Type'])
            add_coverage(
              unit['UnitID'], name.to_s, document['$Type'].to_s,
              relative(@mendix_sidecar),
              projected ? 'mendix_dsl_bidirectional' : 'preserved_native'
            )
          end
        end

        def add_coverage(id, name, kind, path, status)
          @coverage << {
            'id' => id.to_s, 'name' => name.to_s, 'kind' => kind.to_s,
            'ruby_path' => path, 'status' => status
          }
        end
      end
      # rubocop:enable Metrics
    end
  end
end
