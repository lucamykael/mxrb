# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'spec_helper'
require 'stringio'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::Preset do
  def build(root, name, stack)
    Mxrb::Initializer.new(
      name, mode: :ruby, stack:, mxrb_path: File.expand_path('..', __dir__)
    ).scaffold(into: root).root
  end

  def manifest(root)
    JSON.parse(File.read(File.join(root, '.mxrb', 'ruby-app.json')))
  end

  it 'adds the full Sinatra stack without changing the generic MXRB backend' do
    Dir.mktmpdir do |dir|
      root = build(dir, 'moon_app', :flymetothemoon)
      expect(manifest(root).fetch('ruby_stack')).to include(
        'preset' => 'flymetothemoon', 'server' => 'puma',
        'web_framework' => 'sinatra', 'orm' => 'active_record'
      )
      expect(File.read(File.join(root, 'Gemfile'))).to include(
        "gem 'sinatra'", "gem 'puma'", "gem 'activerecord'", "gem 'rake'", "gem 'rspec'", "gem 'rack-test'"
      )
      expect(File).to exist(File.join(root, 'config.ru'))
      expect(File).to exist(File.join(root, 'app', 'web', 'application.rb'))
      expect(File).to exist(File.join(root, 'config', 'database.yml'))
      expect(File).to exist(File.join(root, 'spec', 'requests', 'health_spec.rb'))
      expect(File.read(File.join(root, 'config', 'puma.rb')))
        .to include("ENV.fetch('MXRB_SERVER_PORT', '9292')")
      expect(File.read(File.join(root, 'app', 'models', 'application_record.rb')))
        .to include('!defined?(ApplicationRecord)')

      adapter = Mxrb::RubyApp::RackAdapter.new(root)
      expect(adapter.instance_variable_get(:@server)).to be_nil
      status, headers, body = adapter.call(
        'PATH_INFO' => '/api/health', 'REQUEST_METHOD' => 'GET',
        'QUERY_STRING' => '', 'rack.input' => StringIO.new('')
      )
      expect(status).to eq(200)
      expect(headers.fetch('Content-Type')).to include('application/json')
      expect(JSON.parse(body.join)).to include('ok' => true)
      expect(adapter.instance_variable_get(:@server)).to be_a(Mxrb::RubyApp::Server)

      mounted_status, = adapter.call(
        'SCRIPT_NAME' => '/api', 'PATH_INFO' => '/health', 'REQUEST_METHOD' => 'GET',
        'QUERY_STRING' => '', 'rack.input' => StringIO.new('')
      )
      expect(mounted_status).to eq(200)
      adapter.close

      rebuilt = File.join(root, 'build', 'MoonApp.mpr')
      expect(Mxrb::RubyApp.compile(root, rebuilt)).to eq(rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid

      restored = File.join(dir, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      expect(manifest(restored).dig('ruby_stack', 'preset')).to eq('flymetothemoon')
      expect(File.read(File.join(restored, 'config.ru'))).to include('RackAdapter')
      expect(File).to exist(File.join(restored, 'spec', 'requests', 'health_spec.rb'))
    end
  end

  it 'adds a conventional Rails structure as a separate opt-in preset' do
    Dir.mktmpdir do |dir|
      root = build(dir, 'rails_portal', :onrails)
      expect(manifest(root).fetch('ruby_stack')).to include(
        'preset' => 'onrails', 'web_framework' => 'rails', 'server' => 'puma'
      )
      expect(File.read(File.join(root, 'Gemfile'))).to include(
        "gem 'rails'", "gem 'rspec-rails'", "gem 'activerecord'"
      )
      expect(File.read(File.join(root, 'config', 'application.rb'))).to include(
        'class Application < Rails::Application', 'require \'mxrb\''
      )
      expect(File.read(File.join(root, 'config', 'routes.rb'))).to include(
        "get '/ruby/health'", "match '/api/*path'", 'Mxrb::RubyApp::RackAdapter'
      )
      expect(File.read(File.join(root, 'config.ru'))).to include(
        "map '/api'", 'Mxrb::RubyApp::RackAdapter', 'run Rails.application'
      )
      expect(File.read(File.join(root, 'spec', 'requests', 'health_spec.rb')))
        .to include("get '/api/health'")
      expect(File).to exist(File.join(root, 'app', 'controllers', 'application_controller.rb'))
      expect(File).to exist(File.join(root, 'app', 'models', 'application_record.rb'))
      expect(File).to be_executable(File.join(root, 'bin', 'rails'))

      rebuilt = File.join(root, 'build', 'RailsPortal.mpr')
      expect(Mxrb::RubyApp.compile(root, rebuilt)).to eq(rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid

      restored = File.join(dir, 'restored_rails')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      expect(manifest(restored).dig('ruby_stack', 'preset')).to eq('onrails')
      expect(File).to be_executable(File.join(restored, 'bin', 'rails'))
    end
  end

  it 'keeps both presets exclusive, Ruby-only, and absent by default' do
    expect do
      Mxrb::Initializer.new('invalid', mode: :mendix, stack: :onrails)
    end.to raise_error(ArgumentError, /require --mode ruby/)

    Dir.mktmpdir do |dir|
      default_root = build(dir, 'plain_app', nil)
      expect(manifest(default_root)).not_to have_key('ruby_stack')

      %i[flymetothemoon onrails].each do |stack|
        root = build(dir, "ruby_only_#{stack}", stack)
        stack_files = %w[Gemfile Rakefile config.ru].map { File.join(root, _1) }
        stack_files.concat(Dir.glob(File.join(root, '{app,bin,config,spec}', '**', '*')))
        stack_files.select! { File.file?(_1) }

        expect(stack_files.grep(/\.(?:jar|java)\z/i)).to be_empty
        expect(stack_files.map { File.binread(_1) }.join("\n")).not_to match(/\b(?:java|jruby|jvm)\b/i)
      end

      command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'init', 'bad_app',
                 '--mode=ruby', '--flymetothemoon', '--onrails']
      _stdout, stderr, status = Open3.capture3(*command, chdir: dir)
      expect(status).not_to be_success
      expect(stderr).to include('Use only one of --flymetothemoon or --onrails')
    end
  end

  it 'switches existing presets without retaining the previous framework' do
    Dir.mktmpdir do |dir|
      root = build(dir, 'switchable_app', :flymetothemoon)

      Mxrb::RubyApp::Preset.apply!(root, :onrails)
      expect(manifest(root).dig('ruby_stack', 'preset')).to eq('onrails')
      expect(File.read(File.join(root, 'Gemfile'))).to include("gem 'rails'", "gem 'rspec-rails'")
      expect(File.read(File.join(root, 'Gemfile'))).not_to include("gem 'sinatra'")
      expect(File.read(File.join(root, 'config.ru'))).to include('Rails.application')
      expect(File).not_to exist(File.join(root, 'app', 'web', 'application.rb'))

      Mxrb::RubyApp::Preset.apply!(root, :flymetothemoon)
      expect(manifest(root).dig('ruby_stack', 'preset')).to eq('flymetothemoon')
      expect(File.read(File.join(root, 'Gemfile'))).to include("gem 'sinatra'")
      expect(File.read(File.join(root, 'Gemfile'))).not_to include("gem 'rails'", "gem 'rspec-rails'")
      expect(File.read(File.join(root, 'config.ru'))).to include('RackAdapter')
      expect(File.read(File.join(root, 'config', 'application.rb'))).to include('MXRB_APPLICATION_ROOT')
      expect(File).not_to exist(File.join(root, 'bin', 'rails'))
      expect(File).not_to exist(File.join(root, 'spec', 'rails_helper.rb'))
    end
  end

  it 'makes the supervisor select Puma and preserve the selected environment for both presets' do
    Dir.mktmpdir do |dir|
      %i[flymetothemoon onrails].each do |stack|
        root = build(dir, "puma_#{stack}", stack)
        File.write(File.join(root, 'config', 'environments', 'qa.env'), "STACK_PROFILE=qa-stack\n")
        environment = Mxrb::Environment.load('qa', root:, process: {})
        supervisor = Mxrb::RubyApp::Supervisor.new(
          root, api_port: 9494, frontend: false, environment:
        )

        expect(supervisor.send(:external_backend?)).to be(true)
        expect(Process).to receive(:spawn).with(
          {
            'STACK_PROFILE' => 'qa-stack', 'MXRB_ENV' => 'qa',
            'HOST' => '127.0.0.1', 'MXRB_SERVER_PORT' => '9494'
          },
          'bundle', 'exec', 'puma', '-C', 'config/puma.rb', chdir: root
        ).and_return(12_345)
        expect(supervisor.send(:spawn_backend)).to eq(12_345)
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
