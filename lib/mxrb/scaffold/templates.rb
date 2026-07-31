# frozen_string_literal: true

module Mxrb
  module Scaffold
    # Source templates used by artifact scaffolds.
    # rubocop:disable Metrics/ModuleLength
    module Templates
      module_function

      ENTITY_GUIDE = 'https://github.com/lucamykael/mxrb/blob/main/docs/pt-BR/entity-dsl.md'

      def render(kind, module_name: nil, name: nil)
        public_send(kind, module_name, name)
      end

      def entity(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          # Entity DSL reference: #{ENTITY_GUIDE}
          entity :#{name} do
          end
        RUBY
      end

      def enumeration(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          enumeration :#{name} do
            # value :Example, caption: "Example"
          end
        RUBY
      end

      def use_case(_module_name, name) = flow(name, 'Application use case', entry_point: true)
      def validation(_module_name, name) = flow(name, 'Application validation')

      def query(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          query :#{name} do
            mark_as_used
          end
        RUBY
      end

      def page(module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          page :#{name} do
            title "#{humanize(name)}"
            layout "#{module_name}.ApplicationLayout"
            # allowed_roles "Module.User"

            container :pageHeader, class_name: "mxrb-page-header" do
              text :pageTitle, caption: "#{humanize(name)}"
            end
          end
        RUBY
      end

      def nanoflow(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          nanoflow :#{name} do
            mark_as_used
          end
        RUBY
      end

      def repository(module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          repository :#{name}, implementation: "#{module_name}.#{name}Implementation"
        RUBY
      end

      def repository_implementation(_module_name, name)
        flow("#{name}Implementation", 'Infrastructure repository adapter', entry_point: true)
      end

      def security(module_name, _name)
        <<~RUBY
          # frozen_string_literal: true

          module_role :User, description: "Application user"
          module_role :Administrator, description: "Module administrator"

          # Add access_rule declarations inside each entity.
          # Example: access_rule "#{module_name}.User", read: :all
        RUBY
      end

      def scheduled_event(module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          microflow :#{name} do
          end

          scheduled_event :#{name}, microflow: "#{module_name}.#{name}",
                           interval: 1, unit: :days, enabled: true
        RUBY
      end

      def constant(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          constant :#{name}, type: :string, value: ""
        RUBY
      end

      def integration(_module_name, name) = flow(name, 'Infrastructure integration adapter', entry_point: true)

      def published_rest(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          # Handler scaffold. Publishing the REST document currently remains a
          # native Studio Pro/baseline operation; this microflow is editable Ruby.
          microflow :#{name}, kind: :infrastructure, public: true do
            documentation "Published REST handler #{humanize(name)}"
            mark_as_used
          end
        RUBY
      end

      def consumed_rest(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          microflow :#{name}, kind: :infrastructure do
            mark_as_used
            # call_rest method: :get, location: "https://api.example.test/resource"
          end
        RUBY
      end

      def java_action(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          # Adapter scaffold. Define the Java Action in the native baseline,
          # then uncomment and qualify the call below.
          microflow :#{name}, kind: :infrastructure do
            mark_as_used
            # call_java "Module.JavaActionName"
          end
        RUBY
      end

      def functional_test(module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          microflow "#{humanize(name)}",
                    call: "#{module_name}.#{name}",
                    expect: {}
        RUBY
      end

      def evaluation(_module_name, name)
        <<~RUBY
          # frozen_string_literal: true

          no_call_cycles
          no_missing_internal_references

          check "#{humanize(name)}" do |_project|
            true
          end
        RUBY
      end

      def design_system(_module_name, _name)
        <<~RUBY
          # frozen_string_literal: true

          design_system do
            # color :primary, value: "#1a1a1a"
            # spacing :medium, value: "1rem"
            forbid_literal_colors false
          end
        RUBY
      end

      def theme_main(_module_name, _name)
        <<~SCSS
          @import "custom-variables";

          :root {
            color: #17324d;
            background: #f4f7fb;
            font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          }

          body {
            margin: 0;
            background: #f4f7fb;
          }

          .mxrb-application-shell {
            min-height: 100vh;
          }

          .region-topbar {
            z-index: 20;
            border-bottom: 1px solid rgb(23 50 77 / 10%);
            background: rgb(255 255 255 / 92%);
            box-shadow: 0 8px 28px rgb(23 50 77 / 8%);
            backdrop-filter: blur(16px);
          }

          .mxrb-topbar {
            display: flex;
            height: 100%;
            align-items: center;
            gap: 16px;
            padding: 0 24px;
          }

          .mxrb-sidebar-toggle.btn {
            min-width: auto;
            padding: 9px 14px;
            border: 0;
            border-radius: 10px;
            background: #087f8c;
          }

          .mxrb-brand {
            font-size: 1.125rem;
            font-weight: 750;
            letter-spacing: -0.025em;
          }

          .region-sidebar {
            color: #dceaf0;
            background: linear-gradient(180deg, #102f42, #092331);
            box-shadow: 12px 0 36px rgb(9 35 49 / 16%);
          }

          .mxrb-navigation {
            padding: 20px 14px;
          }

          .mxrb-navigation .navbar-inner > ul > li > a {
            margin: 4px 0;
            padding: 12px 16px;
            color: #dceaf0;
            border-radius: 12px;
            font-weight: 650;
          }

          .mxrb-navigation .navbar-inner > ul > li > a:hover,
          .mxrb-navigation .navbar-inner > ul > li.active > a {
            color: #fff;
            background: rgb(255 255 255 / 12%);
          }

          .region-content {
            box-sizing: border-box;
            background: #f4f7fb;
          }

          .region-content > .mx-scrollcontainer-wrapper {
            padding: clamp(24px, 4vw, 48px);
          }

          .region-content .mx-page {
            box-sizing: border-box;
            width: 100%;
            max-width: 1120px;
            margin: 0 auto;
          }

          .mxrb-page-header {
            box-sizing: border-box;
            flex: 0 0 auto !important;
            width: 100%;
            min-height: 0;
            margin-bottom: 24px;
            padding: 28px 32px;
            color: #fff;
            border-radius: 20px;
            background: linear-gradient(135deg, #087f8c, #0b5d75);
            box-shadow: 0 16px 40px rgb(20 73 94 / 18%);
          }

          .mxrb-page-header .mx-text {
            display: block;
          }

          .mxrb-page-header .mx-text:first-child {
            font-size: clamp(2rem, 5vw, 3rem);
            font-weight: 750;
            letter-spacing: -0.04em;
          }

          .mxrb-page-header .mx-text + .mx-text {
            max-width: 680px;
            margin-top: 8px;
            color: rgb(255 255 255 / 82%);
            font-size: 1rem;
          }

          .mxrb-dashboard-grid {
            display: grid;
            grid-template-columns: repeat(3, minmax(0, 1fr));
            gap: 20px;
          }

          .mxrb-card {
            box-sizing: border-box;
            min-height: 190px;
            padding: 24px;
            border: 1px solid rgb(23 50 77 / 8%);
            border-radius: 18px;
            background: #fff;
            box-shadow: 0 12px 32px rgb(23 50 77 / 8%);
          }

          .mxrb-card .mx-text {
            display: block;
          }

          .mxrb-card .mx-text:first-child {
            margin-bottom: 14px;
            color: #087f8c;
            font-size: 0.75rem;
            font-weight: 800;
            letter-spacing: 0.12em;
          }

          .mxrb-card .mx-text:nth-child(2) {
            margin-bottom: 10px;
            color: #17324d;
            font-size: 1.25rem;
            font-weight: 750;
          }

          .mxrb-card .mx-text:nth-child(3) {
            color: #60768a;
            line-height: 1.6;
          }

          @media (max-width: 767px) {
            .mxrb-dashboard-grid {
              grid-template-columns: 1fr;
            }

            .region-content > .mx-scrollcontainer-wrapper {
              padding: 20px 16px;
            }

            .mxrb-page-header {
              padding: 24px;
              border-radius: 16px;
            }
          }
        SCSS
      end

      def theme_custom_variables(_module_name, _name)
        <<~SCSS
          // Project-specific Sass variables belong here. When Atlas Core is
          // installed, mxrb marketplace adds its legacy variable definitions.
        SCSS
      end

      def theme_settings(_module_name, _name)
        <<~JSON
          {
            "cssFiles": ["theme.compiled.css"]
          }
        JSON
      end

      def theme_exclusion_variables(_module_name, _name)
        <<~SCSS
          // Atlas Core imports this file. Add Sass variables here to exclude
          // optional Atlas components from the compiled theme.
        SCSS
      end

      def github_workflow(_module_name, _name)
        <<~YAML
          name: MXRB

          on:
            push:
            pull_request:

          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: actions/checkout@v4
                - uses: ruby/setup-ruby@v1
                  with:
                    ruby-version: "4.0"
                    bundler-cache: true
                - run: bundle exec rspec
                - run: bundle exec rubocop
                - run: bundle exec ruby project.rb
        YAML
      end

      def presentation(_module_name, _name)
        <<~RUBY
          # frozen_string_literal: true

          layout :ApplicationLayout

          evaluate_dir File.join(__dir__, "pages")
          evaluate_dir File.join(__dir__, "client_actions")
        RUBY
      end

      def infrastructure(_module_name, _name)
        <<~RUBY
          # frozen_string_literal: true

          evaluate_dir File.join(__dir__, "repositories")
          evaluate_dir File.join(__dir__, "integrations")
          evaluate_dir File.join(__dir__, "endpoints")
          evaluate_dir File.join(__dir__, "actions")
        RUBY
      end

      def flow(name, description, entry_point: false)
        <<~RUBY
          # frozen_string_literal: true

          # #{description}
          microflow :#{name} do
          #{entry_point ? '  mark_as_used' : ''}
          end
        RUBY
      end

      def humanize(name)
        name.to_s.gsub(/_+/, ' ').gsub(/([a-z\d])([A-Z])/, '\\1 \\2').strip
      end

      def snake_case(value)
        value.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
             .gsub(/([a-z\d])([A-Z])/, '\\1_\\2').tr('-', '_').downcase
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
