# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The parts of a JavaActionContext the adapters use.
CommunityCommonsContext = Struct.new(:store, :lines, :flows, :calls, :ended, :files, :entities, keyword_init: true) do
  def log(node, level, message) = lines << [node, level, message]
  def flow?(name) = flows.include?(name)

  def call_flow(name, arguments, username:, sudo:)
    calls << [name, arguments, username, sudo]
    flows.fetch(name)
  end

  def end_transaction = self.ended = true
  def changed?(object) = object.members.key?('changed')
  def file_content(object) = files.fetch(object.id)
  def application_root_url = 'http://app.example/'
  def model_version = 'unversioned'
  def runtime_version = '11.12.1'
  def attributes(entity) = entities.fetch(entity)
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::KnownCommunityCommonsActions do
  after do
    Mxrb::RubyApp::Registry.reset!
    described_class::TIMERS.clear
  end

  let(:store) { Mxrb::Runtime::Native::Store.new }
  let(:context) do
    CommunityCommonsContext.new(store:, lines: [], flows: {}, calls: [], ended: false, files: {}, entities: {})
  end

  def action(name, arguments = {}, release = '11.5.1')
    described_class.register(name, release)
    Mxrb::RubyApp::Registry.java_custom_actions.fetch("CommunityCommons.#{name}")
                           .handler.call(arguments, context:)
  end

  def java_error(java_class, message)
    raise_error(Mxrb::Runtime::JavaActionError) do |error|
      expect([error.java_class, error.message]).to eq([java_class, message])
    end
  end

  def object(entity = 'Mod.Thing', **members)
    Mxrb::Runtime::Native::ObjectValue.new(entity:, id: SecureRandom.uuid, members: members.transform_keys(&:to_s))
  end

  describe '.registrations' do
    def write(root, path, source)
      file = File.join(root, 'javasource', 'communitycommons', path)
      FileUtils.mkdir_p(File.dirname(file))
      File.binwrite(file, source)
    end

    it 'enables an action only when its source and helpers match one audited release' do
      x = Digest::SHA256.hexdigest("x\n")
      y = Digest::SHA256.hexdigest("y\n")
      stub_const("#{described_class}::RELEASES",
                 'old' => { 'StringUtils' => y, 'Base64Encode' => x, 'StringTrim' => x },
                 'new' => { 'StringUtils' => x, 'Base64Encode' => x, 'Hash' => x, 'EndTransaction' => x })
      Dir.mktmpdir do |root|
        expect(described_class.registrations(root)).to eq('')
        write(root, 'actions/Base64Encode.java', "x\r\n")
        write(root, 'actions/Hash.java', "x\n")
        write(root, 'actions/StringTrim.java', "x\n")
        write(root, 'actions/EndTransaction.java', "changed\n")
        expect(described_class.registrations(root)).to eq(
          'Mxrb::RubyApp::KnownCommunityCommonsActions.register("StringTrim", "old")'
        )
        write(root, 'StringUtils.java', "x\n")
        expect(described_class.registrations(root).lines.map(&:strip)).to eq(
          ['Mxrb::RubyApp::KnownCommunityCommonsActions.register("Base64Encode", "new")',
           'Mxrb::RubyApp::KnownCommunityCommonsActions.register("Hash", "new")',
           'Mxrb::RubyApp::KnownCommunityCommonsActions.register("StringTrim", "old")']
        )
      end
    end

    it 'audits every action it implements in a release' do
      described_class::RELEASES.each_value do |sources|
        actions = sources.keys - described_class::HELPERS.values.flatten
        expect(actions - described_class::ACTIONS.keys).to eq([])
        actions.each { expect(described_class::HELPERS.fetch(_1, []) - sources.keys).to eq([]) }
      end
    end
  end

  it 'refuses actions that are not audited in the release' do
    expect { described_class.register('Hash', '9.0.1') }.to raise_error(KeyError, /9\.0\.1 Hash is not audited/)
  end

  it 'encodes, hashes and reports the application like the module' do
    expect(action('Base64Encode', 'value' => 'ação')).to eq('YcOnw6Nv')
    expect(action('Base64Encode', 'value' => nil)).to be_nil
    expect(action('EndTransaction')).to be(true)
    expect(context.ended).to be(true)
    expect(action('GetApplicationUrl')).to eq('http://app.example')
    expect(action('GetModelVersion')).to eq('unversioned')
    expect(action('GetRuntimeVersion')).to eq('11.12.1')
    expect(action('Hash', 'value' => 'abc', 'length' => 4))
      .to eq('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    expect { action('Hash', 'value' => nil) }.to java_error('java.lang.NullPointerException', 'value is null')
    expect(action('RandomHash')).to match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/)
  end

  it 'draws random strings and strong passwords with the module bounds' do
    expect(action('RandomString', 'length' => 12)).to match(/\A[A-Za-z0-9]{12}\z/)
    expect(action('RandomString', 'length' => 2**32 + 3).length).to eq(3)
    expect { action('RandomString', 'length' => -1) }
      .to java_error('java.lang.IllegalArgumentException',
                     'The requested length for the random string was negative: -1')
    expect { action('RandomString', 'length' => nil) }.to java_error('java.lang.NullPointerException', 'length is null')

    password = action('RandomStrongPassword', 'MinLength' => 8, 'MaxLength' => 10, 'NrOfCapitalizedCharacters' => 2,
                                              'NrOfDigits' => 2, 'NrOfSpecialCharacters' => 1)
    expect(password.length).to be_between(8, 10)
    expect([password.count('A-Z'), password.count('0-9'), password.count('!-/')]).to all(be >= 1)
    expect(action('RandomStrongPassword', 'MinLength' => 3, 'MaxLength' => 3)).to match(/\A[A-Za-z0-9]{3}\z/)
    expect do
      action('RandomStrongPassword', { 'MinLength' => nil, 'MaxLength' => 3 }, '9.0.1')
    end.to java_error('java.lang.NullPointerException', 'MinLength is null')
    expect { action('RandomStrongPassword', 'MinLength' => 4, 'MaxLength' => 3) }
      .to java_error('java.lang.IllegalArgumentException', 'Min. Length > Max. Length!')
    {
      '11.5.1' => '(CAPS, LOWER, DIGITS, SPL CHARS)', '9.0.1' => '(CAPS, DIGITS, SPL CHARS)'
    }.each do |release, parts|
      arguments = { 'MinLength' => 2, 'MaxLength' => 3, 'NrOfCapitalizedCharacters' => 2, 'NrOfDigits' => 1,
                    'NrOfSpecialCharacters' => 0 }
      expect { action('RandomStrongPassword', arguments, release) }
        .to java_error('java.lang.IllegalArgumentException', "Min. Length should be atleast sum of #{parts} Length!")
    end
    expect { action('RandomStrongPassword', 'MinLength' => 2**31, 'MaxLength' => 2**31) }
      .to java_error('java.lang.IllegalArgumentException',
                     '2147483648 cannot be cast to int without changing its value.')
  end

  it 'reads file contents in the chosen encoding, dropping a UTF-8 mark only from 10.x' do
    file = object('System.FileDocument')
    context.files[file.id] = "\xEF\xBB\xBFol\xC3\xA1".b
    expect(action('StringFromFile', 'source' => nil)).to be_nil
    expect(action('StringFromFile', 'source' => file)).to eq('olá')
    expect(action('StringFromFile', { 'source' => file }, '9.0.1')).to eq('﻿olá')
    expect(action('StringFromFile', 'source' => file, 'encoding' => 'CommunityCommons.StandardEncodings.ISO_8859_1'))
      .to eq('olÃ¡')
    context.files[file.id] = "\xFF\xFEo\x00k\x00".b
    expect(action('StringFromFile', 'source' => file, 'encoding' => 'UTF_16')).to eq('ok')
    context.files[file.id] = "\xFE\xFF\x00o\x00k".b
    expect(action('StringFromFile', 'source' => file, 'encoding' => 'UTF_16')).to eq('ok')
    context.files[file.id] = "\x00o\x00k".b
    expect(action('StringFromFile', 'source' => file, 'encoding' => 'UTF_16')).to eq('ok')
    context.files[file.id] = "\xFFok".b
    expect(action('StringFromFile', 'source' => file, 'encoding' => 'US_ASCII')).to eq('�ok')
    expect { action('StringFromFile', 'source' => file, 'encoding' => 'EBCDIC') }
      .to java_error('java.lang.IllegalArgumentException', 'unknown encoding EBCDIC')
  end

  it 'pads, splits and trims like commons-lang and String.split' do
    expect(action('StringLeftPad', 'value' => nil, 'amount' => 3)).to be_nil
    expect(action('StringLeftPad', 'value' => '7', 'amount' => 3, 'fillCharacter' => '0')).to eq('007')
    expect(action('StringLeftPad', 'value' => '7', 'amount' => 6, 'fillCharacter' => 'ab')).to eq('ababa7')
    expect(action('StringLeftPad', 'value' => '7', 'amount' => 3, 'fillCharacter' => '')).to eq('  7')
    expect(action('StringLeftPad', 'value' => 'long', 'amount' => 2)).to eq('long')
    expect { action('StringLeftPad', 'value' => '7') }.to java_error('java.lang.NullPointerException', 'amount is null')

    split = ->(input, pattern) { action('StringSplit', 'inputString' => input, 'splitParameter' => pattern) }
    parts = split.call('a,b,,c,,', ',')
    expect(parts.map { [_1.entity, _1.members['Value'], _1.members['Index']] })
      .to eq([['CommunityCommons.SplitItem', 'a', 0], ['CommunityCommons.SplitItem', 'b', 1],
              ['CommunityCommons.SplitItem', '', 2], ['CommunityCommons.SplitItem', 'c', 3]])
    expect(store.retrieve('CommunityCommons.SplitItem').size).to eq(4)
    values = ->(input, pattern) { split.call(input, pattern).map { _1.members['Value'] } }
    expect(values.call('', ',')).to eq([''])
    expect(values.call('abc', ';')).to eq(['abc'])
    expect(values.call(',,', ',')).to eq([])
    expect(values.call('ab', '')).to eq(%w[a b])
    expect(values.call('a1b22c', '(\d)+')).to eq(%w[a b c])
    expect { split.call(nil, ',') }.to java_error('java.lang.NullPointerException', 'inputString is null')
    expect { split.call('a', nil) }.to java_error('java.lang.NullPointerException', 'splitParameter is null')

    expect(action('StringTrim', 'value' => nil)).to eq('')
    expect(action('StringTrim', 'value' => "\t\u0000 a b \n")).to eq('a b')
  end

  it 'throws a UserThrownException and measures timers on the CommunityCommons log node' do
    expect { action('ThrowException', 'message' => 'stop') }
      .to java_error('communitycommons.UserThrownException', 'stop')
    expect { action('ThrowException', 'message' => nil) }.to java_error('communitycommons.UserThrownException', '')

    expect(action('TimeMeasureStart', 'TimerName' => 'load')).to be(true)
    taken = action('TimeMeasureEnd', 'TimerName' => 'load', 'Loglevel' => 'CommunityCommons.LogLevel.Info',
                                     'message' => nil)
    expect(taken).to be >= 0
    expect(context.lines).to eq([['CommunityCommons', 'Info', "Timer load finished in #{taken} ms. null"]])
    expect { action('TimeMeasureEnd', 'TimerName' => nil, 'Loglevel' => 'Info') }
      .to java_error('java.lang.IllegalArgumentException', 'Timer with key null not found')
    expect { action('TimeMeasureEnd', 'TimerName' => 'save', 'Loglevel' => 'Info') }
      .to java_error('java.lang.IllegalArgumentException', 'Timer with key save not found')
    action('TimeMeasureStart', 'TimerName' => 'save')
    action('TimeMeasureEnd', 'TimerName' => 'save', 'Loglevel' => 'Debug', 'message' => 'done')
    expect(context.lines.last).to match(['CommunityCommons', 'Debug', /\ATimer save finished in \d+ ms\. done\z/])
    expect { action('TimeMeasureEnd', 'TimerName' => 'load', 'Loglevel' => nil) }
      .to java_error('java.lang.NullPointerException', 'Loglevel is null')
  end

  it 'copies stored attributes and reports changes' do
    source = object('Mod.Source', 'Name' => 'n', 'Number' => 3, 'Total' => 9, 'Only' => 1, 'Link' => 'x')
    target = object('Mod.Target', 'Name' => 'old', 'Number' => 1, 'Total' => 2)
    context.entities.merge!(
      'Mod.Source' => [['Name', :string, false], ['Number', :autonumber, false], ['Total', :decimal, false],
                       ['Only', :integer, false]],
      'Mod.Target' => [['Name', :string, false], ['Number', :autonumber, false], ['Total', :decimal, true],
                       ['Missing', :string, false]]
    )
    store.commit(target)
    expect(store.changed?(target)).to be(false)
    expect(action('copyAttributes', 'source' => source, 'target' => target)).to be(true)
    expect(target.members).to eq('Name' => 'n', 'Number' => 1, 'Total' => 2)
    expect(store.changed?(target)).to be(true)
    expect { action('copyAttributes', 'source' => nil, 'target' => target) }
      .to java_error('java.lang.IllegalStateException', 'source is null')
    expect { action('copyAttributes', 'source' => source, 'target' => nil) }
      .to java_error('java.lang.IllegalStateException', 'target is null')
    plain = CommunityCommonsContext.new(store: Object.new, entities: context.entities)
    expect(described_class.copy_attributes({ 'source' => source, 'target' => target }, plain, '11.5.1')).to be(true)

    expect(action('objectHasChanged', 'item' => object('Mod.Thing', 'changed' => 1))).to be(true)
    expect(action('objectHasChanged', 'item' => object)).to be(false)
    expect { action('objectHasChanged', 'item' => nil) }
      .to java_error('java.lang.IllegalArgumentException', 'The provided object is empty')
  end

  it 'runs a microflow as another user with its named arguments' do
    context.flows.merge!('Mod.Flow' => 42, 'Mod.Empty' => nil)
    first = object
    result = action('executeUnverifiedMicroflowAsUser_2',
                    'microflowName' => 'Mod.Flow', 'username' => 'ann', 'sudoContext' => true,
                    'arg1name' => 'First', 'arg1value' => first, 'arg2name' => nil, 'arg2value' => object)
    expect(result).to eq('42')
    expect(context.calls).to eq([['Mod.Flow', { 'First' => first }, 'ann', true]])
    expect(action('executeUnverifiedMicroflowAsUser_2', 'microflowName' => 'Mod.Empty', 'username' => 'ann'))
      .to be_nil
    expect(context.calls.last).to eq(['Mod.Empty', {}, 'ann', false])
    expect { action('executeUnverifiedMicroflowAsUser_2', 'microflowName' => '', 'username' => 'ann') }
      .to java_error('java.lang.Exception', 'Assertion: No context provided')
    expect { action('executeUnverifiedMicroflowAsUser_2', 'microflowName' => 'Mod.Other', 'username' => 'ann') }
      .to java_error('java.lang.Exception', 'Assertion: microflow not found: Mod.Other')
    expect { action('executeUnverifiedMicroflowAsUser_2', 'microflowName' => 'Mod.Flow', 'username' => nil) }
      .to java_error('java.lang.RuntimeException', 'Assertion: No username provided')
  end
end
# rubocop:enable Metrics/BlockLength
