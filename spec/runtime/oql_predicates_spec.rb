# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'OQL LIKE, IN, DISTINCT and HAVING execution' do
  let(:fixture) { 'spec/fixtures/native_oql_predicates' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Predicates.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load File.join(fixture, 'project.rb')
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

  def seed
    JSON.parse(File.read(File.join(fixture, 'rows.json'))).each do |row|
      record = @store.create('Views.Location')
      record.members.merge!(row.to_h do |key, value|
        [key, %w[Amount Other].include?(key) && value ? BigDecimal(value) : value]
      end)
      @store.commit(record)
    end
  end

  def names(view) = @store.retrieve("Views.View#{view}").map { _1.members.fetch('Name') }.sort

  it 'matches the native Mendix 11.12.1 matrix, including case-insensitive strings and NULL logic' do
    seed
    cases.each { |item| expect(names(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'runs the oracle microflows in the Ruby interpreter with the same results' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project, store: @store)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h do |line|
      name, values = line.delete_prefix('ORACLE ').split('=', 2)
      [name, values.delete_suffix(',').split(',', -1).drop(values.empty? ? 1 : 0).sort]
    end
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'executes the matrix from editable Ruby with MPR access prohibited' do
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: {})
    @store.close
    @store = @application.send(:bridge).store
    seed
    cases.each do |item|
      rows = @application.records("Views.View#{item.fetch('name')}").map { _1[:attributes]['Name'] }.sort
      expect(rows).to eq(item.fetch('expected')), item.fetch('name')
    end
  end

  it 'keeps distinct and grouped identities stable and reflects commits' do
    seed
    first = @store.retrieve('Views.ViewDistinctCase').map(&:id).sort
    expect(@store.retrieve('Views.ViewDistinctCase').map(&:id).sort).to eq(first)
    expect(names('GroupCase')).to eq(['North'])
    north = @store.retrieve('Views.Location').find { _1.members['Name'] == 'north' }
    @store.delete(north)
    expect(names('GroupCase')).to be_empty
    expect(names('DistinctCase')).to eq(%w[Empty Negative Nor North South Zero])
  end

  it 'shares the predicates with tabular queries and orders strings case-insensitively' do
    seed
    grouped = 'SELECT l.Nick AS Nick, COUNT(*) AS Total FROM Views.Location l ' \
              'GROUP BY l.Nick HAVING COUNT(*) > 1 ORDER BY Nick'
    expect(@store.query_oql(grouped)).to eq([{ 'Nick' => '', 'Total' => 2 }])
    distinct = "SELECT DISTINCT l.Name AS Name FROM Views.Location l WHERE l.Name LIKE 'n%' ORDER BY Name DESC"
    expect(@store.query_oql(distinct).map { _1['Name'] }).to eq(%w[North Nor Negative])
    expect(@store.query_oql('SELECT l.Name AS Name FROM Views.Location l WHERE l.Rank IN (1, 3) ' \
                            'ORDER BY Name DESC LIMIT 2').map { _1['Name'] }).to eq(%w[Zero South])
    ranks = 'SELECT DISTINCT l.Rank AS Rank FROM Views.Location l WHERE l.Rank IS NOT NULL ORDER BY Rank'
    expect(@store.query_oql(ranks).map { _1['Rank'] }).to eq([1, 2, 3])
  end

  it 'rejects HAVING outside GROUP BY and HAVING columns that are not grouped' do
    [
      'SELECT l.Name AS Name FROM Views.Location AS l HAVING COUNT(*) > 1',
      'SELECT l.Nick AS Name FROM Views.Location AS l GROUP BY l.Nick HAVING l.Name = 1',
      'SELECT l.Nick AS Name FROM Views.Location AS l GROUP BY l.Nick HAVING l.Name IS NULL',
      'SELECT l.Nick AS Name FROM Views.Location AS l GROUP BY l.Nick HAVING SUM(l.Name) > 1',
      'SELECT l.Nick AS Name FROM Views.Location AS l GROUP BY l.Nick HAVING SUM(*) > 1',
      'SELECT l.Nick AS Name FROM Views.Location AS l WHERE COUNT(*) > 1 GROUP BY l.Nick',
      'SELECT l.Nick AS Name FROM Views.Location AS l GROUP BY l.Nick HAVING',
      'SELECT DISTINCT FROM Views.Location AS l',
      'SELECT FROM Views.Location AS l'
    ].each do |query|
      expect { Mxrb::Runtime::OqlRelationalView.new(query, @store, decoder: ->(value, _type) { value }, decimal: nil) }
        .to raise_error(Mxrb::NativeRuntimeError), query
    end
  end
end

RSpec.describe Mxrb::Runtime::OqlPredicate do
  def predicate(text)
    described_class.new(text, 'l') do |column|
      type = { 'Amount' => :decimal, 'Name' => :string, 'Active' => :boolean }.fetch(column)
      [type, ->(row) { row[column] }]
    end
  end

  it 'applies three-valued logic to LIKE and IN with case-insensitive strings' do
    {
      ["Name LIKE 'a%'", { 'Name' => 'ABC' }] => true,
      ["Name LIKE 'a_c'", { 'Name' => "a\nc" }] => true,
      ["Name LIKE '.*'", { 'Name' => 'abc' }] => false,
      ["Name LIKE 'a%'", {}] => nil,
      ["Name NOT LIKE 'a%'", {}] => nil,
      ['Name LIKE NULL', { 'Name' => '' }] => true,
      ["Name IN ('X', 'y')", { 'Name' => 'Y' }] => true,
      ['Amount IN (1, NULL)', { 'Amount' => BigDecimal('2') }] => nil,
      ['Amount IN (1, NULL)', { 'Amount' => 1 }] => true,
      ['Amount NOT IN (1, NULL)', { 'Amount' => BigDecimal('2') }] => nil,
      ['Amount NOT IN (1, 3)', { 'Amount' => BigDecimal('2') }] => true,
      ['Active IN (TRUE)', { 'Active' => false }] => false,
      ["Name >= 'B'", { 'Name' => 'b' }] => true,
      ["Name < 'b'", { 'Name' => 'B' }] => false
    }.each do |(text, row), expected|
      expect(predicate(text).send(:instance_variable_get, :@expression).read.call(row)).to eq(expected), text
    end
  end
end
# rubocop:enable Metrics/BlockLength
