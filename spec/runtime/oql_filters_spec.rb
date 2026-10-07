# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'OQL WHERE execution' do
  let(:cases) { JSON.parse(File.read('spec/fixtures/native_oql_filters/cases.json')) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Filters.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load 'spec/fixtures/native_oql_filters/project.rb'
      @project = Mxrb.open(@source)
      @store = Mxrb::Runtime::SQLiteStore.new(@project)
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      @store&.close
      @project&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  let(:seed_rows) do
    [
      ['North', 'SELECT WHERE FROM', '9007199254740993.125', '9007199254740993.125', true],
      ['South', "O'Brien", '2.5', '3', false],
      ['Empty', nil, nil, nil, true],
      ['Zero', '', '0', nil, false],
      ['Negative', '', '-1.25', '1', false]
    ]
  end

  def seed
    seed_rows.each do |name, nick, amount, other, active|
      record = @store.create('Views.Location')
      record.members.merge!('Name' => name, 'Nick' => nick, 'Amount' => amount && BigDecimal(amount),
                            'Other' => other && BigDecimal(other), 'Active' => active)
      @store.commit(record)
    end
  end

  it 'matches the native filter matrix without losing decimal precision or NULL semantics' do
    seed
    cases.each do |item|
      names = @store.retrieve("Views.View#{item.fetch('name')}").map { _1.members.fetch('Name') }.sort
      expect(names).to eq(item.fetch('expected')), item.fetch('name')
    end
  end

  it 'filters durable rows and reflects committed changes and deletions' do
    seed
    north = @store.retrieve('Views.Location').find { _1.members['Name'] == 'North' }
    north.members['Amount'] = BigDecimal('2.5')
    expect(@store.count('Views.ViewExact')).to eq(1)
    @store.commit(north)
    expect(@store.count('Views.ViewExact')).to eq(0)
    expect(@store.count('Views.ViewGreaterEqual')).to eq(2)
    @store.delete(north)
    expect(@store.count('Views.ViewGreaterEqual')).to eq(1)
  end

  it 'executes the complete matrix from editable Ruby with MPR access prohibited' do
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: {})
    @store.close
    @store = @application.send(:bridge).store
    seed
    cases.each do |item|
      names = @application.records("Views.View#{item.fetch('name')}").map { _1[:attributes]['Name'] }.sort
      expect(names).to eq(item.fetch('expected')), item.fetch('name')
    end
  end
end

RSpec.describe Mxrb::Runtime::OqlPredicate do
  def predicate(text)
    described_class.new(text, 'l') do |column|
      type = { 'Amount' => :decimal, 'Other' => :decimal, 'Name' => :string,
               'Active' => :boolean, 'Custom' => :binary }.fetch(column) do
        raise Mxrb::NativeRuntimeError, "Unknown source attribute #{column}"
      end
      [type, ->(row) { row[column] }]
    end
  end

  it 'retains three-valued logic in nested combinations and distinguishes literals from columns' do
    {
      'TRUE OR FALSE' => true, 'FALSE OR FALSE' => false, 'FALSE OR NULL' => false,
      'TRUE AND TRUE' => true, 'TRUE AND NULL' => false, 'NOT NULL' => false,
      'Amount = NULL' => true, 'NULL = Amount' => true, 'Amount != NULL' => false,
      'Amount = Other' => false, 'NOT (Amount = Other)' => false,
      'Amount != 2.5' => true, '2.5 != Amount' => true, 'NOT (Amount = 2.5)' => true,
      'NULL > Amount' => false, 'Amount < NULL' => false, 'NULL < NULL' => false,
      'NOT (FALSE AND NULL)' => true, 'NOT (NULL OR TRUE)' => false,
      'Name IS NOT NULL' => false
    }.each { |text, expected| expect(predicate(text).call({})).to eq(expected), text }
    expect(predicate('Amount = Other').call('Amount' => 1)).to be(false)
    expect(predicate('l/Amount = +2.5').call('Amount' => BigDecimal('2.5'))).to be(true)
    expect(predicate("Name = 'a''b'").call('Name' => "a'b")).to be(true)
  end

  it 'rejects unsupported or ill-typed predicates before any rows are read' do
    [
      '', 'Amount >', 'Amount IS', 'Amount IS NOT TRUE', '(Active', 'Active)',
      'Amount = 1; DROP TABLE x', 'Amount = 1 -- comment', "Name = 'unfinished",
      'Amount IN (1, 2)', 'Amount <> 1', 'Name LIKE \'%x\'', 'x.Amount = 1',
      'l. = 1', 'Missing = 1', 'Custom IS NULL', 'Amount', 'Amount AND TRUE',
      'TRUE OR Amount', 'NOT Name', 'Amount = TRUE', "Name > 'a'", 'Amount = 1e2',
      'l.Amount/Name = 1', 'Amount = $parameter', 'Amount = 1 /* comment */'
    ].each do |text|
      expect { predicate(text) }.to raise_error(Mxrb::NativeRuntimeError), text
    end
  end
end

RSpec.describe Mxrb::Runtime::OqlViewQuery do
  it 'rejects unsupported query structures rather than silently dropping a constraint' do
    [
      'SELECT Name FROM Views.Location WHERE',
      'garbage SELECT Name FROM Views.Location',
      'SELECT Name WHERE Active FROM Views.Location',
      'SELECT Name FROM Views.Location JOIN Views.Other ON TRUE',
      'SELECT Name FROM Views.Location WHERE Active SELECT Name',
      'FROM Views.Location WHERE Active SELECT *'
    ].each do |text|
      expect do
        query = described_class.new(text)
        Mxrb::Runtime::OqlPredicate.new(query.filter, query.scope) { [:boolean, ->(_row) { true }] } if query.filter
      end.to raise_error(Mxrb::NativeRuntimeError), text
    end
  end
end
# rubocop:enable Metrics/BlockLength
