# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Writes the Gemfile, environment, application, server and frontend tooling files.
      module ProjectFiles
        private

        def gemfile
          <<~RUBY
            # frozen_string_literal: true

            source 'https://rubygems.org'
            gem 'mxrb'

            group :development do
              gem 'ruby-lsp', require: false
            end
          RUBY
        end

        def ruby_gitignore
          <<~TEXT
            .env
            .env.*
            !.env.example
            config/environments/*.env
            !config/environments/*.env.example
            .mxrb/runtime/*.sqlite3
            frontend/node_modules/
            frontend/dist/
          TEXT
        end

        def ruby_env_example
          <<~TEXT
            # Base values; environment profiles override this file.
            MXRB_ENV=development
          TEXT
        end

        def environment_example(name)
          <<~TEXT
            # Copy to #{name}.env. Process ENV has highest precedence.
            MXRB_DATABASE_PATH=.mxrb/runtime/#{name}.sqlite3
            MXRB_SHARED_STORE_PATH=.mxrb/runtime/#{name}-shared.sqlite3
            MXRB_SESSION_TTL=3600
            MXRB_SCHEDULER_LEASE_TTL=300
            MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=false
            MXRB_AUTH_TOKENS=
            MXRB_USERS_JSON=
          TEXT
        end

        def project_source
          <<~RUBY
            # frozen_string_literal: true

            require 'mxrb' unless defined?(Mxrb::RubyApp)

            mendix_version = #{@project.mendix_version.inspect}
            Mxrb::RubyApp.compile(__dir__, mendix_version:)
          RUBY
        end

        def application_source
          <<~RUBY
            # frozen_string_literal: true

            require 'mxrb'

            MXRB_APPLICATION_ROOT = File.expand_path('..', __dir__)
          RUBY
        end

        def adapters_source
          <<~RUBY
            # frozen_string_literal: true

            # Register only the integrations this application uses. Credentials
            # belong in ignored environment files or a deployment secret manager.
            #
            # Mxrb::RubyApp::Registry.register_adapter(:app_service) do |name, document, variables|
            #   MyAppServiceClient.call(name, document:, variables:)
            # end
            #
            # Legacy Custom Actions use Ruby implementations only. Register every
            # permitted action explicitly by its qualified Mendix name.
            #
            # Mxrb::RubyApp::Registry.register_java_custom_action('MyModule.MyAction') do |arguments|
            #   MyRubyAction.call(arguments)
            # end
            #
            # Supported kinds: :app_service, :web_service, :import_xml,
            # :import_mapping, :export_mapping, and :document.
            #{KnownJavaActions.registrations(File.dirname(@mpr_path))}
            #{KnownOqlActions.registrations(File.dirname(@mpr_path))}
            #{KnownOqlModuleActions.registrations(File.dirname(@mpr_path))}
          RUBY
        end

        def server_source
          <<~RUBY
            #!/usr/bin/env ruby
            # frozen_string_literal: true

            require_relative '../config/application'

            host = ENV.fetch('HOST', '127.0.0.1')
            port = Integer(ENV.fetch('PORT', '9292'))
            frontend_port = Integer(ENV.fetch('FRONTEND_PORT', '5173'))
            supervisor = Mxrb::RubyApp::Supervisor.new(
              MXRB_APPLICATION_ROOT, host:, api_port: port, frontend_port:
            )
            puts "[mxrb] Ruby API: http://\#{host}:\#{port}"
            puts "[mxrb] React + Vite: http://\#{host}:\#{frontend_port}"
            trap('INT') { Thread.new { supervisor.shutdown } }
            supervisor.start
          RUBY
        end

        def frontend_package
          JSON.pretty_generate(
            'name' => underscore(@project.name), 'private' => true, 'version' => '0.0.0',
            'type' => 'module',
            'scripts' => {
              'dev' => 'vite', 'typecheck' => 'tsc --noEmit',
              'lint' => 'eslint . --max-warnings=0',
              'format' => 'prettier --write .', 'format:check' => 'prettier --check .',
              'test' => 'vitest run', 'test:watch' => 'vitest',
              'build' => 'npm run typecheck && vite build', 'preview' => 'vite preview',
              'check' => 'npm run format:check && npm run lint && npm run test && npm run build'
            },
            'dependencies' => {
              'react' => '^19.2.8', 'react-dom' => '^19.2.8',
              'react-router-dom' => '^7.18.2', 'date-fns' => '^4.1.0', 'decimal.js' => '^10.6.0',
              'big.js' => '^6.2.2',
              'plotly.js-dist-min' => '3.0.1',
              'js-base64' => '3.7.7'
            },
            'devDependencies' => {
              '@eslint/js' => '^10.0.1',
              '@testing-library/jest-dom' => '^7.0.1',
              '@testing-library/react' => '^16.3.2',
              '@testing-library/user-event' => '^14.6.4',
              '@types/big.js' => '^6.2.2', '@types/node' => '^26.2.0', '@types/react' => '^19.2.18',
              '@types/react-dom' => '^19.2.4', '@vitejs/plugin-react' => '^6.0.5',
              'eslint' => '^10.8.1', 'eslint-plugin-react-hooks' => '^7.1.1',
              'globals' => '^17.11.0',
              'jsdom' => '^30.0.1', 'prettier' => '^3.9.6',
              'sass-embedded' => '^1.90.0', 'typescript' => '^6.0.3',
              'typescript-eslint' => '^8.67.0', 'vite' => '^8.2.1', 'vitest' => '^4.1.11'
            }
          ) << "\n"
        end

        def frontend_package_lock
          template = File.join(FRONTEND_TEMPLATE_DIR, 'package-lock.json')
          payload = JSON.parse(File.read(template))
          name = underscore(@project.name)
          payload['name'] = name
          payload.dig('packages', '')['name'] = name
          JSON.pretty_generate(payload) << "\n"
        end

        def frontend_eslint_config
          <<~'JS'
            import eslint from '@eslint/js';
            import reactHooks from 'eslint-plugin-react-hooks';
            import globals from 'globals';
            import tseslint from 'typescript-eslint';

            export default tseslint.config(
              {
                ignores: [
                  'dist',
                  'node_modules',
                  'src/generated/*',
                  '!src/generated/bridge',
                  'src/generated/bridge/vendor',
                ],
              },
              eslint.configs.recommended,
              ...tseslint.configs.recommended,
              {
                files: ['**/*.{ts,tsx}'],
                languageOptions: { globals: { ...globals.browser, ...globals.node } },
                plugins: { 'react-hooks': reactHooks },
                rules: {
                  'react-hooks/rules-of-hooks': 'error',
                },
              },
            );
          JS
        end

        def vite_config
          <<~JS
            import { fileURLToPath } from 'node:url';
            import { defineConfig } from 'vite';
            import react from '@vitejs/plugin-react';

            const apiPort = process.env.MXRB_API_PORT || '9292';

            export default defineConfig({
              plugins: [react()],
              resolve: {
                alias: {
                  // The pluggable widget API module that project widget builds import.
                  'mendix/filters/builders': fileURLToPath(
                    new URL('./src/generated/bridge/mendixFilters.ts', import.meta.url),
                  ),
                },
              },
              build: {
                // Mendix accepts legacy selectors that Lightning CSS rejects while minifying.
                cssMinify: false,
              },
              css: {
                preprocessorOptions: {
                  scss: {
                    // Mendix Atlas still depends on the legacy global Sass module model.
                    silenceDeprecations: ['import', 'global-builtin'],
                  },
                },
              },
              server: { proxy: { '/api': `http://127.0.0.1:${apiPort}` } },
            });
          JS
        end

        def frontend_index
          <<~HTML
            <!doctype html>
            <html lang="en">
              <head>
                <meta charset="utf-8" />
                <meta name="viewport" content="width=device-width,initial-scale=1" />
                <title>#{escape_html(@project.name)} · MXRB Ruby</title>
              </head>
              <body>
                <div id="root"></div>
                <script type="module" src="/src/main.tsx"></script>
              </body>
            </html>
          HTML
        end

        def frontend_nanoflows
          javascript_actions = KnownJavaScriptActions.matching(File.dirname(@mpr_path))
          metadata_variant = KnownJavaScriptActions.metadata_variant(File.dirname(@mpr_path))
          feedback_options = metadata_variant ? ", #{JSON.generate(metadata_variant)}" : ''
          commons = KnownJavaScriptActions.matching(File.dirname(@mpr_path),
                                                    sources: KnownJavaScriptActions::COMMONS_SOURCES,
                                                    module_name: 'nanoflowcommons')
          imports = @nanoflow_entries.map do |entry|
            relative = entry.fetch('path').delete_prefix('frontend/src/')
            "import #{entry.fetch('import_name')} from './#{relative.delete_suffix('.ts')}';"
          end
          mappings = @nanoflow_entries.map do |entry|
            "  #{entry.fetch('name').inspect}: #{entry.fetch('import_name')}"
          end
          <<~TS
            import './feedbackWidget';
            import './projectWidgets';
            import { registerNanoflows, registerJavaScriptActions } from './bridge/nanoflow';
            import { feedbackStorageActions } from './bridge/feedbackStorage';
            import { nanoflowCommonsActions } from './bridge/nanoflowCommons';
            import type { RegisteredNanoflow } from './types';

            #{imports.join("\n")}

            const nanoflows: Record<string, RegisteredNanoflow> = {
            #{mappings.join(",\n")}
            };

            registerNanoflows(nanoflows);
            registerJavaScriptActions({
              ...feedbackStorageActions(#{JSON.generate(javascript_actions)}#{feedback_options}),
              ...nanoflowCommonsActions(#{JSON.generate(commons)})
            });

            export default nanoflows;
          TS
        end

        def frontend_pages
          imports = @page_entries.map do |entry|
            relative = entry.fetch('path').delete_prefix('frontend/src/')
            "import #{entry.fetch('import_name')} from './#{relative.delete_suffix('.tsx')}';"
          end
          mappings = @page_entries.map do |entry|
            "  #{JSON.generate(entry.fetch('name'))}: #{entry.fetch('import_name')}"
          end
          <<~TS
            import type { ComponentType } from 'react';
            import type { PageComponentProps } from './types';

            #{imports.join("\n")}

            const pages: Record<string, ComponentType<PageComponentProps>> = {
            #{mappings.join(",\n")}
            };

            export default pages;
          TS
        end
      end
      # rubocop:enable Metrics
    end
  end
end
