# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Persisted System users' do
  let(:fixture) { 'spec/fixtures/native_system_users' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Users.mpr')
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

  def logged(interpreter)
    interpreter.instance_variable_get(:@log).to_h do |line|
      name, values = line.delete_prefix('ORACLE ').split('=', 2)
      [name, values.delete_suffix(',')]
    end
  end

  it 'matches the native Mendix 11.12.1 results from editable Ruby with MPR access prohibited' do
    app = application
    expect(app.call_service('Views.RunAll')).to be(true)
    logged = logged(app.send(:bridge).interpreter)
    expected.each { |name, value| expect(logged.fetch(name)).to eq(value), name }
  end

  it 'stores BCrypt hashes and never serializes them to the client' do
    app = application
    app.call_service('Views.Users')
    store = app.send(:bridge).store
    alice = store.retrieve('System.User').find { _1.members['Name'] == 'alice' }
    expect(alice.members['Password']).to match(Mxrb::Runtime::SystemDomain::BCRYPT)
    expect(app.send(:serialize, alice)[:attributes]).not_to have_key('Password')
    expect(app.send(:hashed_members, 'Views.Missing')).to eq([])
    roles = store.retrieve('System.UserRole')
    Mxrb::Runtime::SystemDomain.synchronize_roles(store, [{ name: 'Administrator', guid: 'renamed' },
                                                          { name: 'Renamed', guid: roles.first.members['ModelGUID'] }])
    expect(store.retrieve('System.UserRole').map { _1.members['Name'] }.sort).to eq(%w[Administrator Member Renamed])
  end
end

RSpec.describe Mxrb::Runtime::SystemDomain do
  it 'hashes once and verifies hashed or plain stored passwords' do
    hash = described_class.hash_password('Secret#1')
    expect(described_class.hash_password(hash)).to eq(hash)
    expect(described_class.password_matches?(hash, 'Secret#1')).to be(true)
    expect(described_class.password_matches?('plain', 'plain')).to be(true)
    expect(described_class.password_matches?('', 'x')).to be(false)
    expect(described_class.record_attributes('App.Other')).to eq([])
    expect(described_class.entity_schemas(described_class::ATTRIBUTES.keys)).to eq([])
  end

  it 'lets a registered adapter replace a platform Java action' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'Adapter.mpr')
      Mxrb.define(path) { self.module(:App) { entity(:Item) { string :Name } } }
      project = Mxrb.open(path)
      interpreter = Mxrb::Runtime::Native::Interpreter.new(
        project, java_custom_actions: { 'System.VerifyPassword' => ->(_arguments) { :adapter } }
      )
      action = { 'JavaAction' => 'System.VerifyPassword', 'ParameterMappings' => [2] }
      expect(interpreter.send(:action_java_action_call, action, {})).to eq(:adapter)
    ensure
      project&.close
    end
  end
end
# rubocop:enable Metrics/BlockLength
