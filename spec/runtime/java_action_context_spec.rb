# frozen_string_literal: true

require 'spec_helper'
require 'sqlite3'

# Model shapes the context reads: native entities with a generalization, Ruby ones without.
ContextModule = Struct.new(:name, :entities, :constants, :associations)
ContextAssociation = Struct.new(:name, :association_type)
ContextEntity = Struct.new(:name, :attributes, :generalization_target)
ContextAttribute = Struct.new(:name, :type, :raw_value_doc)
PlainEntity = Struct.new(:name, :attributes)

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::JavaActionContext do
  let(:store) { Mxrb::Runtime::Native::Store.new }
  let(:interpreter) { instance_double(Mxrb::Runtime::Native::Interpreter) }
  let(:project) do
    calculated = { '$Type' => 'DomainModels$CalculatedValue' }
    entities = [
      ContextEntity.new('Base', [ContextAttribute.new('Code', :string, nil)], 'System.User'),
      ContextEntity.new('Item', [ContextAttribute.new('Name', :string, {}),
                                 ContextAttribute.new('Total', :decimal, calculated)], 'Mod.Base'),
      ContextEntity.new('Loop', [], 'Mod.Loop'),
      ContextEntity.new('Upload', [], 'System.FileDocument'),
      ContextEntity.new('Lone', [ContextAttribute.new('Name', :string, nil),
                                 ContextAttribute.new('Count', :integer, nil)], nil)
    ]
    associations = [ContextAssociation.new('Item_Base', :Reference), ContextAssociation.new('Item_Lone', :ReferenceSet)]
    Struct.new(:modules, :mendix_version).new(
      [ContextModule.new('Mod', entities, [], associations),
       ContextModule.new('Ruby', [PlainEntity.new('Row', [ContextAttribute.new('A', :integer)])], [], [])],
      '11.12.1'
    )
  end
  let(:lines) { [] }

  def context(security_context: nil, policy: nil, environment: {}, store: self.store)
    described_class.new(interpreter:, store:, log: lines, project:, flows: ['Mod.Flow'],
                        security_context:, policy:, environment:)
  end

  def user(name, roles = [])
    role_objects = roles.map { |name| store.create('System.UserRole').tap { |role| role.members['Name'] = name } }
    store.create('System.User').tap { _1.members.merge!('Name' => name, 'UserRoles' => role_objects) }
  end

  it 'logs on a Mendix log node at the CommunityCommons levels' do
    expect(context.log('Node', 'Warning', 'careful')).to be_nil
    expect(lines).to eq(['Node Warning: careful'])
    expect { context.log('Node', 'Loud', 'x') }.to raise_error(ArgumentError, /unknown log level "Loud"/)
  end

  it 'calls flows as the current user, as another user and in a sudo context' do
    expect(context.flow?('Mod.Flow')).to be(true)
    expect(context.flow?('Mod.Other')).to be(false)
    expect { context.call_flow('Mod.Other') }.to raise_error(ArgumentError, 'microflow not found: Mod.Other')

    current = user('ann')
    other = user('bob', %w[Admin])
    session = Mxrb::Runtime::SecurityContext.new(user: current.id, attributes: { 'time_zone' => 'UTC' })
    received = []
    allow(interpreter).to receive(:call) { |name, arguments, context:| received << [name, arguments, context] }

    context(security_context: session).call_flow('Mod.Flow', { 'A' => 1 })
    context(security_context: session).call_flow('Mod.Flow', {}, username: 'ann', sudo: true)
    context(security_context: session).call_flow('Mod.Flow', {}, username: 'BOB', sudo: true)
    expect(received[0]).to eq(['Mod.Flow', { 'A' => 1 }, session])
    expect(received[1].last).to be(session)
    expect(received[2].last).to have_attributes(user: other.id, user_roles: %w[Admin],
                                                attributes: { 'time_zone' => 'UTC', 'sudo' => true })

    policy = instance_double(Mxrb::Runtime::AccessControl)
    expect(policy).to receive(:context).with(user: other.id, user_roles: %w[Admin], attributes: { 'sudo' => false })
                                       .and_return(:expanded)
    context(policy:).call_flow('Mod.Flow', {}, username: 'bob')
    expect(received.last.last).to eq(:expanded)

    expect { context.call_flow('Mod.Flow', {}, username: '') }
      .to raise_error(ArgumentError, 'Assertion: No username provided')
    expect { context.call_flow('Mod.Flow', {}, username: 'nobody') }
      .to raise_error(ArgumentError, 'Assertion: user not found: nobody')
    anonymous = Mxrb::Runtime::SecurityContext.new(user: 42)
    context(security_context: anonymous).call_flow('Mod.Flow', {}, username: 'ann')
    expect(received.last.last).to have_attributes(user: current.id)
  end

  it 'delegates transactions and change tracking' do
    expect(interpreter).to receive(:end_transaction).and_return(true)
    expect(context.end_transaction).to be(true)
    item = store.create('Mod.Item')
    expect(context.changed?(item)).to be(false)
    store.touch(item)
    expect(context.changed?(item)).to be(true)
    expect(context(store: Object.new).changed?(item)).to be(true)
  end

  it 'reads stored file contents and fails without them' do
    database = SQLite3::Database.new(':memory:')
    database.execute('CREATE TABLE mxrb_file_contents (entity TEXT, object_id TEXT, content BLOB)')
    database.execute('INSERT INTO mxrb_file_contents VALUES (?, ?, ?)', ['Mod.Upload', 'a', SQLite3::Blob.new('ok')])
    files = Struct.new(:database).new(database)
    file = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Mod.Upload', id: 'a', members: {})
    expect(context(store: files).file_content(file)).to eq('ok'.b)
    missing = file.with(id: 'b')
    expect { context(store: files).file_content(missing) }
      .to raise_error(Mxrb::NativeRuntimeError, 'Mod.Upload b has no file contents')
    expect { context.file_content(file) }.to raise_error(Mxrb::NativeRuntimeError, /has no file contents/)
  end

  it 'reports the configured application, model and runtime versions' do
    expect(context.application_root_url).to eq('http://localhost:9292/')
    expect(context(environment: { 'HOST' => '0.0.0.0', 'MXRB_SERVER_PORT' => '80' }).application_root_url)
      .to eq('http://0.0.0.0:80/')
    expect(context(environment: { 'MXRB_APPLICATION_ROOT_URL' => 'https://app/' }).application_root_url)
      .to eq('https://app/')
    expect(context.model_version).to eq('unversioned')
    expect(context(environment: { 'MXRB_MODEL_VERSION' => '1.2.3.4' }).model_version).to eq('1.2.3.4')
    expect(context.runtime_version).to eq('11.12.1')
  end

  it 'lists the stored and calculated attributes along the generalization chain' do
    expect(context.attributes('Mod.Item').first(2)).to eq([['Name', :string, false], ['Password', :hashstring, false]])
    expect(context.attributes('Mod.Item').last(3))
      .to eq([['Code', :string, false], ['Name', :string, false], ['Total', :decimal, true]])
    expect(context.attributes('Mod.Lone')).to eq([['Name', :string, false], ['Count', :integer, false]])
    expect(context.attributes('Mod.Loop')).to eq([])
    expect(context.attributes('Ruby.Row')).to eq([['A', :integer, false]])
    expect { context.attributes('Mod.Missing') }.to raise_error(Mxrb::NativeRuntimeError, 'unknown entity Mod.Missing')
    expect { context.attributes('Mod.Upload') }
      .to raise_error(Mxrb::NativeRuntimeError, 'attributes of System.FileDocument specializations are not supported')
  end

  it 'reads constants through the interpreter resolver or the model' do
    resolver = Struct.new(:table) { def value(name) = table.fetch(name) }.new({ 'Mod.Flag' => true })
    with_resolver = described_class.new(interpreter:, store:, log: lines, project:, flows: [], constants: resolver)
    expect(with_resolver.constant('Mod.Flag')).to be(true)
    expect { context.constant('Mod.Flag') }.to raise_error(Mxrb::NativeRuntimeError, 'unknown constant @Mod.Flag')
  end

  it 'tells the members of an entity and its generalizations apart' do
    expect(context.member_kind('Mod.Item', 'Name')).to eq(:attribute)
    expect(context.member_kind('Mod.Item', 'Code')).to eq(:attribute)
    expect(context.member_kind('Mod.Item', 'Password')).to eq(:attribute)
    expect(context.member_kind('System.User', 'Name')).to eq(:attribute)
    expect(context.member_kind('Mod.Lone', 'Count')).to eq(:integer)
    expect(context.member_kind('Mod.Item', 'Item_Base')).to eq(:reference)
    expect(context.member_kind('Mod.Item', 'Item_Lone')).to eq(:reference_set)
    expect(context.member_kind('Mod.Lone', 'Code')).to be_nil
    expect(context.member_kind('Mod.Missing', 'Name')).to be_nil
    expect(context.member_kind('Mod.Item', 'FailedLogins')).to eq(:integer)
    expect(context.member_kind('Mod.Item', 'UserRoles')).to eq(:reference_set)
    expect(context.member_kind('Mod.Item', 'User_Language')).to eq(:reference)
    expect(context.member_kind('Mod.Upload', 'Size')).to eq(:attribute)
    expect(context.member_kind('Mod.Upload', 'Missing')).to be_nil
    expect(context.member_kind('Mod.Lone', 'createdDate')).to eq(:attribute)
    expect(context.member_kind('Mod.Lone', 'owner')).to eq(:reference)
  end

  it 'describes the session of the calling user, a guest or the system' do
    expect(context.session).to eq('id' => nil, 'user' => nil, 'name' => nil, 'anonymous' => false)
    guest = Mxrb::Runtime::SecurityContext.new(attributes: { 'session_id' => 's1', 'anonymous' => true })
    expect(context(security_context: guest).session)
      .to eq('id' => 's1', 'user' => nil, 'name' => 'Anonymous_s1', 'anonymous' => true)
    ann = user('ann')
    signed_in = Mxrb::Runtime::SecurityContext.new(user: ann.id, attributes: { 'session_id' => 's2' })
    expect(context(security_context: signed_in).session)
      .to eq('id' => 's2', 'user' => ann, 'name' => 'ann', 'anonymous' => false)
  end

  it 'reports the default language, en_US without language settings' do
    expect(context.default_language).to eq('code' => 'en_US', 'language' => nil)
    portuguese = store.create('System.Language').tap { _1.members['Code'] = 'pt_BR' }
    project.define_singleton_method(:language_settings) { { 'default' => 'pt_BR' } }
    expect(context.default_language).to eq('code' => 'pt_BR', 'language' => portuguese)
  end

  it 'shows messages as the calling microflow would' do
    effects = []
    allow(interpreter).to receive(:effects).and_return(effects)
    expect(context.show_message('WARNING', 'careful', blocking: true)).to be_nil
    expect(effects).to eq([{ type: 'show_message', level: 'warning', blocking: true, message: 'careful' }])
    expect { context.show_message('LOUD', 'x') }.to raise_error(ArgumentError, 'unknown message type "LOUD"')
  end

  it 'retrieves by XPath through the interpreter and reads the session user' do
    found = [store.create('Mod.Item')]
    expect(interpreter).to receive(:retrieve_xpath)
      .with('Mod.Item', '[Name = $name]', { 'name' => 'a' }, offset: 1, amount: 2, sort: [['Name', true]])
      .and_return(found)
    expect(context.retrieve(" //Mod.Item[Name = $name]\n", { 'name' => 'a' }, offset: 1, amount: 2,
                                                                              sort: [['Name', true]])).to eq(found)
    expect { context.retrieve('Mod.Item') }.to raise_error(ArgumentError, 'unsupported XPath query "Mod.Item"')

    ann = user('ann')
    expect(context.user).to be_nil
    expect(context(security_context: Mxrb::Runtime::SecurityContext.new(user: ann.id)).user).to eq(ann)
  end

  it 'gives Java exceptions their class and an empty message for null' do
    error = Mxrb::Runtime::JavaActionError.new('java.lang.RuntimeException', nil)
    expect([error.java_class, error.message]).to eq(['java.lang.RuntimeException', ''])
    expect(error).to be_a(Mxrb::NativeRuntimeError)
  end
end
# rubocop:enable Metrics/BlockLength
