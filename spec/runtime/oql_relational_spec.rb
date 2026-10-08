# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Relational OQL views' do
  let(:cases) { JSON.parse(File.read('spec/fixtures/native_oql_relational/cases.json')) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Relational.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load 'spec/fixtures/native_oql_relational/project.rb'
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
    Mxrb::Runtime::Native::Interpreter.new(@project, store: @store).call('Views.Seed')
  end

  def rows(item)
    @store.retrieve("Views.View#{item.fetch('name')}").map do |record|
      columns = item.fetch('attributes').map { |name, type| render_value(record.members.fetch(name), type) }
      columns << render_reference(record, item.fetch('reference')) if item['reference']
      columns.join('|')
    end.sort
  end

  def render_value(value, type)
    return '<null>' if value.nil? || value == ''
    return value.utc.strftime('%Y-%m-%d') if type == 'datetime'
    return Mxrb::Runtime::DecimalValues.text(value) if type == 'decimal'

    value.to_s
  end

  def render_reference(record, reference)
    target = @store.retrieve_association("Views.#{reference.fetch('name')}", record).first
    target ? target.members.fetch(reference.fetch('attribute')) : '<null>'
  end

  def set_query(text, name: 'InnerPath')
    @project.modules.first.entities.find { _1.name == "View#{name}" }.oql_query = text
  end

  it 'matches every native join and aggregate result with exact decimals, dates and NULLs' do
    seed
    cases.each { |item| expect(rows(item)).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'executes the same matrix from editable Ruby after MPR access is prohibited' do
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: {})
    @store.close
    @store = @application.send(:bridge).store
    @application.call_service('Views.Seed')
    cases.each { |item| expect(rows(item)).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'reads durable attributes and associations, keeps group identities and reflects commits and deletions' do
    seed
    grouped = -> { @store.retrieve('Views.ViewGroupedFull').find { _1.members['Department'] == 'North' } }
    original = grouped.call
    expect(original.members['TotalSalary']).to eq(BigDecimal('36'))
    employee = @store.retrieve('Views.Employee').find { _1.members['Name'] == 'A' }
    south = @store.retrieve('Views.Department').find { _1.members['Name'] == 'South' }
    employee.members.merge!('Salary' => BigDecimal('1'), 'Employee_Department' => south)
    expect(grouped.call).to eq(original)
    @store.commit(employee)
    expect(grouped.call.id).to eq(original.id)
    expect(grouped.call.members['TotalSalary']).to eq(BigDecimal('25.875'))
    @store.delete(employee)
    expect(@store.retrieve('Views.ViewLeftPath').map { _1.members['Employee'] }).not_to include('A')
    @store.delete(@store.retrieve('Views.Department'))
    expect(@store.retrieve('Views.ViewInnerPath')).to be_empty
    expect(@store.count('Views.ViewFullPath')).to eq(7)
    @store.delete(@store.retrieve('Views.Employee'))
    expect(@store.retrieve('Views.ViewFullPath')).to be_empty
    expect(@store.retrieve('Views.ViewGlobalAggregate').first.members)
      .to include('RowsCount' => 0, 'TotalSalary' => nil)
  end

  it 'validates all clauses, names and types even when no source rows exist' do
    invalid_queries = [
      'SUM(e.Salary)',
      'SELECT COUNT(*) RowsCount FROM Views.',
      'SELECT COUNT(*) RowsCount FROM Views.Employee GROUP',
      'SELECT d.Name Department FROM Views.Department d LEFT JOIN Views.Employee e',
      'SELECT d.Name Department FROM Views.Department d JOIN Views.Employee d ON TRUE',
      'SELECT d.Name Department FROM Views.Department d JOIN Views.Employee e ON',
      'SELECT d.Name Department FROM Views.Department d INNER OUTER JOIN Views.Employee e ON TRUE',
      'SELECT d.Name Department FROM Views.Department d CROSS JOIN Views.Employee e ON TRUE',
      'SELECT d.Name Department FROM d/Views.Employee_Department/Views.Employee e GROUP BY d.Name',
      'SELECT COUNT(*) RowsCount FROM Views.Employee e ORDER BY e.Name',
      'SELECT COUNT(*) RowsCount FROM (SELECT e.Name FROM Views.Employee e) t',
      'SELECT COUNT(*) RowsCount FROM Views.Employee e GROUP e.Name',
      'SELECT COUNT(*) RowsCount FROM Views.Employee e GROUP BY',
      'SELECT COUNT(*) FROM Views.Employee e',
      'SELECT SUM(*) RowsCount FROM Views.Employee e',
      'SELECT SUM(e.Name) RowsCount FROM Views.Employee e',
      'SELECT SUM(e.Unknown) RowsCount FROM Views.Employee e',
      'SELECT SUM(x.Salary) RowsCount FROM Views.Employee e',
      'SELECT e.Name Department, COUNT(*) RowsCount FROM Views.Employee e',
      'SELECT SUM(e.Salary + 1) RowsCount FROM Views.Employee e',
      'SELECT COUNT(*) RowsCount, FROM Views.Employee e',
      'SELECT d.Name Department, Name Employee FROM Views.Department d JOIN Views.Employee e ON TRUE',
      'SELECT d.Name Department, e.Name Employee FROM Views.Department d ' \
      'JOIN x/Views.Employee_Department/Views.Employee e',
      'SELECT d.Name Department, e.Name Employee FROM Views.Employee d ' \
      'JOIN d/Views.Employee_Department/Views.Employee e',
      'SELECT d.Name Department, e.Name Employee FROM Views.Department d JOIN Views.Employee e ON x.Name = e.Name',
      'SELECT d.Name Department, e.Name Employee FROM Views.Department d ' \
      'JOIN Views.Employee e ON d.Name = e.Name; DELETE',
      'SELECT COUNT(*) RowsCount FROM Views.Employee e UNION SELECT COUNT(*) RowsCount FROM Views.Employee e'
    ]
    invalid_queries.each do |query|
      set_query(query)
      expect { @store.retrieve('Views.ViewInnerPath') }.to raise_error(Mxrb::NativeRuntimeError), query
    end
    expect(@store.count('Views.Employee')).to eq(0)
  end

  it 'requires joined view references to project IDs of compatible entities' do
    seed
    base = 'SELECT d.Name Department, %s AS LinkedEmployee FROM Views.Department d ' \
           'LEFT JOIN d/Views.Employee_Department/Views.Employee e'
    ['e.Name', 'd.ID'].each do |reference|
      set_query(format(base, reference), name: 'LinkedEmployee')
      expect { @store.retrieve('Views.ViewLinkedEmployee') }
        .to raise_error(Mxrb::NativeRuntimeError, /unsupported view association/)
    end
    set_query(format(base, 'e.ID'), name: 'LinkedEmployee')
    records = @store.retrieve('Views.ViewLinkedEmployee')
    linked = records.find { _1.members['LinkedEmployee']&.members&.fetch('Name') == 'A' }
    expect(@store.retrieve_association('Views.LinkedEmployee', linked).first.members['Name']).to eq('A')
  end

  it 'does not confuse aggregate-like aliases or quoted keywords with clauses' do
    expect(Mxrb::Runtime::OqlRelationalQuery.relational?('FROM Views.Department SELECT Name AS Max')).to be(false)
    set_query('SELECT d.Name Department, e.Name Employee FROM Views.Department d JOIN Views.Employee e ' \
              "ON e.Name = 'JOIN GROUP SELECT' WHERE d.Name = 'WHERE FROM'")
    expect(@store.retrieve('Views.ViewInnerPath')).to be_empty
  end
end
# rubocop:enable Metrics/BlockLength
