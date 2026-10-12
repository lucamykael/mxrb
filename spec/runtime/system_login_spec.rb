# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Signing in with persisted System users' do
  let(:fixture) { 'spec/fixtures/native_system_login' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Login.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load File.join(fixture, 'project.rb')
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def application
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: { 'MXRB_DATABASE_PATH' => ':memory:' })
  end

  def status(app, user, password)
    app.session_manager.login(user, password)
    200
  rescue Mxrb::RubyApp::AuthenticationError
    401
  end

  it 'matches the native Mendix 11.12.1 sign-in statuses and user states' do
    app = application
    app.call_service('Views.Setup')
    clock = Time.utc(2026, 10, 10, 12)
    app.session_manager.instance_variable_set(:@clock, -> { clock })
    expected.each do |step|
      name = step.fetch('step')
      if name.start_with?('Wait')
        clock += name.delete_prefix('Wait').to_i
        next
      end
      if step.key?('status')
        user, password = step.values_at('user', 'password')
        expect(status(app, user, password)).to eq(step.fetch('status')), name
      end
      expect(app.call_service('Views.Users')).to eq(step.fetch('users')), name
    end
  end

  it 'binds the signed-in user to sessions and $currentUser and keeps configured users first' do
    app = application
    app.call_service('Views.Setup')
    session = app.session_manager.login('ALICE', 'Secret#1')
    context = app.session_manager.authenticate("Bearer #{session.fetch(:token)}")
    alice = app.send(:bridge).store.retrieve('System.User').find { _1.members['Name'] == 'alice' }
    expect(context.user).to eq(alice.id)
    expect(context.user_roles).to eq(['Member'])
    expect(app.send(:bridge).interpreter.call('Views.Me', context:)).to eq('alice')
    expect(app.send(:bridge).interpreter.call('Views.Me')).to eq('<anonymous>')
    configured = Mxrb::RubyApp::SessionManager.new(
      app.access_control, users: JSON.generate('alice' => { 'password' => 'json', 'roles' => ['Member'] }),
                          directory: -> { app.send(:bridge).store }
    )
    expect(configured.login('alice', 'json')[:user]).to eq('alice')
    expect { configured.login('alice', 'Secret#1') }.to raise_error(Mxrb::RubyApp::AuthenticationError)
    expect(configured.login('gina', 'Secret#1')[:user]).not_to eq('gina')
    standalone = Mxrb::RubyApp::SessionManager.new(app.access_control, users: nil)
    expect { standalone.login('gina', 'Secret#1') }.to raise_error(Mxrb::RubyApp::AuthenticationError)
  end
end
# rubocop:enable Metrics/BlockLength
