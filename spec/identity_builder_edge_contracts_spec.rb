# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby identity and builder edge contracts' do
  def manifest(records = [])
    Mxrb::RubyApp::Manifest.new('/tmp/identity-edges', 'mode' => 'ruby', 'modules' => [
                                  { 'models' => records, 'dtos' => [] }
                                ])
  end

  it 'rejects every ambiguous member identity shape explicitly' do
    resolver = Mxrb::RubyApp::MemberIdentity
    expect { resolver.resolve(previous: [{ name: '', id: 'one' }], declarations: []) }
      .to raise_error(Mxrb::ValidationError, /empty or duplicate names/)
    expect { resolver.resolve(previous: [{ name: 'A', id: '' }], declarations: []) }
      .to raise_error(Mxrb::ValidationError, /identities are missing/)
    expect do
      resolver.resolve(previous: [], declarations: [{ name: 'A', id: 'one' }, { name: 'B', id: 'one' }])
    end.to raise_error(Mxrb::ValidationError, /duplicate explicit/)

    previous = [{ name: 'A', id: 'one' }, { name: 'B', id: 'two' }]
    expect { resolver.resolve(previous:, declarations: [{ name: 'A', id: 'unknown' }]) }
      .to raise_error(Mxrb::ValidationError, /conflicts with member A/)
    expect { resolver.resolve(previous:, declarations: [{ name: 'C', renamed_from: '' }]) }
      .to raise_error(Mxrb::ValidationError, /renamed_from must name/)
    expect { resolver.resolve(previous:, declarations: [{ name: 'C', renamed_from: 'Missing' }]) }
      .to raise_error(Mxrb::ValidationError, /unknown member rename/)
    expect do
      resolver.resolve(previous:, declarations: [{ name: 'C', id: 'two', renamed_from: 'A' }])
    end.to raise_error(Mxrb::ValidationError, /conflicts with renamed member/)
    expect { resolver.resolve(previous:, declarations: [{ name: 'B', renamed_from: 'A' }]) }
      .to raise_error(Mxrb::ValidationError, /collides with existing name/)
    expect do
      resolver.resolve(previous:, declarations: [
                         { name: 'C', renamed_from: 'A' }, { name: 'D', renamed_from: 'A' }
                       ])
    end.to raise_error(Mxrb::ValidationError, /multiple declarations claim/)
  end

  it 'validates record baselines, removals, singleton identities, and rename signatures' do
    duplicate = { 'id' => 'record', 'name' => 'App.Item' }
    ambiguous = Mxrb::RubyApp::RecordIdentity.new(manifest([duplicate, duplicate.dup]))
    expect { ambiguous.resolve(id: 'record', name: 'App.Item') }
      .to raise_error(Mxrb::ValidationError, /ambiguous private record/)

    resolver = Mxrb::RubyApp::RecordIdentity.new(manifest([duplicate]))
    expect { resolver.resolve(id: 'record', name: 'App.Item', indexes: nil, removed: { indexes: [:Name] }) }
      .to raise_error(Mxrb::ValidationError, /explicit complete indexes/)
    expect { resolver.resolve(id: 'record', name: 'App.Item', generalization: { target: 'App.Base' }) }
      .to raise_error(Mxrb::ValidationError, /generalization identity baseline/)
    expect(resolver.send(:rename_signature, :lifecycle, :before_commit, 'App.Item')).to eq('before_commit')
    expect(resolver.send(:rename_signature, :indexes, [%i[Name created_date]], 'App.Item'))
      .to eq([%w[Name CreatedDate]])
    expect { resolver.send(:rename_signature, :access_rules, [:invalid], 'App.Item') }
      .to raise_error(ArgumentError, /requires \[roles, xpath\]/)
    expect { resolver.send(:rename_signature, :validation_rules, [:invalid], 'App.Item') }
      .to raise_error(ArgumentError, /requires \[attribute, kind\]/)
    expect(resolver.send(:rename_signature, :validation_rules, %i[Name required], 'App.Item'))
      .to eq(['Name', 'DomainModels$RequiredRuleInfo'])
    expect(resolver.send(:signature, :unknown, {}, 'App.Item')).to be_nil
    expect(resolver.send(:signature, :validation_rules,
                         { attribute: 'Code', kind: 'regular_expression' }, 'App.Item'))
      .to eq(['Code', 'DomainModels$RegExRuleInfo'])
  end

  it 'validates password policy constructors and rolls back failed block edits' do
    expect { Mxrb::RubyApp::PasswordPolicy.new(minimum_length: -1) }
      .to raise_error(TypeError, /nonnegative Integer/)
    expect { Mxrb::RubyApp::PasswordPolicy.new(require_digit: :yes) }
      .to raise_error(TypeError, /true, false, or unspecified/)
    expect do
      Mxrb::RubyApp::PasswordPolicyBuilder.new('MinimumLength' => 1, minimum_length: 2)
    end.to raise_error(ArgumentError, /duplicate password policy/)
    builder = Mxrb::RubyApp::PasswordPolicyBuilder.new
    expect { builder.minimum_length('8') }.to raise_error(TypeError, /requires an Integer/)
    expect { builder.minimum_length(-1) }.to raise_error(ArgumentError, /cannot be negative/)
    expect { builder.require_digit(:yes) }.to raise_error(TypeError, /true or false/)
    expect do
      builder.evaluate do |policy|
        policy.minimum_length(8)
        raise 'rollback'
      end
    end.to raise_error('rollback')
    expect(builder.properties).to be_empty
    expect { Mxrb::RubyApp::PasswordPolicyBuilder.new('Future' => true) }
      .to raise_error(ArgumentError, /unsupported password policy/)
  end

  it 'validates index members and restores them after a failed explicit-receiver block' do
    builder = Mxrb::RubyApp::IndexBuilder.new
    expect { builder.member('') }.to raise_error(ArgumentError, /requires a name/)
    expect { builder.member('Name', type: :future) }.to raise_error(ArgumentError, /unsupported index member/)
    expect { builder.member('Name', type: :owner) }.to raise_error(ArgumentError, /must be named Owner/)
    builder.member('Name')
    expect do
      builder.evaluate do |index|
        index.member('Code')
        raise 'rollback'
      end
    end.to raise_error('rollback')
    expect(builder.members.map(&:name)).to eq(['Name'])
  end

  it 'validates validation-rule specialization and deeply copies unusual legacy values' do
    builder = Mxrb::RubyApp::ValidationRuleBuilder.new(kind: :required)
    expect { builder.regular_expression('pattern') }
      .to raise_error(ArgumentError, /requires a regular-expression/)
    token = Object.new
    builder = Mxrb::RubyApp::ValidationRuleBuilder.new(
      kind: :regular_expression, rule_info: { nested: [+'value', :symbol, 1, true, nil, token] }
    )
    expect(builder.regular_expression('pattern')).to equal(builder)
    expect do
      builder.evaluate do |rule|
        rule.translation(:en_US, 'Invalid')
        raise 'rollback'
      end
    end.to raise_error('rollback')
    expect(builder.translations).to be_empty
    expect(builder.rule_info.fetch('RegExIdentifier')).to eq('pattern')
  end
end
# rubocop:enable Metrics/BlockLength
