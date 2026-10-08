# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'OQL dataset execution' do
  let(:cases) { JSON.parse(File.read('spec/fixtures/native_oql_datasets/cases.json')) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Application.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load 'spec/fixtures/native_oql_datasets/project.rb'
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
    Mxrb::Runtime::Native::Interpreter.new(@project, store: @store).call('Hr.Seed')
  end

  def normalize(rows, item)
    return rows unless item.key?('tie_column')

    rows.chunk { _1.split('|')[item.fetch('tie_column')] }.flat_map { |_key, values| values.sort }
  end

  def rendered(rows, item)
    values = rows.map do |row|
      item.fetch('attributes').map do |name, type|
        render_value(row.fetch(name), type)
      end.join('|')
    end
    normalize(values, item)
  end

  def render_value(value, type)
    if value.nil? || value == ''
      '<null>'
    elsif type == 'datetime'
      value.utc.strftime('%Y-%m-%d')
    elsif type == 'decimal'
      Mxrb::Runtime::DecimalValues.text(value)
    else
      value.to_s
    end
  end

  def select_test_adapters
    directory = File.join(@directory, 'javasource', 'hr', 'actions')
    FileUtils.mkdir_p(directory)
    source = "// explicitly selected test adapter\n"
    sources = %w[RetrieveDatasetOql RetrieveAdvancedOql].to_h do |name|
      File.write(File.join(directory, "#{name}.java"), source)
      [name, [Digest::SHA256.hexdigest(source)]]
    end
    stub_const('Mxrb::RubyApp::KnownOqlActions::SOURCES', sources)
  end

  def export_application
    select_test_adapters
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    target
  end

  it 'matches the native ordered result matrix for dataset names and explicit text' do
    seed
    cases.each do |item|
      expect(rendered(@store.query_dataset("Hr.#{item.fetch('name')}"), item)).to eq(item.fetch('expected'))
      expect(rendered(@store.query_oql(item.fetch('query')), item)).to eq(item.fetch('expected'))
    end
  end

  it 'uses both source-selected Java adapters from editable Ruby with MPR access prohibited' do
    target = export_application
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: { 'MXRB_DATABASE_PATH' => ':memory:' })
    @application.call_service('Hr.Seed')
    cases.each do |item|
      %w[Dataset Text].each do |mode|
        @application.call_service("Hr.#{item.fetch('name')}#{mode}")
        message = @application.send(:bridge).interpreter.effects.fetch(0).fetch(:message)
        rows = message.delete_prefix('Rows:').split(';')
        expect(normalize(rows, item)).to eq(item.fetch('expected')), "#{item.fetch('name')}#{mode}"
      end
    end
  end

  it 'reads committed rows and creates separate uncommitted result objects without persisting a result table' do
    seed
    employee = @store.retrieve('Hr.Employee').find { _1.members['Name'] == 'A' }
    employee.members['Name'] = 'Changed'
    query = 'SELECT e.Name AS Name FROM Hr.Employee e ORDER BY Name'
    first = @store.oql_objects(query, 'Hr.Result')
    second = @store.oql_objects(query, 'Hr.Result')
    expect(first.map { _1.members['Name'] }).to include('A')
    expect(first.map(&:id) & second.map(&:id)).to be_empty
    expect(@store.schema.entities.map(&:name)).not_to include('Hr.Result')
    @store.commit(employee)
    expect(@store.query_oql(query).map { _1.fetch('Name') }).to include('Changed')
    @store.delete(employee)
    expect(@store.query_oql(query).size).to eq(7)
    expect(@store.dataset_objects('Hr.IgnoredColumn', 'Hr.Result').first.members).not_to have_key('Ignored')
  end

  it 'validates queries, orders, output types and nested sources before reading empty tables' do
    invalid = [
      '', 'DELETE FROM Hr.Employee', 'SELECT e.Name AS Name FROM Hr.Employee e)',
      'SELECT (e.Name AS Name FROM Hr.Employee e',
      'SELECT e.Name AS Name FROM Hr.Employee e HAVING TRUE',
      'SELECT e.Name AS Name FROM Hr.Employee e UNION SELECT e.Name AS Name FROM Hr.Employee e',
      'SELECT e.Name AS Name FROM Hr.Employee e ORDER Name',
      'SELECT e.Name AS Name FROM Hr.Employee e ORDER BY Name INVALID',
      'SELECT e.Name AS Name FROM Hr.Employee e ORDER BY',
      'SELECT e.Name AS Name FROM Hr.Employee e ORDER BY Name,',
      'SELECT e.Name AS Name FROM Hr.Employee e ORDER BY Unknown',
      'SELECT e.Name AS Name FROM Hr.Employee e ORDER BY e.Salary',
      'SELECT e.ID AS Name FROM Hr.Employee e ORDER BY Name',
      'SELECT e.Name AS Name FROM Hr.Employee e LIMIT -1',
      'SELECT e.Name AS Name FROM Hr.Employee e OFFSET 1.5',
      'SELECT e.Name AS Name FROM Hr.Employee e LIMIT 1; DELETE FROM Hr.Employee',
      'SELECT e.Name AS Name, e.Salary AS Name FROM Hr.Employee e',
      'SELECT t.Name AS Name FROM (SELECT e.Name AS Name FROM Hr.Employee e)',
      'SELECT t.Name AS Name FROM (SELECT e.Name AS Name FROM Hr.Employee e) t JOIN Hr.Department d ON TRUE',
      'SELECT t.Name AS Name FROM (SELECT e.Name AS Name FROM Hr.Employee e ORDER BY Name) t',
      'SELECT t.Missing AS Name FROM (SELECT e.Name AS Name FROM Hr.Employee e) t',
      'SELECT t.Name AS Name FROM (SELECT e.Unknown AS Name FROM Hr.Employee e) t',
      "SELECT e.Name AS Name FROM Hr.Employee e WHERE e.Name LIKE 'A%'"
    ]
    nested = 'SELECT e.Name AS Name FROM Hr.Employee e'
    18.times { nested = "SELECT t.Name AS Name FROM (#{nested}) t" }
    invalid << nested
    expect(@store.database).not_to receive(:execute).with(/\ASELECT \*/)
    invalid.each { |query| expect { @store.query_oql(query) }.to raise_error(Mxrb::NativeRuntimeError), query }
    expect { @store.oql_objects('SELECT e.Salary AS Name FROM Hr.Employee e', 'Hr.Result') }
      .to raise_error(Mxrb::NativeRuntimeError, /result column Name/)
    expect { @store.oql_objects('SELECT e.Name AS Name FROM Hr.Employee e', 'Hr.Missing') }
      .to raise_error(Mxrb::NativeRuntimeError, /unknown result entity/)
  end

  it 'rejects unknown, excluded, parameterized and non-OQL datasets explicitly' do
    definitions = [
      ['Hr.Excluded', 'SELECT e.Name AS Name FROM Hr.Employee e', [], true],
      ['Hr.Parameters', 'SELECT e.Name AS Name FROM Hr.Employee e', ['Name'], false],
      ['Hr.OtherSource', nil, [], false]
    ].map { Mxrb::Runtime::OqlDatasets::Definition.new(*_1) }
    allow(Mxrb::Runtime::OqlDatasets).to receive(:definitions).and_return(definitions)
    @store.close
    @store = Mxrb::Runtime::SQLiteStore.new(@project)
    %w[Missing Excluded Parameters OtherSource].each do |name|
      expect { @store.query_dataset("Hr.#{name}") }.to raise_error(Mxrb::NativeRuntimeError)
    end
  end

  it 'retains derived-column types, equal sort keys and pagination beyond the end' do
    seed
    expect(@store.query_oql('SELECT t.ID AS RowsCount FROM ' \
                           '(SELECT COUNT(*) AS ID FROM Hr.Employee e) t ORDER BY t.ID'))
      .to eq([{ 'RowsCount' => 8 }])
    expect(@store.query_oql('SELECT e.Name AS Name FROM Hr.Employee e LIMIT 2 OFFSET 30')).to be_empty
    expect(@store.query_oql('SELECT t.Name AS Name FROM ' \
                           '(SELECT e.Name AS Name FROM Hr.Employee e ORDER BY Name OFFSET 7) AS t'))
      .to eq([{ 'Name' => 'H' }])
  end

  it 'reloads query edits and preserves them across Ruby to MPR and another Ruby export' do
    target = export_application
    @application = Mxrb::RubyApp::Application.new(target, reload: true,
                                                          process: { 'MXRB_DATABASE_PATH' => File.join(@directory,
                                                                                                       'reload.db') })
    @application.call_service('Hr.Seed')
    path = File.join(target, 'app', 'datasets', 'hr', 'name_asc.rb')
    File.write(path, File.read(path).sub('ORDER BY e.Name', 'ORDER BY e.Name DESC'))
    expect(@application.reload_if_changed!).to be(true)
    @application.call_service('Hr.NameAscDataset')
    expect(@application.send(:bridge).interpreter.effects.first.fetch(:message)).to start_with('Rows:H|')
    rebuilt = File.join(@directory, 'rebuilt', 'Application.mpr')
    Mxrb::RubyApp.compile(target, rebuilt, mendix_version: '11.12.1')
    Mxrb.open(rebuilt) do |project|
      expect(project.oql_queries.find { _1.qualified_name == 'Hr.NameAsc' }.oql).to end_with('ORDER BY e.Name DESC')
    end
    again = File.join(@directory, 'again')
    Mxrb::Exporter.new(rebuilt, again, mode: :ruby).export!
    expect(File.read(File.join(again, 'app', 'datasets', 'hr', 'name_asc.rb'))).to eq(File.read(path))
  end
end
# rubocop:enable Metrics/BlockLength
