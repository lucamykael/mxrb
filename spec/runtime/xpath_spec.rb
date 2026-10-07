# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/mxrb/runtime/xpath'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::XPath do
  let(:store) { Mxrb::Runtime::Native::Store.new }
  let(:first) { store.create('App.Item') }
  let(:second) { store.create('App.Item') }
  let(:tag) { store.create('App.Tag') }

  before do
    first.members.merge!('Name' => "A]B's", 'Rank' => 2, 'Active' => true, 'State' => 'App.State.Ready')
    second.members.merge!('Name' => 'Other', 'Rank' => 3, 'Active' => false)
    tag.members['Name'] = 'Tag'
    first.members['Tags'] = [tag]
    second.members['Tags'] = []
    second.members['Single'] = nil
  end

  def filter(source, variables = {})
    described_class.new(source, store:).filter([first, second], variables)
  end

  it 'evaluates escaped strings, booleans, numbers, functions, variables, enums and repeated predicates' do
    expect(filter('')).to eq([first, second])
    expect(filter("[Name = 'A]B''s'][Active and Rank >= 2]")).to eq([first])
    expect(filter("[contains(Name, 'Other') or Rank > 5]")).to eq([second])
    expect(filter('[not Active and Rank <= 3][Rank != -2]')).to eq([second])
    expect(filter('[Rank < 3 and (Active = true or Active = false)]')).to eq([first])
    expect(filter('[Rank = $currentObject/Rank]', 'currentObject' => second)).to eq([second])
    expect(filter('[State = App.State.Ready]')).to eq([first])
    expect(filter('[Name = empty]')).to eq([])
    expect(filter('[Rank = $rank]', 'rank' => 2)).to eq([first])
    expect(filter('[Active = true()][not false()]')).to eq([first])
    expect(filter('[Single = empty]')).to eq([first, second])
    expect(filter('[empty = Single]')).to eq([first, second])
    expect(filter('[App.Item.Rank = 2]')).to eq([first])
    expect(filter('[Rank * 2 + 1 = 5][Rank - 1 = 1]')).to eq([first])
    expect(filter('[Rank div 2 = 1][Rank mod 2 = 0]')).to eq([first])
    first.members['Created'] = Time.now - 1
    second.members['Created'] = nil
    expect(described_class.new('[Created < [%CurrentDateTime%]]', store:).filter([first])).to eq([first])
    expect(filter('[Created < [%CurrentDateTime%]]')).to eq([first])
    expect(filter('[empty < Rank]')).to eq([])
  end

  it 'rejects slash division before evaluating any records, including nested and unreachable operands' do
    ['[Rank / 2 = 1]', '[6 / 2 = 3]', '[(Rank) / 2 = 1]', '[Rank / $divisor = 1]',
     '[true() or Rank / 2 = 1]', '[App.Tags[Rank / 2 = 1]/App.Tag]',
     '[length(Name) / 2 = 1]'].each do |source|
      expect { described_class.new(source, store:).filter([]) }.to raise_error(ArgumentError, /invalid XPath/)
    end
  end

  it 'preserves slashes in association paths, variable members and string values' do
    tag.members['Name'] = 'docs/reference'
    expect(filter("[App.Tags/App.Tag/Name = 'docs/reference']")).to eq([first])
    expect(filter('[App.Tags/App.Tag/Name = $tag/Name]', 'tag' => tag)).to eq([first])
    expect(filter("[contains(App.Tags/App.Tag/Name, '/')]")).to eq([first])
  end

  it 'matches native signed integer division and remainder while preserving decimal quotients' do
    first.members.merge!('Rank' => -12, 'Amount' => BigDecimal('-12.5'))
    second.members.merge!('Rank' => 12, 'Amount' => BigDecimal('12.5'))
    expect(filter('[Rank div 5 = -2][Rank mod 5 = -2]')).to eq([first])
    expect(filter('[Rank div 5 = -3][Rank mod 5 = 3]')).to eq([])
    expect(filter('[Rank div -5 = -2][Rank mod -5 = 2]')).to eq([second])
    expect(filter('[Amount div 5 = -2.5][Amount mod 5 = -2.5]')).to eq([first])
    expect(filter('[Amount div 5 = 2.5][Amount mod 5 = 2.5]')).to eq([second])
    expect(filter('[Rank div 5.0 = 2.4]')).to eq([second])
    expect { filter('[Rank mod 0 = 1]') }.to raise_error(ArgumentError, /invalid XPath operand/)
  end

  it 'uses existential comparisons, related-object predicates and inverse traversal' do
    expect(filter('[App.Tags/App.Tag/Name = \'Tag\']')).to eq([first])
    expect(filter("[App.Tags[Name = 'Tag']/App.Tag]")).to eq([first])
    expect(filter('[App.Tags = $tag]', 'tag' => tag)).to eq([first])
    expect(filter('[id = $id]', 'id' => first.id)).to eq([first])
    reverse = described_class.new('[App.Tags/App.Item[Rank = 2]]', store:)
    expect(reverse.filter([tag])).to eq([tag])
    first.members['Single'] = tag
    expect(filter('[Single/App.Tag = $tag]', 'tag' => tag)).to eq([first])
  end

  it 'coerces numeric query parameters to integer operands without truncating decimal columns' do
    first.members.merge!('Rank' => -12, 'Amount' => BigDecimal('-12.4'))
    second.members.merge!('Rank' => 12, 'Amount' => BigDecimal('12.4'))
    expect(filter('[Rank = 12.4][12.4 = Rank][Rank div 5 = 2.9]')).to eq([second])
    expect(filter('[Rank = -12.4][-12.4 = Rank][Rank div 5 = -2.9]')).to eq([first])
    expect(filter('[Rank < 12.4][Rank != 12.4]')).to eq([first])
    expect(filter('[Rank = Amount]')).to eq([])
    expect(filter('[Amount = Rank]')).to eq([])
    expect(filter('[12 = 12.4][12.4 != 12]')).to eq([first, second])
    expect(filter('[-Rank = 12.4]')).to eq([first])
    expect(filter('[Rank = $v][$v = Rank]', 'v' => BigDecimal('12.4'))).to eq([second])
    expect(filter('[Amount = $v]', 'v' => 12)).to eq([])
    expect(filter('[Tags/Rank = 12.4]')).to eq([])
  end

  it 'rejects malformed expressions, unknown variables, invalid traversal and excessive nesting' do
    ['[', '[]', ']', "[Name = 'bad]", 'Name = 1', '[[Name = 1]]', '[Rank =]', '[Name = 2 3]', '[!]',
     '[contains(Name,)]', '[contains()]', '[Name/Other = 1]', '[Rank = $missing]',
     '[Rank = $rank/Value]', '[mystery(Name)]'].each do |source|
      expect { filter(source, 'rank' => 2) }.to raise_error(ArgumentError)
    end
    expect { filter('x' * 8193) }.to raise_error(ArgumentError, /too large/)
    expect { filter("[#{'not ' * 33}true]") }.to raise_error(ArgumentError, /nesting/)
    expect { filter('[contains(Tags, \'Tag\')]') }.to raise_error(ArgumentError, /string attribute/)
    expect { filter('[contains(Name, Single)]') }.to raise_error(ArgumentError, /single value/)
    expect { filter('[Single + 1 = 2]') }.to raise_error(ArgumentError, /single value/)
    expect { filter('[Rank div 0 = 2]') }.to raise_error(ArgumentError, /invalid XPath operand/)
  end

  it 'reverses only the marked self-association step, including nested predicates and multiple hops' do
    leaf = store.create('App.Item')
    first.members['Parent'] = nil
    second.members['Parent'] = first
    leaf.members['Parent'] = second
    tag.members['Parent'] = first
    variables = { 'root' => first, 'leaf' => leaf }
    expect(filter('[App.Parent = $root]', variables)).to eq([second])
    expect(filter('[App.Parent[reversed()] = $leaf]', variables)).to eq([second])
    expect(filter('[App.Parent[reversed()]/App.Item/App.Parent = $root]', variables)).to eq([first])
    expect(filter('[App.Parent[reversed()][Rank = 3]/App.Item]', variables)).to eq([first])
    expect(filter('[App.Parent[reversed()]/App.Item/App.Parent[reversed()] = $leaf]', variables)).to eq([first])
    second.members['App.Links'] = [first, leaf, 'unrelated']
    expect(filter('[App.Links[reversed()] = $leaf]', variables)).to eq([])
    expect(filter('[App.Links[reversed()]/App.Item[Rank = 3]]')).to eq([first])
    second.members['App.Links'] = [tag]
    expect(filter('[App.Links[reversed()]/App.Item]')).to eq([])
  end

  it 'validates reverse markers even before querying an empty table' do
    ['[reversed()]', '[App.Parent[reversed(1)]]', '[App.Parent[reversed() or true]]',
     '[App.Parent[reversed()][reversed()]]', '[not reversed()]'].each do |source|
      expect { described_class.new(source, store:).filter([]) }.to raise_error(ArgumentError)
    end
  end

  it 'keeps an attribute named reversed separate from the reversed() marker' do
    first.members['reversed'] = true
    second.members['reversed'] = false
    second.members['Parent'] = first
    expect(filter('[reversed = true]')).to eq([first])
    expect(filter('[App.Parent[reversed = true]/App.Item]')).to eq([second])
  end

  it 'enforces association permissions and related record visibility in reverse paths' do
    second.members['Parent'] = first
    policy = instance_double(Mxrb::Runtime::AccessControl)
    allow(policy).to receive(:entity_allowed?).and_return(true)
    allow(policy).to receive(:authorize!).and_return(true)
    query = described_class.new('[App.Parent[reversed()]/App.Item/Rank = 3]', store:, policy:, context: :reader)
    expect(query.filter([first])).to eq([first])
    expect(policy).to have_received(:authorize!).with('App.Item', kind: :entity, action: :read,
                                                                  context: :reader, member: 'Parent', record: first)
    allow(policy).to receive(:entity_allowed?).with('App.Item', action: :read, context: :reader, record: second)
                                              .and_return(false)
    expect(query.filter([first])).to eq([])
    allow(policy).to receive(:authorize!).and_raise(Mxrb::Runtime::AuthorizationError)
    expect { query.filter([first]) }.to raise_error(Mxrb::Runtime::AuthorizationError)
  end

  it 'evaluates the documented string and date functions over association attribute sets' do
    another = store.create('App.Tag')
    another.members['Name'] = 'Another'
    first.members['Tags'] << another
    expect(filter("[starts-with(App.Tags/App.Tag/Name, 'An')][ends-with(Name, 's')]")).to eq([first])
    expect(filter('[string-length(Name) = 5][length(Name) = 5]')).to eq([first, second])
    expect(filter('[contains(Name, Name)]')).to eq([first, second])
    expect(filter('[Single = NULL]')).to eq([first, second])
    first.members['Created'] = Time.utc(2021, 1, 3, 2, 4, 5)
    second.members['Created'] = nil
    parts = { 'year' => 2021, 'month' => 1, 'day' => 3, 'hours' => 2, 'minutes' => 4,
              'seconds' => 5, 'quarter' => 1, 'day-of-year' => 3, 'week' => 53, 'weekday' => 1 }
    parts.each do |part, expected|
      expect(filter("[#{part}-from-dateTime(Created, 'UTC') = #{expected}]")).to eq([first]), part
    end
    expect(filter("[day-from-dateTime(Created, 'America/Boa_Vista') = 2]")).to eq([first])
    context = Mxrb::Runtime::SecurityContext.new(attributes: { 'time_zone' => 'America/Boa_Vista' })
    expect(described_class.new('[hours-from-dateTime(Created) = 22]', store:, context:).filter([first])).to eq([first])
    expect(filter("[length('abc') = 3]")).to eq([first, second])
    expect(filter('[length(empty) = empty]')).to eq([first, second])
  end

  it 'rejects invalid function arity, types and time zones without expanding unauthorized paths' do
    first.members['Created'] = Time.utc(2026)
    ['[length(Name, 1)]', '[contains(Name, 1)]', '[year-from-dateTime(Name)]',
     "[year-from-dateTime(Created, '+02:00')]", '[contains(Name, Tags)]'].each do |source|
      expect { filter(source) }.to raise_error(ArgumentError)
    end
    policy = instance_double(Mxrb::Runtime::AccessControl)
    allow(policy).to receive(:entity_allowed?).and_return(true)
    allow(policy).to receive(:authorize!).and_raise(Mxrb::Runtime::AuthorizationError)
    query = described_class.new("[starts-with(App.Tags/App.Tag/Name, 'T')]", store:, policy:)
    expect { query.filter([first]) }.to raise_error(Mxrb::Runtime::AuthorizationError)
  end

  it 'resolves the current time at execution rather than freezing it when the query is parsed' do
    now = Time.utc(2026)
    first.members['Created'] = now + 10
    allow(Time).to receive(:now).and_return(now)
    query = described_class.new('[Created < [%CurrentDateTime%]]', store:)
    expect(query.filter([first])).to eq([])
    allow(Time).to receive(:now).and_return(now + 20)
    expect(query.filter([first])).to eq([first])
  end

  it 'enforces record and member permissions at every traversal and variable dereference' do
    policy = instance_double(Mxrb::Runtime::AccessControl)
    allow(policy).to receive(:entity_allowed?).and_return(true)
    allow(policy).to receive(:authorize!).and_return(true)
    query = described_class.new('[App.Tags/App.Tag/Name = \'Tag\']', store:, policy:, context: :reader)
    expect(query.filter([first])).to eq([first])
    expect(policy).to have_received(:authorize!).with('App.Tag', kind: :entity, action: :read,
                                                                 context: :reader, member: 'Name', record: tag)
    allow(policy).to receive(:authorize!).with('App.Tag', anything).and_raise(Mxrb::Runtime::AuthorizationError)
    expect { query.filter([first]) }.to raise_error(Mxrb::Runtime::AuthorizationError)
    allow(policy).to receive(:entity_allowed?).with('App.Tag', anything).and_return(false)
    expect(query.filter([first])).to eq([])
    query = described_class.new('[Name = $currentObject/Name]', store:, policy:)
    expect { query.filter([first], 'currentObject' => tag) }.to raise_error(Mxrb::Runtime::AuthorizationError)
    expect(query.filter([first], 'currentObject' => first)).to eq([first])
    allow(policy).to receive(:entity_allowed?).and_return(false)
    expect(query.filter([first])).to eq([])
  end
end
# rubocop:enable Metrics/BlockLength
