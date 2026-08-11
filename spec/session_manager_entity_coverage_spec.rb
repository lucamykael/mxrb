# frozen_string_literal: true

require 'digest'
require 'spec_helper'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength, Metrics/ParameterLists
RSpec.describe Mxrb::RubyApp::SessionManager, 'credentials and profile edges' do
  def access_policy
    context = Struct.new(:user, :user_roles, :module_roles, :attributes, keyword_init: true)
    Object.new.tap do |policy|
      policy.define_singleton_method(:context) do |user: nil, user_roles: nil, roles: nil,
                                                       module_roles: nil, attributes: {}, **|
        context.new(
          user:, user_roles: Array(user_roles || roles), module_roles: Array(module_roles), attributes:
        )
      end
    end
  end

  it 'rejects non-positive TTLs and handles anonymous and malformed credentials' do
    expect do
      described_class.new(access_policy, users: nil, tokens: nil, ttl: 0)
    end.to raise_error(ArgumentError, /TTL must be positive/)

    manager = described_class.new(access_policy, users: nil, tokens: nil, ttl: 1)
    expect(manager.anonymous.user).to be_nil
    expect(manager.authenticate(nil).user_roles).to eq([])
    expect(manager.authenticate('Basic credentials').attributes).to eq({})
    expect(manager.logout(nil)).to be_nil
    expect(manager.logout('Bearer unknown')).to be(false)
    expect { manager.authenticate('Bearer unknown') }
      .to raise_error(Mxrb::RubyApp::AuthenticationError, /invalid or expired/)
    expect { manager.login('missing', 'password') }
      .to raise_error(Mxrb::RubyApp::AuthenticationError, /invalid username/)
    expect { described_class.new(access_policy, users: '{', tokens: nil) }
      .to raise_error(ArgumentError, /invalid MXRB_USERS_JSON/)
    expect { described_class.new(access_policy, users: '[]', tokens: nil) }
      .to raise_error(ArgumentError, /must contain a JSON object/)
  end

  it 'supports plain and SHA-256 credentials plus both role profile spellings' do
    users = JSON.generate(
      'plain' => {
        'password' => 'secret', 'user_roles' => ['User'],
        'module_roles' => ['Sales.Reader'], 'attributes' => { 'locale' => 'pt_BR' }
      },
      'digest' => {
        'password_digest' => "sha256$#{Digest::SHA256.hexdigest('hash-secret')}",
        'roles' => ['Administrator']
      },
      'short' => { 'password_digest' => 'plain$long-password' },
      'unsupported' => { 'password_digest' => 'bcrypt$value' }
    )
    tokens = JSON.generate(
      'profile-token' => {
        'user' => 'service', 'user_roles' => ['Service'], 'attributes' => { 'source' => 'token' }
      },
      'empty-profile' => 'not-an-object'
    )
    manager = described_class.new(access_policy, users:, tokens:, ttl: '60')

    plain = manager.login('plain', 'secret')
    expect(plain).to include(user: 'plain', roles: ['User'])
    expect(manager.authenticate("bearer #{plain[:token]}")).to have_attributes(
      module_roles: ['Sales.Reader'], attributes: { 'locale' => 'pt_BR' }
    )
    expect(manager.login('digest', 'hash-secret')[:roles]).to eq(['Administrator'])
    expect(manager.authenticate('Bearer profile-token')).to have_attributes(
      user: 'service', user_roles: ['Service'], attributes: { 'source' => 'token' }
    )
    expect(manager.authenticate('Bearer empty-profile').user).to be_nil
    expect { manager.login('short', 'x') }.to raise_error(Mxrb::RubyApp::AuthenticationError)
    expect { manager.login('unsupported', 'value') }
      .to raise_error(Mxrb::RubyApp::AuthenticationError)
    expect(manager.send(:secure_compare, 'a', 'longer')).to be(false)
  end
end

RSpec.describe Mxrb::Model::Entity, 'complete BSON lifecycle and domain metadata' do
  def attribute(id, name)
    {
      '$ID' => id, 'Name' => name,
      'Type' => { '$Type' => 'DomainModels$StringAttributeType' },
      'Value' => { 'DefaultValue' => '' }
    }
  end

  def entity_document
    {
      '$ID' => 'entity-id', '$Type' => 'DomainModels$EntityImpl',
      '$QualifiedName' => 'Sales.Order', 'Name' => 'Order', 'Documentation' => 'Orders',
      'DataStorageGuid' => 'storage-id', 'ExportLevel' => 'Public', 'Location' => '12;34',
      'Generalization' => {
        'Persistable' => false, 'Generalization' => 'System.FileDocument',
        'HasOwnerAttr' => true, 'HasCreatedDateAttr' => true,
        'HasChangedDateAttr' => true, 'HasChangedByAttr' => true
      },
      'Attributes' => [3, attribute('name-id', 'Name'), attribute('code-id', 'Code')],
      'ValidationRules' => [
        3,
        { 'Attribute' => 'Sales.Order.Name',
          'RuleInfo' => { '$Type' => 'DomainModels$RequiredRuleInfo' } },
        { 'Attribute' => 'Sales.Order.Code',
          'RuleInfo' => { '$Type' => 'DomainModels$UniqueRuleInfo' } },
        { 'Attribute' => 'Sales.Order.Name',
          'RuleInfo' => { '$Type' => 'DomainModels$RangeRuleInfo' } },
        { 'Attribute' => 'Sales.Order.Missing',
          'RuleInfo' => { '$Type' => 'DomainModels$RequiredRuleInfo' } }
      ],
      'Indexes' => [3, {
        'Attributes' => [
          3,
          { 'Attribute' => 'Sales.Order.Name' },
          { 'attribute' => 'Sales.Order.Code' },
          { 'AttributePointer' => 'code-id' },
          { 'AttributePointer' => 'missing-id' }
        ]
      }],
      'AccessRules' => [3, {
        'AllowedModuleRoles' => [1, 'Sales.User'], 'AllowCreate' => true,
        'AllowDelete' => false, 'MemberAccesses' => [
          3,
          { 'Attribute' => 'Sales.Order.Name', 'AccessRights' => 'ReadWrite' },
          { 'Association' => 'Sales.Order_Customer', 'AccessRights' => 'ReadOnly' }
        ]
      }],
      'EventHandlers' => [
        3,
        { 'Moment' => 'Before', 'Event' => 'Commit', 'Microflow' => 'Sales.Validate' },
        { 'Moment' => 'After', 'Event' => 'Delete', 'Microflow' => 'Sales.Audit',
          'PassEventObject' => false, 'RaiseErrorOnFalse' => true }
      ]
    }
  end

  it 'parses validation, indexes, access, system members, and lifecycle metadata' do
    entity = described_class.from_bson(entity_document, nil, nil)
    expect(entity).to have_attributes(
      persistable: false, location: { x: 12, y: 34 },
      system_members: { owner: true, created_date: true, changed_date: true, changed_by: true }
    )
    expect(entity.generalization_target).to eq('System.FileDocument')
    expect(entity.attributes.find { _1.name == 'Name' }.required).to be(true)
    expect(entity.attributes.find { _1.name == 'Code' }.unique).to be(true)
    index_members = entity.indexes.first['Attributes'].drop(1)
    expect(index_members[2]['Attribute']).to eq('Sales.Order.Code')
    expect(index_members[3]).not_to have_key('Attribute')
    expect(entity.access_rules.first[:members]).to contain_exactly(
      include(name: 'Name', kind: :attribute),
      include(name: 'Order_Customer', kind: :association)
    )
    expect(entity.lifecycle).to eq([
                                     { event: :before_commit, handler: 'Sales.Validate', pass_event_object: true,
                                       raise_error_on_false: false },
                                     { event: :after_delete, handler: 'Sales.Audit', pass_event_object: false,
                                       raise_error_on_false: true }
                                   ])
  end

  it 'round-trips lifecycle defaults and explicit BSON flags' do
    entity = described_class.from_bson(entity_document, nil, nil)
    events = Mxrb::IO::BsonCodec.parse_array(entity.to_bson['eventHandlers'])[:items]
    expect(events).to contain_exactly(
      include('Moment' => 'Before', 'Event' => 'Commit', 'Microflow' => 'Sales.Validate',
              'PassEventObject' => true, 'RaiseErrorOnFalse' => false),
      include('Moment' => 'After', 'Event' => 'Delete', 'Microflow' => 'Sales.Audit',
              'PassEventObject' => false, 'RaiseErrorOnFalse' => true)
    )
  end

  it 'covers OQL source variants, system flag spellings, and serialization defaults' do
    entity = described_class.new
    entity.source = { '$Type' => 'DomainModels$OqlViewEntitySource', 'sourceDocument' => 'Sales.Query' }
    expect(entity).to be_oql_view
    expect(entity.oql_source_document).to eq('Sales.Query')
    entity.source = 'invalid'
    expect(entity.oql_source_document).to be_nil
    expect(entity).not_to be_oql_view

    lower = described_class.send(:parse_system_members, {
      'hasOwner' => true, 'hasCreatedDate' => true, 'hasChangedDate' => true, 'hasChangedBy' => true
    })
    expect(lower.values).to all(be(true))
    expect(described_class.send(:parse_system_members, 'invalid')).to eq({})

    entity.id = 'new-id'
    entity.name = 'New'
    entity.qualified_name = 'Sales.New'
    entity.persistable = false
    entity.location = nil
    entity.lifecycle = []
    entity.access_rules = []
    entity.instance_variable_set(:@attributes, [])
    bson = entity.to_bson
    expect(bson['location']).to eq('x' => 0, 'y' => 0)
    expect(bson['generalization']).to include('persistable' => false, 'hasOwner' => false)
    expect(entity.inspect).to include('New', 'persistable=false')

    plain = described_class.from_bson({
      '$ID' => 'plain', 'Name' => 'Plain', 'Generalization' => 'invalid',
      'Location' => { x: 7 }, 'Attributes' => [3], 'AccessRules' => [3]
    }, nil, nil)
    expect(plain).to have_attributes(persistable: true, location: { x: 7, y: 0 })
    expect(plain.generalization_target).to be_nil
    expect(described_class.send(:parse_location, nil)).to eq(x: 0, y: 0)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength, Metrics/ParameterLists
