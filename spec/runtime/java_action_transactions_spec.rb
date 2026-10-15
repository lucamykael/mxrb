# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Java action context in the interpreter' do
  around do |example|
    Dir.mktmpdir('mxrb-java-transactions-') do |root|
      @path = File.join(root, 'Tx.mpr')
      build(@path)
      @project = Mxrb::Model::Project.open(@path)
      example.run
    ensure
      @project&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def build(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Tx do
        entity(:Item) { string :Name }
        entity(:Draft) do
          non_persistent!
          string :Name
        end
        java_action :End, parameters: [], return_type: { kind: :boolean }
        java_action :Fail, parameters: [], return_type: { kind: :boolean }
        microflow :Ending do
          create_object 'Tx.Item', as: :item, set: { Name: "'sub'" }, commit: true
          call_java 'Tx.End', as: :ended
          log_message 'sub_end={1}', parameters: ['toString($ended)']
        end
        microflow :Guarded do
          call_microflow 'Tx.Ending'
          rescue_all { log_message 'never' }
        end
        microflow :Failing do
          call_java 'Tx.Fail', as: :failed
          rescue_all do
            log_message 'type={1}', parameters: ['$latestError/ErrorType']
            log_message 'message={1}', parameters: ['$latestError/Message']
          end
        end
        microflow :Root do
          call_microflow 'Tx.Guarded'
          call_microflow 'Tx.Failing'
          call_java 'Tx.End', as: :first
          log_message 'root_end={1}', parameters: ['toString($first)']
          call_java 'Tx.End', as: :second
          log_message 'again={1}', parameters: ['toString($second)']
          call_microflow 'Tx.Guarded'
          create_object 'Tx.Item', as: :late, set: { Name: "'late'" }, commit: true
          call_java 'Tx.Fail', as: :failed
        end
      end
    end
  end

  def interpreter(store: nil, fail: -> { raise 'plain failure' })
    adapters = {
      'Tx.End' => Mxrb::Runtime::Native::ContextJavaAction.new(->(_, context:) { context.end_transaction }),
      'Tx.Fail' => ->(_) { fail.call }
    }
    Mxrb::Runtime::Native::Interpreter.new(@project, store:, java_custom_actions: adapters)
  end

  it 'ends the transaction outside custom-handled calls and continues in autocommit' do
    runtime = interpreter
    expect { runtime.call('Tx.Root') }.to raise_error(RuntimeError, 'plain failure')
    expect(runtime.log).to eq(['sub_end=false', 'type=RuntimeError', 'message=plain failure', 'root_end=true',
                               'again=false', 'sub_end=false'])
    expect(runtime.store.retrieve('Tx.Item').map { _1.members['Name'] }).to eq(%w[sub sub late])
  end

  it 'reports a Java exception class as $latestError/ErrorType' do
    failure = -> { raise Mxrb::Runtime::JavaActionError.new('java.io.IOException', 'disk') }
    runtime = interpreter(fail: failure)
    runtime.call('Tx.Failing')
    expect(runtime.log).to eq(['type=java.io.IOException', 'message=disk'])
  end

  it 'commits the SQLite unit of work and keeps later commits after a failure' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'tx.sqlite3')
      store = Mxrb::Runtime::SQLiteStore.new(@project, path:)
      runtime = interpreter(store:)
      expect { runtime.call('Tx.Root') }.to raise_error(RuntimeError, 'plain failure')
      reader = SQLite3::Database.new(path)
      table = store.schema.entity('Tx.Item').table
      expect(reader.get_first_value(%(SELECT COUNT(*) FROM "#{table}"))).to eq(3)
      expect(store.retrieve('Tx.Item').size).to eq(3)
      expect(store.end_transaction).to be(false)
      expect(interpreter(store:).end_transaction).to be(false)
      draft = store.create('Tx.Draft')
      expect(store.changed?(draft)).to be(false)
      store.touch(draft)
      expect(store.changed?(draft)).to be(true)
    ensure
      reader&.close
      store&.close
    end
  end

  it 'leaves the transaction to stores without one and to sudo contexts no entity access' do
    store = Object.new
    def store.on(*) = self
    runtime = Mxrb::Runtime::Native::Interpreter.new(@project, store:)
    expect(runtime.end_transaction).to be(false)
    policy = instance_double(Mxrb::Runtime::AccessControl)
    sudo = Mxrb::Runtime::SecurityContext.new(attributes: { 'sudo' => true })
    guarded = Mxrb::Runtime::Native::Interpreter.new(@project, policy:)
    guarded.instance_variable_set(:@apply_entity_access, true)
    guarded.instance_variable_set(:@security_context, sudo)
    expect(guarded.send(:enforce_entity_access?)).to be(false)
    guarded.instance_variable_set(:@security_context, Mxrb::Runtime::SecurityContext.new)
    expect(guarded.send(:enforce_entity_access?)).to be(true)
    guarded.instance_variable_set(:@security_context, Object.new)
    expect(guarded.send(:enforce_entity_access?)).to be(true)
  end

  it 'registers context adapters explicitly and alone' do
    registry = Mxrb::RubyApp::Registry
    adapter = registry.register_java_custom_action('Tx.End', with_context: true) { true }
    expect(adapter).to be_a(Mxrb::Runtime::Native::ContextJavaAction)
    expect { registry.register_java_custom_action('Tx.End', with_store: true, with_context: true) { true } }
      .to raise_error(ArgumentError, 'choose with_store or with_context, not both')
  end
end

RSpec.describe Mxrb::Runtime::Native::Store do
  it 'tracks set members until commit or rollback' do
    store = described_class.new(defaults: { 'Tx.Item' => { 'Name' => '' } })
    item = store.create('Tx.Item')
    expect(store.changed?(item)).to be(false)
    item.members['Name'] = 'x'
    expect(store.changed?(item)).to be(true)
    item.members['Name'] = ''
    store.touch(item)
    expect(store.changed?(item)).to be(true)
    store.commit(item)
    expect(store.changed?(item)).to be(false)
    store.touch(item)
    store.rollback(item)
    expect(store.changed?(item)).to be(false)
    expect(described_class.new.changed?(described_class.new.create('Tx.Other'))).to be(false)
  end

  it 'keeps committed work after an end of transaction when the call fails' do
    store = described_class.new
    expect(store.end_transaction).to be(false)
    expect do
      store.transaction do
        store.commit(store.create('Tx.Item').tap { _1.members['Name'] = 'kept' })
        expect(store.end_transaction).to be(true)
        expect(store.end_transaction).to be(false)
        store.commit(store.create('Tx.Item').tap { _1.members['Name'] = 'later' })
        store.create('Tx.Item').members['Name'] = 'dropped'
        raise 'failed'
      end
    end.to raise_error(RuntimeError, 'failed')
    expect(store.retrieve('Tx.Item').map { _1.members['Name'] }).to eq(%w[kept later])
  end
end
# rubocop:enable Metrics/BlockLength
