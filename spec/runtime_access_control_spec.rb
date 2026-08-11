# frozen_string_literal: true

require 'spec_helper'
require_relative '../lib/mxrb/runtime/access_control'

# rubocop:disable Lint/ConstantDefinitionInBlock, Metrics/BlockLength, Metrics/MethodLength

RSpec.describe Mxrb::Runtime::AccessControl do
  Artifact = Struct.new(:name, :allowed_module_roles)
  Entity = Struct.new(:name, :qualified_name, :access_rules)
  AccessMod = Struct.new(:name, :microflows, :pages, :entities, :scheduled_events)

  def security(level: 'CheckEverything')
    {
      '$Type' => 'Security$ProjectSecurity',
      'SecurityLevel' => level,
      'AdminUserRole' => 'Administrator',
      'UserRoles' => [
        2,
        {
          'Name' => 'User', 'ManageAllRoles' => false,
          'ModuleRoles' => [1, 'Sales.User']
        },
        {
          'Name' => 'Administrator', 'ManageAllRoles' => true,
          'ModuleRoles' => [1, 'Sales.Admin']
        }
      ]
    }
  end

  def project(level: 'CheckEverything')
    user_rule = {
      roles: ['Sales.User'], create: true, delete: false,
      default_rights: 'ReadOnly',
      members: [
        { name: 'Name', rights: 'ReadWrite' },
        { name: 'Secret', rights: 'None' }
      ],
      xpath: '[Owner = $currentUser]'
    }
    entity = Entity.new('Order', 'Sales.Order', [user_rule])
    hidden = Entity.new('Audit', 'Sales.Audit', [])
    mod = AccessMod.new(
      'Sales', [Artifact.new('CreateOrder', ['Sales.User'])],
      [Artifact.new('Dashboard', ['Sales.User'])], [entity, hidden], []
    )
    raw = { document: security(level:) }
    Struct.new(:modules, :all_units) do
      def parse_bson(unit) = unit.fetch(:document)
    end.new([mod], [raw])
  end

  it 'expands explicit user roles and authorizes microflows and pages' do
    policy = described_class.new(project)
    user = policy.context(user: { id: 7 }, roles: ['User'])

    expect(user.module_roles).to eq(['Sales.User'])
    expect(policy.microflow_allowed?('Sales.CreateOrder', context: user)).to be true
    expect(policy.page_allowed?('Sales.Dashboard', context: user)).to be true
    expect(policy.page_allowed?(Artifact.new('Admin', ['Sales.Admin']), context: user)).to be false
    expect(policy.authorized?('Sales.CreateOrder', kind: :microflow,
                                                   action: :execute, context: user)).to be true
  end

  it 'enforces entity operations, member rights, and XPath constraints' do
    policy = described_class.new(project)
    context = policy.context(user: { id: 7 }, roles: ['User'])
    owned = { 'Owner' => 7, 'Name' => 'A', 'Secret' => 'x' }
    foreign = owned.merge('Owner' => 8)

    expect(policy.entity_allowed?('Sales.Order', action: :create, context:)).to be true
    expect(policy.entity_allowed?('Sales.Order', action: :delete, context:)).to be false
    expect(policy.member_allowed?('Sales.Order', 'Name', action: :write,
                                                         context:, record: owned)).to be true
    expect(policy.member_allowed?('Sales.Order', 'Secret', action: :read,
                                                           context:, record: owned)).to be false
    expect(policy.entity_allowed?('Sales.Order', action: :read,
                                                 context:, record: foreign)).to be false
    expect(policy.filter_readable('Sales.Order', [owned, foreign], context:)).to eq([owned])
    expect(policy.xpath_constraints('Sales.Order', context:)).to eq(['[Owner = $currentUser]'])
  end

  it 'denies missing rules and unsupported XPath by default' do
    policy = described_class.new(project)
    context = policy.context(roles: ['User'], user: { id: 7 })

    expect(policy.entity_allowed?('Sales.Audit', action: :read, context:)).to be false
    expect(policy.evaluate_xpath("[contains(Name, 'x')]", record: { Name: 'x' }, context:)).to be_nil
    expect do
      policy.authorize!('Sales.Audit', kind: :entity, action: :read, context:)
    end.to raise_error(Mxrb::Runtime::AuthorizationError, /not authorized/)
  end

  it 'allows administrators and projects with security checks disabled' do
    secured = described_class.new(project)
    admin = secured.context(roles: ['Administrator'])
    expect(secured.entity_allowed?('Sales.Audit', action: :delete, context: admin)).to be true

    open_policy = described_class.new(project(level: 'CheckNothing'))
    anonymous = open_policy.context
    expect(open_policy.page_allowed?('Sales.Dashboard', context: anonymous)).to be true
    expect(open_policy.entity_allowed?('Sales.Audit', action: :delete, context: anonymous)).to be true
  end

  it 'supports direct module-role contexts and basic boolean XPath' do
    policy = described_class.new(project)
    context = { module_roles: ['Sales.User'], user: { id: 'u1' }, variables: { Limit: 3 } }
    record = { 'Owner' => 'u1', 'Amount' => 5, 'Active' => true }

    expression = '[Owner = $currentUser and Amount > $Limit and Active = true()]'
    expect(policy.evaluate_xpath(expression, record:, context:)).to be true
    expect(policy.evaluate_xpath('[Owner != $currentUser or Amount < 3]', record:, context:)).to be false
  end

  it 'covers generic authorization dispatch and every entity permission shape' do
    policy = described_class.new(project)
    context = policy.context(roles: ['User'], user: { id: 7 })

    expect(policy.authorized?('Sales.Dashboard', kind: :page,
                                                 action: :read, context:)).to be true
    expect(policy.page_allowed?('Missing.Page', context:)).to be false
    expect(policy.authorized?(Object.new, action: :read, context:)).to be false
    expect(policy.entity_allowed?('Missing.Entity', action: :read, context:)).to be false
    expect(policy.xpath_constraints('Missing.Entity', context:)).to eq([])
    expect(policy.authorize!('Sales.Dashboard', kind: :page,
                                                action: :read, context:)).to be true
    admin = policy.context(roles: ['Administrator'])
    expect(policy.page_allowed?('Sales.Dashboard', context: admin)).to be true

    named = Struct.new(:name).new('NamedResource')
    expect do
      policy.authorize!(named, kind: :unknown, action: :read, context:)
    end.to raise_error(Mxrb::Runtime::AuthorizationError, /NamedResource/)

    order = project.modules.first.entities.first
    expect(policy.entity_allowed?(order, action: :write, context:)).to be true
    expect(policy.entity_allowed?(order, action: :unknown, context:)).to be false
    expect(policy.member_allowed?(order, Struct.new(:name).new('Missing'),
                                  action: :read, context:)).to be true

    default_write = Entity.new(
      'Writable', 'Sales.Writable',
      [{ roles: ['Sales.User'], default_rights: 'ReadWrite', members: [] }]
    )
    expect(policy.entity_allowed?(default_write, action: :write, context:)).to be true
    expect(policy.member_allowed?(default_write, 'Anything', action: :write, context:)).to be true

    empty_roles = Entity.new(
      'Closed', 'Sales.Closed', [{ roles: [], default_rights: 'ReadWrite' }]
    )
    expect(policy.entity_allowed?(empty_roles, action: :read, context:)).to be false
  end

  it 'infers model resource types and handles absent or partially unreadable security' do
    policy = described_class.new(project)
    context = policy.context(roles: ['User'])
    microflow = Mxrb::Model::Microflow.allocate
    microflow.instance_variable_set(:@allowed_module_roles, ['Sales.User'])
    page = Mxrb::Model::Page.allocate
    page.instance_variable_set(:@allowed_module_roles, ['Sales.User'])
    entity = Mxrb::Model::Entity.new
    entity.name = 'Direct'
    entity.qualified_name = 'Sales.Direct'
    entity.access_rules = [{ roles: ['Sales.User'], default_rights: 'ReadOnly' }]

    expect(policy.authorized?(microflow, action: :execute, context:)).to be true
    expect(policy.authorized?(page, action: :read, context:)).to be true
    expect(policy.authorized?(entity, action: :read, context:)).to be true

    no_security = Struct.new(:modules).new(project.modules)
    expect(described_class.new(no_security).security_enabled?).to be false

    security_doc = security
    partially_broken = Struct.new(:modules, :all_units) do
      def parse_bson(unit)
        raise 'unreadable unit' if unit[:broken]

        unit.fetch(:document)
      end
    end.new(project.modules, [{ broken: true }, { document: security_doc }])
    expect(described_class.new(partially_broken).security_enabled?).to be true

    raw_context = Mxrb::Runtime::SecurityContext.new(roles: ['User'])
    normalized = policy.send(:normalized_context, raw_context)
    expect(normalized.module_roles).to eq(['Sales.User'])
    expect(policy.send(:normalized_context, nil)).to be_nil
  end

  it 'evaluates the supported XPath operand and comparison branches conservatively' do
    policy = described_class.new(project)
    context = policy.context(user: { 'name' => 'alice' }, roles: ['User'], variables: { Limit: 3 })
    record = { 'Name' => "a'b", 'Count' => 3, 'Ratio' => 1.5, 'Nothing' => nil, 'Owner' => 'alice' }

    expect(policy.evaluate_xpath('', record:, context:)).to be true
    expect(policy.evaluate_xpath('true()', record:, context:)).to be true
    expect(policy.evaluate_xpath('false()', record:, context:)).to be false
    expect(policy.evaluate_xpath('not(false())', record:, context:)).to be true
    expect(policy.evaluate_xpath('not(unsupported())', record:, context:)).to be_nil
    expect(policy.evaluate_xpath("Name = 'a''b'", record:, context:)).to be true
    expect(policy.evaluate_xpath('Count >= 3', record:, context:)).to be true
    expect(policy.evaluate_xpath('Count <= 3', record:, context:)).to be true
    expect(policy.evaluate_xpath('Count = false()', record: { Count: false }, context:)).to be true
    expect(policy.evaluate_xpath('Ratio = 1.5', record:, context:)).to be true
    expect(policy.evaluate_xpath('Nothing = null', record:, context:)).to be true
    expect(policy.evaluate_xpath('Owner = [%CurrentUser%]', record:, context:)).to be true
    expect(policy.evaluate_xpath('Count = bare', record:, context:)).to be_nil
    expect(policy.evaluate_xpath('Count = $Missing', record:, context:)).to be_nil
    expect(policy.evaluate_xpath('Missing = 1 or true()', record:, context:)).to be_nil
    expect(policy.evaluate_xpath('Name > 1', record:, context:)).to be false

    expect(policy.evaluate_xpath('Owner = $currentUser', record: { Owner: 'bob' },
                                                         context: { user: { name: 'bob' } })).to be true
    user = Struct.new(:id).new(9)
    expect(policy.evaluate_xpath('Owner = $currentUser', record: { Owner: 9 },
                                                         context: { user: })).to be true
    expect(policy.evaluate_xpath('Owner = $currentUser', record: { Owner: 'plain' },
                                                         context: { user: 'plain' })).to be true
    expect(policy.evaluate_xpath('Owner = $currentUser', record: { Owner: nil },
                                                         context: { user: nil })).to be true
    expect(policy.evaluate_xpath('Owner = $currentUser', record: { Owner: 'string-id' },
                                                         context: { user: { 'id' => 'string-id' } })).to be true
    expect(policy.evaluate_xpath('Owner = $currentUser', record: { Owner: {} },
                                                         context: { user: {} })).to be true
    expect(policy.evaluate_xpath('((Count = 3))', record:, context:)).to be true

    members_record = Object.new
    members_record.define_singleton_method(:members) { { 'Count' => 3 } }
    expect(policy.evaluate_xpath('Count = 3', record: members_record, context: {})).to be true
    method_record = Object.new
    method_record.define_singleton_method(:count) { 3 }
    expect(policy.evaluate_xpath('count = 3', record: method_record, context: {})).to be true

    malformed_array = Object.new
    malformed_array.define_singleton_method(:empty?) { false }
    malformed_array.define_singleton_method(:first) { raise TypeError }
    expect(policy.send(:parse_array, malformed_array)).to eq([malformed_array])
    expect(policy.send(:value, Object.new, :missing)).to be_nil
    expect(policy.send(:value, {}, :missing)).to be_nil

    fake_match = Object.new
    fake_match.define_singleton_method(:[]) { |index| { 1 => 'Count', 2 => '?', 3 => '3' }[index] }
    fake_expression = Object.new
    fake_expression.define_singleton_method(:match) { |_pattern| fake_match }
    expect(policy.send(:comparison, fake_expression, record, context)).to be_nil
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock, Metrics/BlockLength, Metrics/MethodLength
