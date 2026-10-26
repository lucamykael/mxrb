# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/text_merge'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::TextMerge do
  let(:base) { "entity :Order do\n  decimal :Total\nend\n" }

  it 'merges a changed line with an insertion next to it' do
    ours = "entity :Order do\n  decimal :Total # the total\nend\n"
    theirs = "entity :Order do\n  decimal :Total\n  string :Note\nend\n"
    expect(described_class.merge(base, ours, theirs))
      .to eq(["entity :Order do\n  decimal :Total # the total\n  string :Note\nend\n", 0])
    expect(described_class.merge(base, theirs, ours))
      .to eq(["entity :Order do\n  decimal :Total # the total\n  string :Note\nend\n", 0])
  end

  it 'marks edits of the same line with the side labels, or settles them in favour of one side' do
    ours = base.sub('Total', 'Amount')
    theirs = base.sub('Total', 'Sum')
    text, conflicts = described_class.merge(base, ours, theirs)
    expect(conflicts).to eq(1)
    expect(text).to eq("entity :Order do\n<<<<<<< ruby\n  decimal :Amount\n||||||| base\n  decimal :Total\n" \
                       "=======\n  decimal :Sum\n>>>>>>> mendix\nend\n")
    expect(described_class.merge(base, ours, theirs, labels: %w[a b c]).first).to include('<<<<<<< a', '>>>>>>> c')
    expect(described_class.merge(base, ours, theirs, favor: :ours)).to eq([ours, 1])
    expect(described_class.merge(base, ours, theirs, favor: :theirs)).to eq([theirs, 1])
  end

  it 'accepts the same change on both sides and keeps separate edits of one side apart' do
    same = base.sub('Total', 'Sum')
    expect(described_class.merge(base, same, same)).to eq([same, 0])
    text = "a\nb\nc\nd\ne\n"
    ours = "A\nb\nc\nd\nE\n"
    expect(described_class.merge(text, ours, text)).to eq([ours, 0])
    expect(described_class.merge(text, ours, "a\nb\nC\nd\ne\n")).to eq(["A\nb\nC\nd\nE\n", 0])
  end

  it 'conflicts on two different insertions at the same place and merges deletions' do
    text, conflicts = described_class.merge("a\nb\n", "a\nX\nb\n", "a\nY\nb\n")
    expect(conflicts).to eq(1)
    expect(text).to eq("a\n<<<<<<< ruby\nX\n||||||| base\n=======\nY\n>>>>>>> mendix\nb\n")
    expect(described_class.merge("a\nb\nc\n", "a\nc\n", "a\nb\nc\nd\n")).to eq(["a\nc\nd\n", 0])
    expect(described_class.merge("a\nb\nc\n", "a\nX\nb\nc\n", "a\nc\n")).to eq(["a\nX\nc\n", 0])
    expect(described_class.merge("a\nb\nc\n", "a\nc\n", "a\nX\nb\nc\n")).to eq(["a\nX\nc\n", 0])
  end

  it 'terminates conflicting lines that have no final newline' do
    text, conflicts = described_class.merge('a', 'b', 'c')
    expect(conflicts).to eq(1)
    expect(text).to eq("<<<<<<< ruby\nb\n||||||| base\na\n=======\nc\n>>>>>>> mendix\n")
    expect(described_class.merge('', 'x', '')).to eq(['x', 0])
  end

  it 'finds matches inside changed regions, around a common prefix and suffix' do
    before = %W[head\n a\n b\n c\n tail\n]
    after = %W[head\n x\n a\n y\n c\n z\n tail\n]
    expect(described_class.matches(before, after)).to eq([[0, 0], [1, 2], [3, 4], [4, 6]])
    expect(described_class.myers(%W[a\n b\n], %W[a\n c\n])).to eq([[0, 0]])
    expect(described_class.myers([], %W[a\n])).to eq([])
  end

  it 'treats files that differ in more lines than the edit limit as rewritten' do
    stub_const("#{described_class}::MAXIMUM_EDITS", 2)
    before = %W[a\n b\n c\n d\n]
    after = %W[x\n b\n y\n z\n w\n]
    expect(described_class.myers(before, after)).to eq([])
    expect(described_class.merge(before.join, after.join, before.join)).to eq([after.join, 0])
  end

  it 'reproduces any one-sided edit exactly' do
    random = Random.new(20_261_023)
    300.times do
      original = Array.new(random.rand(25)) { "#{%w[a b c d e].sample(random:)}\n" }
      edited = original.dup
      random.rand(5).times { edited.insert(random.rand(edited.size + 1), "#{%w[x y].sample(random:)}\n") }
      random.rand(3).times { edited.delete_at(random.rand(edited.size)) unless edited.empty? }
      pairs = described_class.matches(original, edited)
      expect(pairs.all? { |left, right| original[left] == edited[right] }).to be(true)
      expect(pairs.each_cons(2).all? { |(a, b), (c, d)| c > a && d > b }).to be(true)
      expect(described_class.merge(original.join, edited.join, original.join)).to eq([edited.join, 0])
      expect(described_class.merge(original.join, original.join, edited.join)).to eq([edited.join, 0])
    end
  end
end
# rubocop:enable Metrics
