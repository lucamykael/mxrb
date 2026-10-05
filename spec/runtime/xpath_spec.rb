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
    expect(filter('[Rank / 2 = 1][Rank div 2 = 1][Rank mod 2 = 0]')).to eq([first])
    first.members['Created'] = Time.now - 1
    second.members['Created'] = nil
    expect(described_class.new('[Created < [%CurrentDateTime%]]', store:).filter([first])).to eq([first])
    expect(filter('[Created < [%CurrentDateTime%]]')).to eq([first])
    expect(filter('[empty < Rank]')).to eq([])
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

  it 'rejects malformed expressions, unknown variables, invalid traversal and excessive nesting' do
    ['[', '[]', ']', "[Name = 'bad]", 'Name = 1', '[[Name = 1]]', '[Rank =]', '[Name = 2 3]', '[!]',
     '[contains(Name,)]', '[contains()]', '[Name/Other = 1]', '[Rank = $missing]',
     '[Rank = $rank/Value]', '[mystery(Name)]'].each do |source|
      expect { filter(source, 'rank' => 2) }.to raise_error(ArgumentError)
    end
    expect { filter('x' * 8193) }.to raise_error(ArgumentError, /too large/)
    expect { filter("[#{'not ' * 33}true]") }.to raise_error(ArgumentError, /nesting/)
    expect { filter('[contains(Tags, \'Tag\')]') }.to raise_error(ArgumentError, /single value/)
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
