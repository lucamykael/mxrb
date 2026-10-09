# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'OQL value expressions' do
  let(:fixture) { 'spec/fixtures/native_oql_expressions' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      @source = File.join(directory, 'Expressions.mpr')
      ENV['MXRB_OUTPUT_PATH'] = @source
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(@source)
      @store = Mxrb::Runtime::SQLiteStore.new(@project)
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @store&.close
      @project&.close
    end
  end

  def interpreter = @interpreter ||= Mxrb::Runtime::Native::Interpreter.new(@project, store: @store)

  def logged
    interpreter.call('Views.Seed')
    cases.each { |item| interpreter.call("Views.Case#{item.fetch('name')}") }
    interpreter.instance_variable_get(:@log).to_h { _1.delete_prefix('ORACLE ').split('=', 2) }
  end

  it 'matches every native Mendix 11.12.1 result for functions, CAST, CASE, arithmetic and dates' do
    results = logged
    cases.each { |item| expect(results.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'requires computed view projections to match the view attributes' do
    entity = @project.modules.find { _1.name == 'Views' }.entities.find { _1.name == 'ViewLower' }
    view = Mxrb::Runtime::OqlRelationalView.new('SELECT LOWER(l.Name) AS Other FROM Views.Location l', @store,
                                                decoder: ->(value, _type) { value }, decimal: nil)
    expect { view.retrieve('Views.ViewLower', entity) }.to raise_error(Mxrb::NativeRuntimeError, /must match/)
  end

  it 'computes the same values in tabular queries with ordering' do
    interpreter.call('Views.Seed')
    rows = @store.query_oql('SELECT l.Name AS Name, l.Rank : 2 AS Half, l.Amount : 3 AS Third, ' \
                            'CASE WHEN l.Active THEN UPPER(l.Name) END AS Label FROM Views.Location l ' \
                            'WHERE l.Amount IS NOT NULL ORDER BY Third DESC LIMIT 2')
    expect(rows.map { [_1['Name'], _1['Half'], _1['Third'].to_s('F'), _1['Label']] })
      .to eq([['North', 1, '3002399751580331.04166666', 'NORTH'], ['north', 1, '2.33333333', 'NORTH']])
  end

  it 'fails where Mendix fails: unknown parts, untyped NULL, non-string REPLACE and out-of-range casts' do
    interpreter.call('Views.Seed')
    [
      'SELECT l.Rank + NULL AS Value FROM Views.Location l',
      "SELECT REPLACE(l.Nick, 'e', NULL) AS Value FROM Views.Location l",
      'SELECT DATEPART(MILLENNIUM, l.Moment) AS Value FROM Views.Location l',
      'SELECT DATEDIFF(WEEK, l.Moment, l.Moment) AS Value FROM Views.Location l',
      'SELECT CAST(l.Moment AS INTEGER) AS Value FROM Views.Location l',
      'SELECT CAST(l.Rank AS FLOAT) AS Value FROM Views.Location l',
      'SELECT ROUND(l.Amount, l.Rank) AS Value FROM Views.Location l',
      'SELECT l.Name + 1 AS Value FROM Views.Location l',
      'SELECT LOWER(l.Rank) AS Value FROM Views.Location l',
      'SELECT COALESCE(l.Name) AS Value FROM Views.Location l',
      'SELECT COALESCE(l.Name, l.Rank) AS Value FROM Views.Location l',
      'SELECT CASE WHEN l.Active THEN 1 ELSE l.Name END AS Value FROM Views.Location l',
      'SELECT CASE ELSE 1 END AS Value FROM Views.Location l',
      'SELECT CASE WHEN l.Active THEN NULL END AS Value FROM Views.Location l',
      'SELECT l.Name AS Name, COUNT(*) + l.Rank AS Value FROM Views.Location l GROUP BY l.Name',
      'SELECT DATEPART(YEAR, l.Name) AS Value FROM Views.Location l',
      'SELECT CAST(l.Name AS UNKNOWN) AS Value FROM Views.Location l',
      'SELECT CASE l.Rank END AS Value FROM Views.Location l',
      'SELECT l.Rank + 3000000000 AS Value FROM Views.Location l'
    ].each { |query| expect { @store.query_oql(query) }.to raise_error(Mxrb::NativeRuntimeError), query }
    {
      'SELECT CAST(l.Amount AS INTEGER) AS Value FROM Views.Location l' => /out of range/,
      'SELECT l.Amount : 0 AS Value FROM Views.Location l WHERE l.Amount IS NOT NULL' => /division by zero/,
      'SELECT l.Rank % 0 AS Value FROM Views.Location l WHERE l.Rank IS NOT NULL' => /division by zero/,
      "SELECT CAST('x' AS INTEGER) AS Value FROM Views.Location l" => /cannot cast/,
      "SELECT CAST('2024' AS DATETIME) AS Value FROM Views.Location l" => /cannot cast/,
      "SELECT REPLACE(l.Name, l.Nick, 'x') AS Value FROM Views.Location l" => /must be a string/
    }.each { |query, message| expect { @store.query_oql(query) }.to raise_error(Mxrb::NativeRuntimeError, message), query }
  end
end
# rubocop:enable Metrics/BlockLength
