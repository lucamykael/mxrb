# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The parts of a JavaActionContext the startup adapters use.
StartupActionContext = Struct.new(:store, :constants, :lines, keyword_init: true) do
  def constant(name) = constants.fetch(name)
  def log(node, level, message) = lines << [node, level, message]
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::KnownStartupActions do
  after do
    Mxrb::RubyApp::Registry.reset!
    described_class::STATE[:initialized] = false
  end

  let(:store) { Mxrb::Runtime::Native::Store.new }
  let(:context) { StartupActionContext.new(store:, constants: { 'UnitTesting.Enabled' => false }, lines: []) }

  def action(name, arguments = {})
    release = name.start_with?('UnitTesting') ? '10.0.4' : '3.3.1'
    described_class.register(name, release)
    Mxrb::RubyApp::Registry.java_custom_actions.fetch(name).handler.call(arguments, context:)
  end

  it 'registers an action only when it and its helpers match an audited release' do
    Dir.mktmpdir do |root|
      expect(described_class.registrations(root)).to eq('')
      write = lambda do |path, text|
        file = File.join(root, 'javasource', 'unittesting', "#{path}.java")
        FileUtils.mkdir_p(File.dirname(file))
        File.binwrite(file, text)
      end
      x = Digest::SHA256.hexdigest("x\n")
      stub_const("#{described_class}::MODULES",
                 'UnitTesting' => { root: 'unittesting', helpers: %w[ConfigurationManager],
                                    releases: { '1' => { 'ConfigurationManager' => x, 'actions/IsEnabled' => x } } },
                 'OIDC' => { root: 'oidc', helpers: [], releases: { '2' => {} } })
      write.call('actions/IsEnabled', "x\r\n")
      expect(described_class.registrations(root)).to eq('')
      write.call('ConfigurationManager', "x\n")
      expect(described_class.registrations(root))
        .to eq('Mxrb::RubyApp::KnownStartupActions.register("UnitTesting.IsEnabled", "1")')
    end
  end

  it 'refuses actions outside the audited releases' do
    expect { described_class.register('OIDC.CallCustomMicroflow', '3.3.1') }.to raise_error(KeyError)
    expect { described_class.register('UnitTesting.RunUnitTest', '10.0.4') }
      .to raise_error(KeyError, 'UnitTesting 10.0.4 RunUnitTest is not audited')
  end

  it 'starts unit testing only when the constant enables it' do
    expect(action('UnitTesting.IsEnabled')).to be(false)
    context.constants['UnitTesting.Enabled'] = true
    expect(action('UnitTesting.IsEnabled')).to be(true)
    expect(action('UnitTesting.IsInitialized')).to be(false)
    expect(action('UnitTesting.Initialize')).to be_nil
    expect(action('UnitTesting.IsInitialized')).to be(true)
    expect(action('UnitTesting.RegisterModelUpdateSubscriber')).to be(false)
    expect(context.lines).to eq([['UnitTestRunner', 'Debug',
                                  'Did not subscribe to model updates, not in local development']])
  end

  it 'deletes the authentication attempts older than the expiry' do
    attempts = [Time.now - 7200, Time.now - 10, nil].map do |created|
      store.create('OIDC.AuthAttempt').tap { _1.members['createdDate'] = created }
    end
    store.commit(attempts)
    expect(action('OIDC.DeleteExpiredAuthAttempts', 'expiresInMinutes' => 60, 'batchSize' => 2)).to be_nil
    expect(store.retrieve('OIDC.AuthAttempt')).to eq(attempts.drop(1))
    expect(action('OIDC.DeleteExpiredAuthAttempts', 'expiresInMinutes' => 60, 'batchSize' => 2)).to be_nil
    expect { action('OIDC.DeleteExpiredAuthAttempts', 'batchSize' => 2) }
      .to raise_error(Mxrb::Runtime::JavaActionError, 'expiresInMinutes is null')
    expect { action('OIDC.DeleteExpiredAuthAttempts', 'expiresInMinutes' => 1) }
      .to raise_error(Mxrb::Runtime::JavaActionError, 'batchSize is null')
  end
end
# rubocop:enable Metrics/BlockLength
