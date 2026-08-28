# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'remaining branch contracts' do
  it 'exports every optional entity, attribute, association, and index option' do
    attribute = double(
      name: 'Status', type: nil, default_value: '', documentation: '', length: nil,
      localize_date: false, enumeration: 'App.Status', required: false, unique: true
    )
    association = double(
      to_entity_id: 'App.Target', association_type: :ReferenceSet, owner: :Default,
      name: 'Links', documentation: 'docs',
      parent_delete_behavior: :DeleteMeAndReferences,
      child_delete_behavior: :DeleteMeButKeepReferences
    )
    entity = double(
      name: 'Source', attributes: [attribute], persistable: true, documentation: '',
      generalization_target: nil, system_members: {}, access_rules: [], indexes: [
        { 'IndexedAttributes' => [3] },
        { 'IndexedAttributes' => [3, {
          'Attribute' => 'App.Source.Status', 'Ascending' => false
        }], 'IncludeInOffline' => true }
      ]
    )
    source = Mxrb::Exporter.new('input', Dir.pwd).send(
      :entity_source, entity, double(name: 'App', entities: []), [association]
    )
    expect(source).to include(
      'string :Status', 'localize_date: false', 'enumeration: "App.Status"',
      'unique: true', 'cardinality: :many_to_many', 'documentation: "docs"',
      'parent_delete: :DeleteMeAndReferences', 'ascending: [false]',
      'include_offline: true'
    )
  end

  it 'covers index advice rejection, high confidence, and non-redundant definitions' do
    advisor = Mxrb::Oql::IndexAdvisor.new
    query = ->(id, total) { double(query_id: id, total_time_ms: total) }
    evidence = {
      %w[orders status] => [query.call('q1', 100)],
      %w[customers name] => [query.call('q1', 2_000)],
      %w[orders owner] => [query.call('q1', 2_000), query.call('q2', 2_000), query.call('q3', 2_000)]
    }
    candidates = advisor.send(:candidates_for, evidence, %w[orders])
    expect(candidates.map(&:columns)).to eq([['owner']])
    expect(candidates.first.confidence).to eq(:high)
    expect(advisor.send(:index_signature, 'indexdef' => 'invalid')).to be_nil
    expect(advisor.send(:redundant_pair, [['a'], %w[first x]], [['a'], %w[second y]]))
      .to be_nil
  end

  it 'covers SQL Server workload rows below every threshold and zero denominators' do
    report = Mxrb::Oql::SqlServerWorkloadAnalyzer.new.analyze(
      query_rows: [{
        'query_hash' => 'zero', 'query_text' => 'SELECT 1', 'execution_count' => '0',
        'total_elapsed_time' => '0', 'total_rows' => '0',
        'total_logical_reads' => '0', 'total_physical_reads' => '0'
      }],
      table_rows: [
        { 'relation' => 'A', 'user_scans' => '1', 'user_seeks' => '2' },
        { 'relation' => 'B', 'user_scans' => '99', 'user_seeks' => '0' }
      ],
      index_rows: [
        { 'index_name' => 'Used', 'user_seeks' => '1', 'user_scans' => '0', 'index_bytes' => '9999999' },
        { 'index_name' => 'Small', 'user_seeks' => '0', 'user_scans' => '0', 'index_bytes' => '1' }
      ]
    )
    expect(report.queries.first).to have_attributes(mean_time_ms: 0.0, cache_hit_ratio: 1.0)
    expect(report.findings).to be_empty
  end

  it 'covers lower-case domain mutation document helpers' do
    entity = { '$ID' => 'entity', 'attributes' => [3] }
    Mxrb::Semantic::DomainMutator.put_attributes(entity, [{ '$ID' => 'attribute' }])
    expect(entity['attributes'][1]['$ID']).to eq('attribute')
    domain = { 'entities' => [3, entity] }
    replacement = entity.merge('name' => 'Updated')
    Mxrb::Semantic::DomainMutator.put_entity(domain, 'entity', replacement)
    expect(domain['entities'][1]['name']).to eq('Updated')
  end

  it 'covers entity nil generalization, non-hash generalization, and unknown validation targets' do
    base = {
      '$ID' => SecureRandom.uuid, 'Name' => 'Entity', 'Attributes' => [3],
      'ValidationRules' => [3, { 'Attribute' => 'App.Entity.Missing' }],
      'Indexes' => [3], 'AccessRules' => [3]
    }
    entity = Mxrb::Model::Entity.from_bson(base, nil, nil)
    expect(entity.persistable).to be(true)
    entity.generalization = 'invalid'
    expect(entity.generalization_target).to be_nil
  end

  it 'covers invalid builder documents, initializer paths, association behavior, and server params' do
    builder = Mxrb::Dsl::ModuleBuilder.new('App')
    expect do
      builder.native_document('Bad', type: 'X$Y', deep_structure: [])
    end.to raise_error(ArgumentError, /requires a Hash/)
    expect do
      Mxrb::Initializer.new('app', mxrb_path: '/missing/mxrb')
    end.to raise_error(ArgumentError, /does not exist/)
    association = Mxrb::Model::Association.new
    association.delete_behavior = 'invalid'
    expect(association.parent_delete_behavior).to eq(:NoAction)
    server = Mxrb::Oql::Server.allocate
    expect do
      server.send(:query_sql, 'sql' => 'SELECT 1', 'params' => [])
    end.to raise_error(ArgumentError, /JSON object/)
  end

  it 'covers zero-baseline deltas, qualified names, and writer graph/member branches' do
    delta = Mxrb::Oql::WorkloadBaseline.send(:delta, 'q', :mean, 0, 10)
    expect(delta.change_percent).to eq(100.0)
    index = Mxrb::Semantic::Index.allocate
    mod = double(name: 'App')
    entity = double(name: 'Entity', qualified_name: 'Qualified.Entity')
    expect(index.send(:qualified_entity_name, mod, entity)).to eq('Qualified.Entity')
    expect(index.send(:qualified_entity_name, mod, double(name: 'Fallback', qualified_name: '')))
      .to eq('App.Fallback')

    writer = Mxrb::Writer.new('x', version: '11.12.1', modules: [])
    ordered = writer.send(
      :ordered_flow_objects,
      [{ '$ID' => 'start', '$Type' => 'Microflows$StartEvent' }],
      [{ 'OriginPointer' => 'start', 'DestinationPointer' => 'missing' }]
    )
    expect(ordered.size).to eq(1)
    members = writer.send(
      :access_member_docs, :all, :all, 'App', 'Entity',
      attributes: ['Name'], associations: ['Entity_Link']
    )
    expect(members.find { !_1['Association'].empty? }['Attribute']).to eq('')
    previous = {
      '$ID' => 'association', 'deleteBehavior' => {
        '$ID' => 'behavior', '$Type' => 'DomainModels$DeleteBehavior'
      }
    }
    document = writer.send(
      :association_doc,
      { name: 'Link', type: :Reference, documentation: '' },
      from_id: SecureRandom.uuid, to_id: SecureRandom.uuid, previous:
    )
    expect(document).to have_key('deleteBehavior')
  end

  it 'covers doctor success, existing aggregator directories, and absent Java candidates' do
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'module.rb')
      FileUtils.mkdir_p(File.join(dir, 'entities'))
      File.write(file, 'evaluate_dir File.join(__dir__, "entities")')
      doctor = Mxrb::Doctor.new(dir, runner: ->(*_args) { raise Errno::ENOENT })
      expect(doctor.send(:missing_evaluate_dirs, file)).to be_empty
      allow(Dir).to receive(:[]).and_return([File.join(dir, 'valid.mpr')])
      allow(Mxrb).to receive(:validate).and_return(double(valid?: true, errors: []))
      expect(doctor.send(:mpr_check)).to have_attributes(status: :ok)
      allow(Dir).to receive(:glob).and_return([])
      stub_const('ENV', ENV.to_h.merge('JAVA_HOME' => ''))
      expect(doctor.send(:executable_check, 'java')).to have_attributes(status: :error)
    end
  end

  it 'covers functional settings errors and atomic cleanup failure branches' do
    settings = { '$Type' => 'Settings$ProjectSettings', 'Settings' => [2] }
    raw = { 'UnitID' => 'settings' }
    mpr = double(all_units: [raw])
    allow(mpr).to receive(:parse_contents).and_return(settings)
    allow(mpr).to receive(:close)
    allow(Mxrb::IO::MprFile).to receive(:open).and_return(mpr)
    instrumenter = Mxrb::Functional::Instrumenter.allocate
    instrumenter.instance_variable_set(:@path, 'model.mpr')
    expect { instrumenter.send(:select_after_startup!) }
      .to raise_error(Mxrb::FunctionalTestError, /model settings/)

    Dir.mktmpdir do |dir|
      credentials = Mxrb::OfficialMarketplace::Credentials.new(path: File.join(dir, 'credentials'))
      allow(File).to receive(:rename).and_raise(IOError, 'rename failed')
      expect { credentials.save_pat('pat') }.to raise_error(IOError, /rename failed/)
      expect(Dir[File.join(dir, '*.tmp-*')]).to be_empty
    end
  end

  it 'covers marketplace default config, lexical root rejection, and lock cleanup failure' do
    Dir.mktmpdir do |dir|
      allow(Dir).to receive(:home).and_return(dir)
      stub_const('ENV', ENV.to_h.merge('XDG_CONFIG_HOME' => ''))
      credentials = Mxrb::OfficialMarketplace::Credentials.new
      expect(credentials.save_pat('pat')).to eq(File.join(dir, '.config', 'mxrb', 'credentials'))

      installer = Mxrb::OfficialMarketplace::Installer.new(target: dir)
      expect { installer.send(:safe_destination, '', dir) }
        .to raise_error(Mxrb::MarketplaceError, /unsafe/)
      lock_path = File.join(dir, 'lock.json')
      allow(File).to receive(:rename).and_raise(IOError, 'rename failed')
      expect { installer.send(:write_lock_atomically, lock_path, 'packages' => {}) }
        .to raise_error(IOError, /rename failed/)
      expect(File).not_to exist("#{lock_path}.tmp-#{Process.pid}")
    end
  end

  it 'covers quiet CLI output and a migration with no previous output variable' do
    Dir.mktmpdir do |dir|
      root = Mxrb::Initializer.new('quiet_app').scaffold(into: dir).root
      output = StringIO.new
      Mxrb::Scaffold::CLI.new(
        'evaluation', ['new', 'architecture', '--target', root], output:
      ).run
      expect(output.string).not_to include('Done. Run:')
      preview = StringIO.new
      Mxrb::Scaffold::CLI.new(
        'entity', ['new', 'QuietApp.Preview', '--target', root, '--dry-run'], output: preview
      ).run
      expect(preview.string).to include('would create')

      ENV.delete('MXRB_OUTPUT_PATH')
      load File.join(root, 'project.rb')
      expect(Mxrb::ProjectLifecycle.new(root).migration_plan.current).to end_with('QuietApp.mpr')
      expect(ENV).not_to have_key('MXRB_OUTPUT_PATH')
    end
  end

  it 'cleans registry staging files when its atomic rename fails' do
    Dir.mktmpdir do |dir|
      registry = Mxrb::Scaffold::Registry.new(dir)
      allow(File).to receive(:rename).and_raise(IOError, 'rename failed')
      expect { registry.send(:write, 'scaffolds' => {}) }
        .to raise_error(IOError, /rename failed/)
      expect(File).not_to exist(File.join(dir, '.mxrb', "scaffolds.json.tmp-#{Process.pid}"))
    end
  end
end
# rubocop:enable Metrics/BlockLength
