# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'OQL subqueries, UNION and views over views' do
  let(:fixture) { 'spec/fixtures/native_oql_subqueries' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }
  let(:decoder) { ->(value, _type) { value } }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Subqueries.mpr')
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
    JSON.parse(File.read(File.join(fixture, 'rows.json'))).each do |entity, rows|
      rows.each do |row|
        record = @store.create("Views.#{entity}")
        record.members.merge!(row.to_h { |key, value| [key, key == 'Amount' && value ? BigDecimal(value) : value] })
        @store.commit(record)
      end
    end
  end

  def text(value) = value.is_a?(BigDecimal) ? value.to_s('F').delete_suffix('.0') : value.to_s

  def rows(item, objects)
    columns = ['Name'] + item.fetch('attributes', {}).keys
    objects.map { |members| columns.map { members[_1].nil? ? '<null>' : text(members[_1]) }.join('|') }.sort
  end

  it 'matches the native Mendix 11.12.1 results' do
    seed
    cases.each do |item|
      objects = @store.retrieve("Views.View#{item.fetch('name')}").map(&:members)
      expect(rows(item, objects)).to eq(item.fetch('expected')), item.fetch('name')
    end
  end

  it 'runs the oracle microflows in the Ruby interpreter with the same results' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project, store: @store)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h do |line|
      name, values = line.delete_prefix('ORACLE ').split('=', 2)
      [name, values.split(';').sort]
    end
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'executes the views from editable Ruby with MPR access prohibited' do
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: {})
    @store.close
    @store = @application.send(:bridge).store
    seed
    cases.each do |item|
      objects = @application.records("Views.View#{item.fetch('name')}").map { _1[:attributes] }
      expect(rows(item, objects)).to eq(item.fetch('expected')), item.fetch('name')
    end
  end

  it 'keeps view object identities stable and reflects commits through views over views' do
    seed
    first = @store.retrieve('Views.ViewChainedTwice').map(&:id).sort
    expect(@store.retrieve('Views.ViewChainedTwice').map(&:id).sort).to eq(first)
    expect(@store.retrieve('Views.ViewUnion').map(&:id).uniq.length).to eq(4)
    north = @store.retrieve('Views.Location').find { _1.members['Name'] == 'Nor' }
    @store.delete(north)
    expect(@store.retrieve('Views.ViewChainedTwice').map { _1.members['Name'] }.sort).to eq(%w[Negative North north])
  end

  it 'shares subqueries with tabular queries' do
    seed
    query = 'SELECT l.Name AS Name, (SELECT COUNT(*) FROM Views.Visit AS v WHERE v.Place = l.Name) AS Visits ' \
            'FROM Views.Location AS l WHERE EXISTS (SELECT v.Place FROM Views.Visit AS v WHERE v.Place = l.Name) ' \
            'ORDER BY Name'
    expect(@store.query_oql(query)).to eq([{ 'Name' => 'North', 'Visits' => 2 }, { 'Name' => 'north', 'Visits' => 2 },
                                           { 'Name' => 'South', 'Visits' => 1 }])
    unnamed = 'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Rank = ' \
              '(SELECT v.Total + 0 FROM Views.Visit AS v WHERE v.Total < 2 LIMIT 1)'
    expect(@store.query_oql(unnamed).map { _1['Name'] }.sort).to eq(%w[South Zero])
  end

  it 'rejects subqueries Mendix rejects or that cannot yield one value' do
    seed
    [
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Rank = (SELECT o.Rank FROM Views.Location AS o)',
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Rank = (SELECT MAX(o.Rank) + 0 FROM Views.Location AS o)',
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Name IN (SELECT v.Place, v.Total FROM Views.Visit AS v)',
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Name IN (SELECT v.Total FROM Views.Visit AS v)',
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE EXISTS l.Name',
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Name IN (SELECT v.Place FROM Views.Visit AS v',
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Rank = (SELECT l2.ID FROM Views.Location AS l2 LIMIT 1)',
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Rank = (SELECT MAX(o.Rank) FROM Views.Location AS o ' \
      'GROUP BY o.Region ORDER BY o.Amount LIMIT 1)',
      'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Name IN (SELECT o.Name FROM Views.Location AS o ' \
      'ORDER BY o.ID LIMIT 1)',
      'SELECT l.Name AS Name FROM Views.Location AS l UNION SELECT l.Name AS Name, l.Rank AS Rank ' \
      'FROM Views.Location AS l'
    ].each do |query|
      expect { Mxrb::Runtime::OqlRelationalView.new(query, @store, decoder:, decimal: nil).retrieve('X', nil) }
        .to raise_error(Mxrb::NativeRuntimeError), query
    end
    many = 'SELECT l.Name AS Name FROM Views.Location AS l WHERE l.Rank = ' \
           '(SELECT MAX(o.Rank) FROM Views.Location AS o GROUP BY o.Region)'
    expect { @store.query_oql(many) }.to raise_error(Mxrb::NativeRuntimeError, /more than one row/)
    expect { Mxrb::Runtime::OqlPredicate.new('(SELECT 1)', 'l') { nil } }
      .to raise_error(Mxrb::NativeRuntimeError, /not supported here/)
    binary = instance_double(Mxrb::Runtime::OqlSubquery, columns: [Mxrb::Runtime::OqlTable::Column.new('B', :binary)])
    expect { Mxrb::Runtime::OqlPredicate.new('1 IN (SELECT b.B FROM M.E b)', 'l', subquery: ->(*) { binary }) }
      .to raise_error(Mxrb::NativeRuntimeError, /unsupported subquery column type binary/)
  end

  it 'rejects a view that reads itself' do
    views = @store.instance_variable_get(:@views)
    entity, = views.instance_variable_get(:@definitions).fetch('Views.ViewChained')
    allow(entity).to receive(:oql_query).and_return('SELECT c.Name AS Name FROM Views.ViewChained AS c')
    expect { @store.retrieve('Views.ViewChained') }.to raise_error(Mxrb::NativeRuntimeError, /reads itself/)
    expect(views.table('Views.Location')).to be_nil
  end
end

RSpec.describe Mxrb::Runtime::OqlUnion do
  it 'splits only top-level UNION and UNION ALL' do
    expect(described_class.parts("SELECT a FROM X WHERE a = 'UNION' UNION ALL SELECT b FROM Y " \
                                 'WHERE b IN (SELECT c FROM Z UNION SELECT d FROM W) UNION SELECT e FROM V'))
      .to eq([["SELECT a FROM X WHERE a = 'UNION'", false],
              ['SELECT b FROM Y WHERE b IN (SELECT c FROM Z UNION SELECT d FROM W)', true],
              ['SELECT e FROM V', false]])
    expect(described_class.parts('SELECT a FROM X UNION')).to eq([['SELECT a FROM X', false], ['', false]])
  end
end

RSpec.describe Mxrb::Runtime::OqlRelationalQuery do
  it 'names unaliased subquery columns and keeps subquery aggregates out of the outer grouping' do
    query = described_class.new('SELECT v.Place, v.Total - Total, CASE WHEN v.Total > 1 THEN 1 ELSE 0 END, ' \
                                'AVG(v.Total) AS Mean, ' \
                                '(SELECT COUNT(*) FROM Views.Location AS l) AS Count1 FROM Views.Visit AS v')
    expect(query.projections.map(&:name)).to eq(%w[Place Column2 Column3 Mean Count1])
    expect(query.projections.last.aggregated).to be(false)
    expect(described_class.new('SELECT ROUND(SUM(v.Total), 2) AS S FROM Views.Visit AS v').grouped?).to be(true)
  end
end
# rubocop:enable Metrics/BlockLength
