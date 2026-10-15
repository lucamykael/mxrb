# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The fixture's Java actions, written as the Ruby adapters an exported application
# registers; Durable reads the database through its own connection.
JAVA_ACTION_RUNTIME_ADAPTERS = <<~RUBY
  registry = Mxrb::RubyApp::Registry
  registry.register_java_custom_action('Views.Fail') do |arguments|
    raise Mxrb::Runtime::JavaActionError.new('views.ProbeException', arguments['message'])
  end
  registry.register_java_custom_action('Views.FailRuntime') do |arguments|
    raise Mxrb::Runtime::JavaActionError.new('java.lang.RuntimeException', arguments['message'])
  end
  registry.register_java_custom_action('Views.ModelVersion', with_context: true) { |_, context:| context.model_version }
  registry.register_java_custom_action('Views.RuntimeVersion', with_context: true) { |_, context:| context.runtime_version }
  registry.register_java_custom_action('Views.IsChanged', with_context: true) do |arguments, context:|
    context.changed?(arguments.fetch('item'))
  end
  registry.register_java_custom_action('Views.EndTx', with_context: true) do |_, context:|
    context.end_transaction
    true
  end
  registry.register_java_custom_action('Views.Durable', with_context: true) do |arguments, context:|
    store = context.store
    entity = store.schema.entity('Views.Item')
    column = entity.columns.find { _1.name == 'Name' }.sql_name
    reader = SQLite3::Database.new(store.database.filename('main'))
    reader.get_first_value(%(SELECT COUNT(*) FROM "\#{entity.table}" WHERE "\#{column}" = ?), arguments.fetch('name'))
  ensure
    reader&.close
  end
RUBY

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Java action runtime semantics' do
  let(:fixture) { 'spec/fixtures/native_java_action_runtime' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))).fetch('results') }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'project', 'Runtime.mpr')
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

  it 'matches Mendix 11.12.1 from editable Ruby with MPR access prohibited' do
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    File.write(File.join(target, 'config', 'adapters.rb'), JAVA_ACTION_RUNTIME_ADAPTERS, mode: 'a')
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    process = { 'MXRB_DATABASE_PATH' => File.join(@directory, 'runtime.sqlite3') }
    @application = Mxrb::RubyApp::Application.new(target, process:)
    expect(@application.call_service('Views.RunAll')).to be(true)
    logged = @application.send(:bridge).interpreter.log.to_h { _1.delete_prefix('ORACLE ').split('=', 2) }
    expect(logged).to eq(expected)
  end
end
# rubocop:enable Metrics/BlockLength
