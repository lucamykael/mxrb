# frozen_string_literal: true

require 'fileutils'
require 'json'

module Mxrb
  module RubyApp
    # Adds an opt-in conventional Ruby framework around the generic MXRB Rack
    # backend. Presets never alter the default Ruby mode and never own Mendix
    # domain metadata; the Ruby application manifest remains authoritative.
    # rubocop:disable Metrics
    class Preset
      NAMES = %i[flymetothemoon onrails].freeze
      MARKER_PATH = File.join('config', 'mxrb_stack.rb')

      def self.apply!(root, name)
        new(root, name).apply!
      end

      def self.detect(root)
        path = File.join(root, MARKER_PATH)
        return unless File.file?(path)

        File.read(path)[/MXRB_RUBY_STACK\s*=\s*['"](flymetothemoon|onrails)['"]/, 1]
      end

      def self.manifest(name)
        selected = name.to_s
        {
          'preset' => selected, 'rack' => true, 'server' => 'puma',
          'web_framework' => selected == 'onrails' ? 'rails' : 'sinatra',
          'orm' => 'active_record', 'test' => 'rspec', 'tasks' => 'rake'
        }
      end

      def initialize(root, name)
        @root = File.expand_path(root)
        @name = name.to_sym
        raise ArgumentError, "Ruby stack must be #{NAMES.join(' or ')}" unless NAMES.include?(@name)

        @manifest = Manifest.load(@root)
        @namespace = ruby_constant(@manifest.data.dig('project', 'name'))
      end

      def apply!
        ensure_gems
        write(MARKER_PATH, marker_source, replace_baseline: true)
        name == :onrails ? write_rails : write_flymetothemoon
        update_manifest
        append_readme
        root
      end

      private

      attr_reader :root, :name, :manifest, :namespace

      def ensure_gems
        path = File.join(root, 'Gemfile')
        source = File.file?(path) ? File.read(path).rstrip : "source 'https://rubygems.org'"
        gems.each do |declaration|
          gem_name = declaration[/gem ['"]([^'"]+)/, 1]
          source += "\n#{declaration}" unless source.match?(/gem ['"]#{Regexp.escape(gem_name)}['"]/)
        end
        File.binwrite(path, "#{source}\n")
      end

      def gems
        common = [
          "gem 'rack', '~> 3.1'", "gem 'puma', '~> 7.0'",
          "gem 'activerecord', '~> 8.0'", "gem 'sqlite3', '~> 2.0'",
          "gem 'rake', '~> 13.2'", "gem 'rspec', '~> 3.13'",
          "gem 'rack-test', '~> 2.2'"
        ]
        if name == :onrails
          common + ["gem 'rails', '~> 8.0'", "gem 'rspec-rails', '~> 7.1'"]
        else
          common + ["gem 'sinatra', '~> 4.1'"]
        end
      end

      def write_flymetothemoon
        write('config.ru', fly_config_ru)
        write('config/environment.rb', fly_environment)
        write('config/puma.rb', puma_config)
        write('config/database.yml', database_yml)
        write('app/models/application_record.rb', application_record)
        write('app/web/application.rb', sinatra_application)
        write('db/migrate/.keep', '')
        write('Rakefile', fly_rakefile)
        write('.rspec', "--require spec_helper\n--format documentation\n")
        write('spec/spec_helper.rb', fly_spec_helper)
        write('spec/requests/health_spec.rb', fly_health_spec)
      end

      def write_rails
        write('config/boot.rb', rails_boot)
        write('config/application.rb', rails_application, replace_baseline: true)
        write('config/environment.rb', rails_environment)
        write('config/environments/development.rb', rails_development)
        write('config/environments/test.rb', rails_test)
        write('config/routes.rb', rails_routes)
        write('config/puma.rb', puma_config)
        write('config/database.yml', database_yml)
        write('config.ru', rails_config_ru)
        write('app/models/application_record.rb', application_record)
        write('app/controllers/application_controller.rb', rails_application_controller)
        write('app/controllers/health_controller.rb', rails_health_controller)
        write('db/migrate/.keep', '')
        write('Rakefile', rails_rakefile)
        write('bin/rails', rails_bin)
        FileUtils.chmod(0o755, File.join(root, 'bin', 'rails'))
        write('.rspec', "--require spec_helper\n--format documentation\n")
        write('spec/spec_helper.rb', rails_spec_helper)
        write('spec/rails_helper.rb', rails_helper)
        write('spec/requests/health_spec.rb', rails_health_spec)
      end

      def update_manifest
        path = File.join(root, MANIFEST_PATH)
        data = JSON.parse(File.read(path))
        data['ruby_stack'] = self.class.manifest(name)
        File.binwrite(path, JSON.pretty_generate(data) << "\n")
      end

      def append_readme
        path = File.join(root, 'README.md')
        text = File.file?(path) ? File.read(path) : ''
        heading = name == :onrails ? 'Rails preset' : 'Fly Me to the Moon preset'
        return if text.include?("## #{heading}")

        text += <<~MARKDOWN

          ## #{heading}

          This opt-in stack runs the MXRB backend through Rack and Puma while
          React + Vite remains the browser client. ActiveRecord owns only Ruby
          tables declared through its migrations; Mendix entities remain owned
          by the MXRB manifest so round-trips never have two schema authorities.

          ```sh
          bundle install
          bundle exec rake db:migrate
          bundle exec rspec
          bundle exec mxrb run .
          ```
        MARKDOWN
        File.binwrite(path, text)
      end

      def write(relative, contents, replace_baseline: false)
        path = File.join(root, relative)
        return if File.file?(path) && !(replace_baseline && baseline_file?(path))

        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, contents)
      end

      def baseline_file?(path)
        return true if path.end_with?(MARKER_PATH)

        File.read(path).include?('MXRB_APPLICATION_ROOT')
      rescue Errno::ENOENT
        true
      end

      def ruby_constant(value)
        result = value.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?).map do |part|
          part[0].upcase + part[1..].to_s
        end.join
        result = "Application#{result}" if result.empty? || result.match?(/\A\d/)
        result
      end

      def marker_source
        <<~RUBY
          # frozen_string_literal: true

          MXRB_RUBY_STACK = '#{name}' unless defined?(MXRB_RUBY_STACK)
        RUBY
      end

      def puma_config
        <<~RUBY
          # frozen_string_literal: true

          bind "tcp://\#{ENV.fetch('HOST', '127.0.0.1')}:\#{ENV.fetch('MXRB_SERVER_PORT', '9292')}"
          threads_count = Integer(ENV.fetch('RAILS_MAX_THREADS', '5'))
          threads threads_count, threads_count
          workers 0
          environment ENV.fetch('RACK_ENV', ENV.fetch('RAILS_ENV', 'development'))
        RUBY
      end

      def database_yml
        <<~YAML
          default: &default
            adapter: sqlite3
            pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>
            timeout: 5000

          development:
            <<: *default
            database: db/development.sqlite3

          test:
            <<: *default
            database: db/test.sqlite3

          production:
            <<: *default
            database: <%= ENV.fetch("DATABASE_PATH", "db/production.sqlite3") %>
        YAML
      end

      def application_record
        <<~RUBY
          # frozen_string_literal: true

          if defined?(ActiveRecord::Base) && !defined?(ApplicationRecord)
            class ApplicationRecord < ActiveRecord::Base
              primary_abstract_class
            end
          end
        RUBY
      end

      def fly_environment
        <<~RUBY
          # frozen_string_literal: true

          require 'bundler/setup'
          require 'yaml'
          require 'erb'
          require 'active_record'
          require 'mxrb'

          root = File.expand_path('..', __dir__)
          environment = ENV.fetch('RACK_ENV', 'development')
          settings = YAML.safe_load(ERB.new(File.read(File.join(root, 'config/database.yml'))).result,
                                    aliases: true).fetch(environment)
          ActiveRecord::Base.establish_connection(settings)
          require File.join(root, 'app/models/application_record')
        RUBY
      end

      def sinatra_application
        <<~RUBY
          # frozen_string_literal: true

          require 'json'
          require 'sinatra/base'

          module #{namespace}
            module Web
              class Application < Sinatra::Base
                set :show_exceptions, false

                get '/health' do
                  content_type :json
                  JSON.generate(ok: true, framework: 'sinatra')
                end
              end
            end
          end
        RUBY
      end

      def fly_config_ru
        <<~RUBY
          # frozen_string_literal: true

          require_relative 'config/environment'
          require_relative 'app/web/application'

          map '/ruby' do
            run #{namespace}::Web::Application
          end
          run Mxrb::RubyApp::RackAdapter.new(__dir__)
        RUBY
      end

      def fly_rakefile
        <<~RUBY
          # frozen_string_literal: true

          require_relative 'config/environment'
          require 'rake'
          require 'active_record/tasks/database_tasks'
          require 'rspec/core/rake_task'

          namespace :db do
            desc 'Run ActiveRecord migrations for Ruby-owned tables'
            task :migrate do
              ActiveRecord::MigrationContext.new('db/migrate').migrate
            end
          end

          RSpec::Core::RakeTask.new(:spec)
          task default: :spec
        RUBY
      end

      def fly_spec_helper
        <<~RUBY
          # frozen_string_literal: true

          ENV['RACK_ENV'] = 'test'
          require_relative '../config/environment'
          require 'rack/test'
          require 'rspec'

          RSpec.configure do |config|
            config.include Rack::Test::Methods
          end
        RUBY
      end

      def fly_health_spec
        <<~RUBY
          # frozen_string_literal: true

          require 'spec_helper'
          require_relative '../../app/web/application'

          RSpec.describe 'Ruby web health' do
            def app = #{namespace}::Web::Application

            it 'answers through Sinatra' do
              get '/health'
              expect(last_response).to be_ok
            end
          end
        RUBY
      end

      def rails_boot
        <<~RUBY
          # frozen_string_literal: true

          ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)
          require 'bundler/setup'
        RUBY
      end

      def rails_application
        <<~RUBY
          # frozen_string_literal: true

          require_relative 'boot'
          require 'rails/all'
          require 'mxrb'
          Bundler.require(*Rails.groups)

          module #{namespace}
            class Application < Rails::Application
              config.load_defaults 8.0
              config.autoload_lib(ignore: %w[assets tasks]) if config.respond_to?(:autoload_lib)
            end
          end
        RUBY
      end

      def rails_environment
        <<~RUBY
          # frozen_string_literal: true

          require_relative 'application'
          Rails.application.initialize!
        RUBY
      end

      def rails_development
        <<~RUBY
          # frozen_string_literal: true

          Rails.application.configure do
            config.enable_reloading = true
            config.eager_load = false
            config.consider_all_requests_local = true
            config.secret_key_base = ENV.fetch('SECRET_KEY_BASE', 'development-only-mxrb-secret')
          end
        RUBY
      end

      def rails_test
        <<~RUBY
          # frozen_string_literal: true

          Rails.application.configure do
            config.enable_reloading = false
            config.eager_load = false
            config.consider_all_requests_local = true
            config.secret_key_base = 'test-only-mxrb-secret'
          end
        RUBY
      end

      def rails_routes
        <<~RUBY
          # frozen_string_literal: true

          Rails.application.routes.draw do
            get '/ruby/health', to: 'health#show'
            mxrb_backend = Mxrb::RubyApp::RackAdapter.new(Rails.root.to_s)
            match '/api', to: mxrb_backend, via: :all
            match '/api/*path', to: mxrb_backend, via: :all
          end
        RUBY
      end

      def rails_config_ru
        <<~RUBY
          # frozen_string_literal: true

          require_relative 'config/environment'
          map '/api' do
            run Mxrb::RubyApp::RackAdapter.new(Rails.root.to_s)
          end
          run Rails.application
        RUBY
      end

      def rails_application_controller
        <<~RUBY
          # frozen_string_literal: true

          class ApplicationController < ActionController::Base
          end
        RUBY
      end

      def rails_health_controller
        <<~RUBY
          # frozen_string_literal: true

          class HealthController < ApplicationController
            def show
              render json: { ok: true, framework: 'rails' }
            end
          end
        RUBY
      end

      def rails_rakefile
        <<~RUBY
          # frozen_string_literal: true

          require_relative 'config/application'
          Rails.application.load_tasks
        RUBY
      end

      def rails_bin
        <<~RUBY
          #!/usr/bin/env ruby
          # frozen_string_literal: true

          APP_PATH = File.expand_path('../config/application', __dir__)
          require_relative '../config/boot'
          require 'rails/commands'
        RUBY
      end

      def rails_spec_helper
        <<~RUBY
          # frozen_string_literal: true

          require 'rspec'
        RUBY
      end

      def rails_helper
        <<~RUBY
          # frozen_string_literal: true

          ENV['RAILS_ENV'] ||= 'test'
          require_relative '../config/environment'
          require 'rspec/rails'
        RUBY
      end

      def rails_health_spec
        <<~RUBY
          # frozen_string_literal: true

          require 'rails_helper'

          RSpec.describe 'Ruby web health', type: :request do
            it 'answers through Rails' do
              get '/ruby/health'
              expect(response).to have_http_status(:ok)
            end

            it 'mounts the generic MXRB backend under /api' do
              get '/api/health'
              expect(response).to have_http_status(:ok)
              expect(response.parsed_body).to include('ok' => true)
            end
          end
        RUBY
      end
    end
    # rubocop:enable Metrics
  end
end
