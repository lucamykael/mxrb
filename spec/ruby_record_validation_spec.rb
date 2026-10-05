# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Standalone record validation' do
  around do |example|
    Dir.mktmpdir do |directory|
      Mxrb::RubyApp::Registry.reset!
      @base = Class.new(Mxrb::RubyApp::Record) do
        mendix_name 'Rules.Base'
        attribute :name, type: :string, mendix_name: 'Name'
        attribute :amount, type: :decimal, mendix_name: 'Amount'
        attribute :limit, type: :decimal, mendix_name: 'Limit'
      end
      @child = Class.new(Mxrb::RubyApp::Record) do
        mendix_name 'Rules.Child'
        generalizes 'Rules.Base'
      end
      @sibling = Class.new(Mxrb::RubyApp::Record) do
        mendix_name 'Rules.Sibling'
        generalizes 'Rules.Base'
      end
      data = { 'mode' => 'ruby', 'project' => { 'name' => 'Rules', 'mendix_version' => '11.12.1' }, 'modules' => [] }
      manifest = Mxrb::RubyApp::Manifest.new(directory, data)
      project = Mxrb::RubyApp::RuntimeProject.new(manifest)
      schema = Mxrb::Runtime::SchemaMigrator.derive_records(Mxrb::RubyApp::Registry.all(:record))
      @store = Mxrb::Runtime::SQLiteStore.new(project, path: File.join(directory, 'validation.sqlite3'), schema:)
      @validator = Mxrb::RubyApp::RecordValidation.new(Mxrb::RubyApp::Registry.all(:record), @store)
      @store.on(:before_commit) { |object| @validator.call(object) }
      example.run
    ensure
      @store&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def object(entity = 'Rules.Child', **values)
    @store.create(entity).tap { _1.members.merge!(values.transform_keys(&:to_s)) }
  end

  def rule(member, kind, **info)
    @base.validation_rule(member, kind:, rule_info: info)
  end

  it 'rejects inherited blank strings and reports all failures in declaration order' do
    @base.validation_rule('Name', kind: :required) { translation 'pt_BR', 'Nome obrigatório' }
    @base.validation_rule('Name', kind: :required) { translation 'en_US', 'Name is required' }
    @child.validation_rule('Amount', kind: :required)
    value = object(Name: " \t ", Amount: nil)
    expect { @store.commit(value) }.to raise_error(Mxrb::RubyApp::RecordValidationError) do |error|
      expect(error.errors.map { _1[:message] }).to eq(['Nome obrigatório', 'Name is required', 'Amount: required'])
      expect(error.errors.map { _1[:entity] }.uniq).to eq(['Rules.Child'])
    end
    value.members.merge!('Name' => 'Valid', 'Amount' => 0)
    @store.commit(value)
    value.members['Name'] = ''
    expect { @store.commit(value) }.to raise_error(Mxrb::ValidationError)
    expect(@store.find('Rules.Base', value.id).members['Name']).to eq('Valid')
  end

  it 'matches Java whitespace without rejecting nonbreaking or zero-width spaces' do
    rule('Name', :required)
    ["\u2003", "\u001c", "\u3000"].each do |space|
      expect { @store.commit(object(Name: space)) }.to raise_error(Mxrb::RubyApp::RecordValidationError)
    end
    ["\u00a0", "\u2007", "\u202f", "\u200b", "\0"].each do |text|
      @store.commit(object(Name: text))
    end
  end

  it 'checks uniqueness across subtypes using durable rows and rolls back a batch' do
    rule('Name', :unique)
    first = object(Name: 'Unique')
    @store.commit(first)
    draft = object(Name: 'Other')
    second = object('Rules.Sibling', Name: 'Other')
    @store.commit(second)
    expect { @store.commit(draft) }.to raise_error(Mxrb::ValidationError)
    duplicate = object(Name: 'Unique')
    expect { @store.commit(duplicate) }.to raise_error(Mxrb::ValidationError)
    first = @store.find('Rules.Child', first.id)
    first.members['Amount'] = 2
    @store.commit(first)
    @store.rollback(draft)
    @store.rollback(duplicate)
    a = object(Name: 'Batch')
    b = object('Rules.Sibling', Name: 'Batch')
    expect { @store.commit([a, b]) }.to raise_error(Mxrb::ValidationError)
    table = @store.schema.entity('Rules.Child').table
    expect(@store.database.get_first_value(%(SELECT COUNT(*) FROM "#{table}"))).to eq(1)
  end

  it 'compares inclusive decimal bounds, other attributes and exact equality' do
    rule('Amount', 'DomainModels$RangeRuleInfo', TypeOfRange: 'Between', UseMinValue: true,
                                                 MinValue: '1.5', UseMaxValue: false, MaxAttribute: 'Rules.Base.Limit')
    value = object(Amount: 1.5, Limit: 2.5)
    @store.commit(value)
    value.members['Amount'] = 2.5
    @store.commit(value)
    [1.4, 2.6].each do |invalid|
      value.members['Amount'] = invalid
      expect { @store.commit(value) }.to raise_error(Mxrb::ValidationError)
      value = @store.find('Rules.Child', value.id)
    end
    rule('Amount', 'DomainModels$EqualsToRuleInfo', UseValue: false, EqualsToAttribute: 'Rules.Base.Limit')
    value.members.merge!('Amount' => 2, 'Limit' => 2)
    @store.commit(value)
    value.members['Limit'] = 3
    expect { @store.commit(value) }.to raise_error(Mxrb::ValidationError)
  end

  it 'counts UTF-16 code units for maximum length and keeps optional values empty' do
    rule('Name', 'DomainModels$MaxLengthRuleInfo', MaxLength: 2)
    value = object(Name: '😀')
    @store.commit(value)
    value.members['Name'] = '😀a'
    expect { @store.commit(value) }.to raise_error(Mxrb::ValidationError)
    value = @store.find('Rules.Child', value.id)
    value.members['Name'] = nil
    @store.commit(value)
    rule('Amount', 'DomainModels$RangeRuleInfo', TypeOfRange: 'Between', UseMinValue: true, MinValue: '1',
                                                 UseMaxValue: true, MaxValue: '2')
    @store.commit(object(Name: 'OK', Amount: nil))
  end

  it 'requires an explicit adapter for JVM regular expressions and rejects missing definitions' do
    rule('Name', 'DomainModels$RegExRuleInfo', RegExIdentifier: 'Rules.Pattern')
    value = object(Name: 'OK')
    expect { @store.commit(value) }.to raise_error(Mxrb::ValidationError, /unknown regular expression/)
    Class.new(Mxrb::RubyApp::RegularExpression) do
      mendix_name 'Rules.Pattern'
      expression '[A-Z]+'
    end
    expect { @store.commit(value) }.to raise_error(Mxrb::ValidationError, /adapter is required/)
    Mxrb::RubyApp::Registry.register_adapter(:regular_expression) do |expression:, value:|
      expect(expression).to eq('[A-Z]+')
      value == 'OK'
    end
    @store.commit(value)
    value.members['Name'] = 'bad'
    expect { @store.commit(value) }.to raise_error(Mxrb::RubyApp::RecordValidationError)
    @store.commit(object(Name: nil))
  end

  it 'fails explicitly for unsupported rules and broken attribute references' do
    rule('Name', 'DomainModels$FutureRuleInfo')
    expect { @store.commit(object(Name: 'OK')) }.to raise_error(Mxrb::ValidationError, /unsupported runtime validation/)
    @base.clear_validation_rules!
    rule('Missing', :required)
    expect { @store.commit(object) }.to raise_error(Mxrb::ValidationError, /unknown validation attribute/)
  end
  it 'compares typed constants, timestamps with offsets, Booleans and empty equality' do
    cases = [
      [:integer, '2', 2, 3], [:string, 'yes', 'yes', 'no'],
      [:boolean, 'true', true, false], [:boolean, 'false', false, true],
      [:datetime, '2026-10-05T12:00:00Z', Time.iso8601('2026-10-05T08:00:00-04:00'),
       Time.iso8601('2026-10-05T13:00:00Z')]
    ]
    cases.each do |type, expected, valid, invalid|
      member = { name: :value, mendix_name: 'Value', type: }
      value = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Rules.Base', id: 'typed', members: { 'Value' => valid })
      info = { kind: 'DomainModels$EqualsToRuleInfo', rule_info: { 'UseValue' => true, 'Value' => expected } }
      expect(Mxrb::RubyApp::ValidationCondition.new(@store, @base, member, value).valid?(info)).to be(true)
      value.members['Value'] = invalid
      expect(Mxrb::RubyApp::ValidationCondition.new(@store, @base, member, value).valid?(info)).to be(false)
    end
    rule('Name', 'DomainModels$EqualsToRuleInfo', UseValue: true, Value: nil)
    @store.commit(object(Name: nil))
    member = { name: :active, mendix_name: 'Active', type: :boolean }
    value = object(Active: 'invalid')
    condition = Mxrb::RubyApp::ValidationCondition.new(@store, @base, member, value)
    info = { kind: 'equals', rule_info: { 'UseValue' => true, 'Value' => 'false' } }
    expect { condition.valid?(info) }.to raise_error(Mxrb::ValidationError, /invalid Boolean/)
  end

  it 'reads native date literals with optional time as UTC and preserves empty bounds' do
    member = { name: :value, mendix_name: 'Value', type: :datetime }
    values = { '2026-10-05' => '2026-10-05T00:00:00Z', '2026-10-05 12:30' => '2026-10-05T12:30:00Z',
               '2026-10-05 12:30:45' => '2026-10-05T12:30:45Z', '' => nil }
    values.each do |literal, instant|
      value = object(Value: instant)
      rule = { kind: 'equals', rule_info: { 'UseValue' => true, 'Value' => literal } }
      expect(Mxrb::RubyApp::ValidationCondition.new(@store, @base, member, value).valid?(rule)).to be(true)
    end
  end

  it 'handles one-sided ranges and rejects unknown range modes' do
    rule('Amount', 'DomainModels$RangeRuleInfo', TypeOfRange: 'GreaterThanOrEqualTo', UseMinValue: true, MinValue: '2')
    @store.commit(object(Amount: 2))
    expect { @store.commit(object(Amount: 1)) }.to raise_error(Mxrb::ValidationError)
    @base.clear_validation_rules!
    rule('Amount', 'DomainModels$RangeRuleInfo', TypeOfRange: 'SmallerThanOrEqualTo', UseMaxValue: true, MaxValue: '2')
    @store.commit(object(Amount: 2))
    expect { @store.commit(object(Amount: 3)) }.to raise_error(Mxrb::ValidationError)
    @base.clear_validation_rules!
    rule('Amount', 'DomainModels$RangeRuleInfo', TypeOfRange: 'Future')
    expect { @store.commit(object(Amount: 2)) }.to raise_error(Mxrb::ValidationError, /unsupported range type/)
  end

  it 'does not apply persistent rules to DTOs or unknown records, and permits event-free writes' do
    @child.persistence(false)
    rule('Name', :required)
    expect(@validator.call(object(Name: nil))).to be_nil
    unknown = Mxrb::Runtime::Native::ObjectValue.new(entity: 'External.Record', id: 'unknown', members: {})
    expect(@validator.call(unknown)).to be_nil
    @child.persistence(true)
    @store.commit(object(Name: nil), events: false)
  end
end
# rubocop:enable Metrics/BlockLength
