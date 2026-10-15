# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'OQL parameters through the Marketplace OQL module' do
  let(:fixture) { 'spec/fixtures/native_oql_parameters' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Parameters.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load File.join(fixture, 'project.rb')
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      Mxrb::RubyApp::KnownOqlModuleActions.reset!
      Mxrb::RubyApp::Registry.reset!
    end
  end

  # Placeholder sources stand in for the audited module files of a real project.
  def select_test_adapters
    source = "// explicitly selected test adapter\n"
    hash = Digest::SHA256.hexdigest(source)
    names = Mxrb::RubyApp::KnownOqlModuleActions::RELEASES.fetch('4.1.2').fetch(:actions).keys
    files = names.map { "actions/#{_1}.java" } + ['implementation/OQL.java']
    files.each { write_source(File.join(@directory, 'javasource', 'oql', _1), source) }
    stub_const('Mxrb::RubyApp::KnownOqlModuleActions::RELEASES',
               '4.1.2' => { implementation: hash, actions: names.to_h { [_1, hash] } })
  end

  def write_source(path, source)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  def application
    select_test_adapters
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: { 'MXRB_DATABASE_PATH' => ':memory:' })
  end

  it 'matches the native Mendix 11.12.1 results from editable Ruby with MPR access prohibited' do
    app = application
    expect(app.call_service('Views.RunAll')).to be(true)
    logged = app.send(:bridge).interpreter.instance_variable_get(:@log).to_h do |line|
      line.delete_prefix('ORACLE ').split('=', 2)
    end
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  context 'with the store' do
    before do
      @project = Mxrb.open(@source)
      @store = Mxrb::Runtime::SQLiteStore.new(@project)
      Mxrb::Runtime::Native::Interpreter.new(@project, store: @store).call('Views.Seed')
    end

    after do
      @store.close
      @project.close
    end

    let(:north) { @store.retrieve('Views.Building').find { _1.members['Name'] == 'North' } }

    def names(statement, **options)
      @store.oql_module_objects(statement, 'Views.Result', **options).map { _1.members['Name'] }
    end

    it 'binds every parameter type and maps object IDs to owned associations' do
      identifier = Mxrb::Runtime::OqlParameters::Identifier.new(north.id)
      result = @store.oql_module_objects('Views.ByBuilding', 'Views.Result',
                                         parameters: { 'BuildingID' => identifier, 'Status' => 'Active' })
      expect(result.map { _1.members['Result_Building']&.id }.uniq).to eq([north.id])
      long = 'SELECT p.Name AS Name FROM Views.Program AS p WHERE p.Rank < $Big AND p.Amount < $Float ' \
             'AND p.Name != $Text AND p.Flag = $Flag'
      expect(names(long, parameters: { 'Big' => 2**40, 'Float' => 3.0, 'Text' => 'x', 'Flag' => true }))
        .to eq(%w[Alpha])
      expect(names('SELECT p.Name AS Name FROM Views.Program AS p WHERE p.Due < $When',
                   parameters: { 'When' => Time.utc(2024, 1, 1) })).to eq(%w[gamma])
      expect(names('SELECT p.Name AS Name, p.Name AS submetaobjectname FROM Views.Program AS p ' \
                   'WHERE p.Rank = $R', parameters: { 'R' => 1 }, amount: 1)).to eq(%w[Alpha])
      nobody = 'SELECT p.Name AS Name, b.ID AS Result_Building FROM Views.Program AS p ' \
               'LEFT JOIN p/Views.Program_Building/Views.Building AS b WHERE p.Rank = 1'
      expect(@store.oql_module_objects(nobody, 'Views.Result', parameters: {}).map { _1.members['Result_Building'] })
        .to include(nil)
      expect(@store.oql_module_count('SELECT p.Name AS Name FROM Views.Program AS p', parameters: {})).to eq(5)
    end

    it 'maps rows like release 2.10.0: text only, every column, unqualified associations' do
      legacy = ->(statement) { @store.oql_module_objects(statement, 'Views.Result', parameters: {}, release: '2.10.0') }
      linked = 'SELECT p.Name AS Name, b.ID AS Result_Building FROM Views.Program AS p ' \
               'JOIN p/Views.Program_Building/Views.Building AS b WHERE p.Rank = 1'
      expect(legacy.call(linked).map { _1.members['Result_Building']&.id }).to eq([north.id])
      expect { legacy.call('Views.ByBuilding') }.to raise_error(Mxrb::NativeRuntimeError)
      expect { legacy.call('SELECT p.Name AS Name, p.Name AS submetaobjectname FROM Views.Program AS p') }
        .to raise_error(Mxrb::Runtime::JavaActionError,
                        'Could not find result attribute submetaobjectname in target object.')
      nothing = 'SELECT p.Name AS Name, p.Amount AS Other FROM Views.Program AS p WHERE p.Amount IS NULL'
      [[nil, 'java.lang.RuntimeException',
        'Unable to map null value for column Other to any association or attribute.'],
       ['2.10.0', 'java.lang.NullPointerException',
        'Null value found Other was not found as association or attribute.']]
        .each do |release, java_class, message|
          options = { parameters: {}, release: }.compact
          expect { @store.oql_module_objects(nothing, 'Views.Result', **options) }
            .to raise_error(Mxrb::Runtime::JavaActionError) { |error| expect([error.java_class, error.message]).to eq([java_class, message]) }
        end
      # OQL aliases cannot hold a dot, but the module matches a qualified column exactly since 3.x.
      current = Mxrb::Runtime::OqlModuleQuery.new(@store.send(:oql_queries), @store)
      old = Mxrb::Runtime::OqlModuleQuery.new(@store.send(:oql_queries), @store, release: '2.10.0')
      expect(current.send(:association, 'Views.Result', 'Views.Result_Building')&.name).to eq('Result_Building')
      expect(old.send(:association, 'Views.Result', 'Views.Result_Building')).to be_nil
    end

    it 'rejects unset parameters, unknown values and columns without a target' do
      {
        'SELECT p.Name AS Name FROM Views.Program AS p WHERE p.Rank = $Missing' => {},
        'SELECT p.Name AS Name FROM Views.Program AS p WHERE p.Rank = $Odd' => { 'Odd' => Object.new },
        'SELECT p.Name AS Name, p.Rank AS Unknown FROM Views.Program AS p' => {},
        'SELECT p.Name AS Name, p.ID AS Other FROM Views.Program AS p' => {},
        'SELECT p.Name AS Name, ar.Name AS AreaName FROM Views.Program AS p ' \
        'RIGHT JOIN p/Views.Program_Asset/Views.Asset/Views.Asset_Area/Views.Area AS ar' => {}
      }.each do |statement, parameters|
        expect { names(statement, parameters:) }.to raise_error(Mxrb::NativeRuntimeError), statement
      end
      query = 'SELECT p.Name AS Name FROM Views.Program AS p'
      expect { @store.oql_module_objects(query, 'Views.Missing', parameters: {}) }
        .to raise_error(Mxrb::NativeRuntimeError, /unknown result entity/)
    end
  end
end

RSpec.describe Mxrb::RubyApp::KnownOqlModuleActions do
  after { described_class.reset! }

  it 'registers only audited actions and keeps parameters per thread' do
    Dir.mktmpdir { expect(described_class.registrations(_1)).to eq('') }
    Dir.mktmpdir do |directory|
      root = File.join(directory, 'javasource', 'oql')
      FileUtils.mkdir_p(File.join(root, 'implementation'))
      FileUtils.mkdir_p(File.join(root, 'actions'))
      File.write(File.join(root, 'implementation', 'OQL.java'), 'x')
      File.write(File.join(root, 'actions', 'AddStringParameter.java'), 'x')
      x = Digest::SHA256.hexdigest('x')
      stub_const("#{described_class}::RELEASES",
                 '4.1.2' => { implementation: 'other', actions: {} },
                 '2.10.0' => { implementation: x, actions: { 'AddStringParameter' => x, 'ExecuteOQLStatement' => x } })
      expect(described_class.registrations(directory))
        .to eq('Mxrb::RubyApp::KnownOqlModuleActions.register("AddStringParameter", "2.10.0")')
      expect { described_class.register('CountRowsOQLStatement', '2.10.0') }.to raise_error(KeyError, /not audited/)
    end
    described_class.add('name' => 'A', 'value' => nil)
    expect(described_class.parameters).to eq('A' => nil)
    expect(Thread.new { described_class.parameters }.value).to eq({})
  end
end
# rubocop:enable Metrics/BlockLength
