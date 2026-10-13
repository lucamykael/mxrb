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

        def overlay_frontend_web_assets(source, destination, public: false)
          Find.find(source) do |path|
            relative_path = path.delete_prefix("#{source}/")
            next if path == source || File.directory?(path)
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
            next if path == source
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

        def write_manifest(project, modules, runtime_mpr)
          native_coverage(project)
          payload = {
            'format_version' => 1, 'mode' => 'ruby',
            'project' => { 'name' => project.name, 'mendix_version' => project.mendix_version },
            'decimal' => Runtime::DecimalContext.settings(project),
            'languages' => Runtime::Languages.settings(project),
            'security' => @security_manifest,
            'navigation' => runtime_value(project.navigation.to_h),
            'source' => {
              'name' => File.basename(@mpr_path),
              'sha256' => Digest::SHA256.file(@mpr_path).hexdigest
            },
            'modules' => modules, 'coverage' => @coverage, 'runtime_model' => 'ruby',
            'java_action_parameters' => java_action_parameters(project),
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
