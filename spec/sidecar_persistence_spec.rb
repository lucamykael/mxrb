# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Objects the Java actions sidecar instantiates, changes and commits through its
# callbacks stay known to the store across nested microflow calls, request
# handlers and transaction ends, and a REST operation's object parameter can be
# committed by the microflow it is handed to.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Java sidecar persistence' do
  around do |example|
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'project', 'Runtime.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = source
      load 'spec/fixtures/java_action_sidecar/project.rb'
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      @application = Mxrb::RubyApp::Application.new(
        target, process: { 'MXRB_DATABASE_PATH' => File.join(directory, 'runtime.sqlite3') }
      )
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  let(:bridge) { @application.send(:bridge) }
  let(:interpreter) { bridge.interpreter }
  let(:store) { bridge.store }

  # A sidecar whose Java side is a Ruby block driving the session callbacks.
  def sidecar(&script)
    services = bridge.sidecar_services
    fake = Class.new do
      define_method(:invoke) do |_name, _parameters, context:, http: nil| # rubocop:disable Lint/UnusedBlockArgument
        script.call(Mxrb::Runtime::JavaSidecar::Session.new(context, services))
      end
      define_method(:request) do |_handler, _request, session:, context:| # rubocop:disable Lint/UnusedBlockArgument
        script.call(Mxrb::Runtime::JavaSidecar::Session.new(context, services))
      end
    end.new
    interpreter.instance_variable_set(:@java_sidecar, fake)
  end

  def callback(session, method, params = {})
    answer = session.answer('id' => 1, 'method' => method, 'params' => params)
    raise "#{method}: #{answer['error']}" if answer['error']

    answer['result']
  end

  def labels = store.retrieve('Views.Tag').map { _1.members['Label'] }

  it 'keeps objects Java instantiates and commits around nested microflows and changes' do
    sidecar do |session|
      object = callback(session, 'instantiate', 'entity' => 'Views.Tag')
      callback(session, 'microflow', 'name' => 'Views.Remember', 'arguments' => { 'Value' => 'nested' })
      callback(session, 'set', 'object' => object, 'member' => 'Label', 'value' => 'java')
      callback(session, 'commit', 'objects' => [object])
      'nonce'
    end
    expect(interpreter.call('Views.ReadNonce', {})).to eq('nonce')
    expect(labels).to contain_exactly('nested', 'java')

    tag = store.retrieve('Views.Tag').find { _1.members['Label'] == 'java' }
    tag.members['Label'] = 'ruby'
    store.transaction { store.commit(tag) }
    sidecar do |session|
      object = callback(session, 'retrieve', 'xpath' => "//Views.Tag[Label = 'ruby']").first
      callback(session, 'set', 'object' => object, 'member' => 'Label', 'value' => 'java again')
      callback(session, 'microflow', 'name' => 'Views.Remember', 'arguments' => { 'Value' => 'later' })
      callback(session, 'commit', 'objects' => [object])
      'nonce'
    end
    interpreter.call('Views.ReadNonce', {})
    expect(labels).to contain_exactly('nested', 'java again', 'later')
  end

  it 'commits objects created before and after IContext.endTransaction and in request handlers' do
    sidecar do |session|
      before = callback(session, 'instantiate', 'entity' => 'Views.Tag')
      callback(session, 'set', 'object' => before, 'member' => 'Label', 'value' => 'before')
      callback(session, 'end_transaction')
      after = callback(session, 'instantiate', 'entity' => 'Views.Tag')
      callback(session, 'set', 'object' => after, 'member' => 'Label', 'value' => 'after')
      callback(session, 'commit', 'objects' => [after, before])
      'nonce'
    end
    interpreter.call('Views.ReadNonce', {})
    expect(labels).to contain_exactly('before', 'after')

    sidecar do |session|
      object = callback(session, 'instantiate', 'entity' => 'Views.Tag')
      callback(session, 'microflow', 'name' => 'Views.Remember', 'arguments' => { 'Value' => 'handler flow' })
      callback(session, 'set', 'object' => object, 'member' => 'Label', 'value' => 'handler')
      callback(session, 'commit', 'objects' => [object])
      { 'status' => 200 }
    end
    interpreter.java_request('nonce', { 'method' => 'GET', 'path' => '/nonce' }, context: nil)
    expect(labels).to contain_exactly('before', 'after', 'handler flow', 'handler')
  end

  it 'lets a microflow commit the object a REST operation received' do
    parameter = { 'name' => 'Tag', 'entity' => 'Views.Tag', 'required' => true }
    object = @application.send(:deserialize_rest_value, { 'Label' => 'from rest' }, parameter)
    expect(object.members).to include('Label' => 'from rest')
    expect(store.find('Views.Tag', object.id)).to equal(object)
    store.transaction { store.commit(object) }
    expect(labels).to eq(['from rest'])
  end
end
# rubocop:enable Metrics/BlockLength
