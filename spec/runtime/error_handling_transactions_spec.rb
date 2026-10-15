# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The fixture's Java actions as an exported application registers them; Durable
# reads the database through its own connection.
ERROR_HANDLING_ADAPTERS = <<~RUBY
  registry = Mxrb::RubyApp::Registry
  registry.register_java_custom_action('Views.Fail') do |arguments|
    raise Mxrb::Runtime::JavaActionError.new('views.ProbeException', arguments['message'])
  end
  registry.register_java_custom_action('Views.CommitThenFail', with_context: true) do |arguments, context:|
    item = context.store.create('Views.Item')
    item.members['Name'] = arguments.fetch('name')
    context.store.commit(item)
    raise Mxrb::Runtime::JavaActionError.new('views.ProbeException', 'after commit')
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
RSpec.describe 'Transactions around custom error handling' do
  let(:fixture) { 'spec/fixtures/native_error_handling_transactions' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))).fetch('results') }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'project', 'Errors.mpr')
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

  def logged(interpreter) = interpreter.log.to_h { _1.delete_prefix('ORACLE ').split('=', 2) }

  it 'matches Mendix 11.12.1 from editable Ruby with MPR access prohibited' do
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    File.write(File.join(target, 'config', 'adapters.rb'), ERROR_HANDLING_ADAPTERS, mode: 'a')
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    process = { 'MXRB_DATABASE_PATH' => File.join(@directory, 'errors.sqlite3') }
    @application = Mxrb::RubyApp::Application.new(target, process:)
    expect(@application.call_service('Views.RunAll')).to be(true)
    expect(logged(@application.send(:bridge).interpreter)).to eq(expected)
  end

  it 'keeps the in-transaction results in the memory store' do
    project = Mxrb::Model::Project.open(@source)
    load_adapters = Module.new { module_eval(ERROR_HANDLING_ADAPTERS) }
    expect(load_adapters).to be_a(Module)
    adapters = Mxrb::RubyApp::Registry.java_custom_actions.reject { _1 == 'Views.Durable' }
    adapters['Views.Durable'] = Mxrb::Runtime::Native::ContextJavaAction.new(->(*, context:) { context && -1 })
    runtime = Mxrb::Runtime::Native::Interpreter.new(project, java_custom_actions: adapters)
    expect(runtime.call('Views.RunAll')).to be(true)
    seen = logged(runtime).select { |key, _| key.start_with?('seen_') || key.end_with?('_caught') }
    expect(seen).to eq(expected.select { |key, _| key.start_with?('seen_') || key.end_with?('_caught') })
    expect(runtime.store.retrieve('Views.Item').map { _1.members['Name'] }.sort).to eq(%w[C H J S Z])
  ensure
    project&.close
  end
end
# rubocop:enable Metrics/BlockLength

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Error handling savepoints in the stores' do
  around do |example|
    Dir.mktmpdir('mxrb-savepoints-') do |root|
      @path = File.join(root, 'Points.mpr')
      Mxrb.define(@path) do
        mendix_version '11.12.1'
        self.module(:Views) { entity(:Item) { string :Name } }
      end
      @project = Mxrb::Model::Project.open(@path)
      example.run
    ensure
      @project&.close
    end
  end

  def item(store, name) = store.create('Views.Item').tap { _1.members['Name'] = name }
  def names(store) = store.retrieve('Views.Item').map { _1.members['Name'] }.sort

  it 'voids memory savepoints after a restart and restarts only a running transaction' do
    store = Mxrb::Runtime::Native::Store.new
    store.restart_transaction
    store.transaction do
      store.commit(item(store, 'kept'))
      token = store.savepoint
      store.commit(item(store, 'undone'))
      store.restart_transaction
      store.commit(item(store, 'after'))
      store.rollback_savepoint(token)
      expect(names(store)).to eq(%w[after])
      store.end_transaction
      store.restart_transaction
      expect(names(store)).to eq(%w[after])
    end
  end

  it 'commits a SQLite transaction of its own and voids stale savepoints' do
    store = Mxrb::Runtime::SQLiteStore.new(@project)
    store.restart_transaction
    own = store.savepoint
    store.commit(item(store, 'own'))
    store.release_savepoint(own)
    expect(store.database.transaction_active?).to be(false)
    store.transaction do
      inner = store.savepoint
      store.commit(item(store, 'void'))
      store.restart_transaction
      store.release_savepoint(inner)
      store.rollback_savepoint(inner)
      store.commit(item(store, 'fresh'))
    end
    expect(names(store)).to eq(%w[fresh own])
  ensure
    store&.close
  end
end
# rubocop:enable Metrics/BlockLength
