# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::SourceIdentity do
  around do |example|
    Dir.mktmpdir('mxrb-source-order-') do |directory|
      @directory = directory
      example.run
    end
  end

  after { Mxrb::RubyApp::Registry.reset! }

  def entry(name = 'Existing', id: '11111111-1111-4111-8111-111111111111')
    { 'name' => "App.#{name}", 'ruby_class' => "App::#{name}", 'id' => id,
      'path' => 'app/models/app/existing.rb' }
  end

  def context(entries = [entry])
    manifest = Mxrb::RubyApp::Manifest.new(
      @directory, 'mode' => 'ruby', 'modules' => [{ 'name' => 'App', 'models' => entries }]
    )
    described_class.new(manifest)
  end

  def owner(name, ruby_class: "App::#{name}")
    double(name: ruby_class, mendix_name: "App.#{name}", mendix_id: '', resolve_record_identities!: nil)
  end

  def bundle_entry(**overrides)
    {
      'kind' => 'record', 'id' => '11111111-1111-4111-8111-111111111111',
      'name' => 'App.Existing', 'path' => 'app/models/app/existing.rb',
      'ruby_class' => 'App::Existing', 'native_kind' => ''
    }.merge(overrides)
  end

  def bundle_file(payload, checksum: nil)
    contents = payload.is_a?(String) ? payload : JSON.generate(payload)
    {
      path: described_class::BUNDLE_PATH, contents:,
      sha256: checksum || Digest::SHA256.hexdigest(contents)
    }
  end

  # rubocop:disable Metrics/ParameterLists
  def bind(resolver, declaration, path: entry.fetch('path'), id: nil, kind: 'record', renamed_from: nil)
    resolver.load_file(File.join(@directory, path)) do
      resolver.resolve(declaration, kind, declaration.mendix_name, id:, renamed_from:)
    end
  end
  # rubocop:enable Metrics/ParameterLists

  [%w[Added Existing], %w[Existing Added]].each do |order|
    it "resolves #{order.join(' then ')} without transferring an existing identity" do
      resolver = context
      resolved = order.to_h { |name| [name, bind(resolver, owner(name))] }

      expect(resolved).to eq('Added' => '', 'Existing' => entry.fetch('id'))
      expect(resolver.finalize!).to equal(resolver)
    end
  end

  it 'allows new declarations before an existing class that moves to a later file' do
    resolver = context
    expect(bind(resolver, owner('Added'))).to eq('')
    expect(bind(resolver, owner('Existing'), path: 'app/models/app/z_moved.rb')).to eq(entry.fetch('id'))
    expect(resolver.finalize!).to equal(resolver)
  end

  it 'recognizes matched legacy entries even when their native identity is empty' do
    resolver = context([entry(id: '')])
    expect(bind(resolver, owner('Added'))).to eq('')
    expect(bind(resolver, owner('Existing'))).to eq('')
    expect(resolver.finalize!).to equal(resolver)
  end

  it 'reserves every identity in a shared file independently of declaration order' do
    other = entry('Other', id: '22222222-2222-4222-8222-222222222222')
    resolver = context([entry, other])
    resolved = %w[Added Other Existing].to_h { |name| [name, bind(resolver, owner(name))] }

    expect(resolved).to eq('Added' => '', 'Other' => other.fetch('id'), 'Existing' => entry.fetch('id'))
    expect(resolver.finalize!).to equal(resolver)
  end

  it 'still rejects unmatched replacements instead of guessing a rename by position' do
    resolver = context
    expect(bind(resolver, owner('Changed'))).to eq('')

    expect { resolver.finalize! }
      .to raise_error(Mxrb::ValidationError, /cannot distinguish a new declaration from a rename/)
  end

  it 'binds an explicit entity rename to its existing private identity' do
    resolver = context
    renamed = owner('Renamed')

    expect(bind(resolver, renamed, renamed_from: 'App.Existing')).to eq(entry.fetch('id'))
    expect(resolver.finalize!).to equal(resolver)
    expect { resolver.validate_entity_names! }.not_to raise_error
  end

  it 'does not let one resolved declaration hide another unclaimed identity' do
    other = entry('Other', id: '22222222-2222-4222-8222-222222222222')
    resolver = context([entry, other])
    expect(bind(resolver, owner('Added'))).to eq('')
    expect(bind(resolver, owner('Existing'))).to eq(entry.fetch('id'))

    expect { resolver.finalize! }.to raise_error(Mxrb::ValidationError, /cannot distinguish/)
  end

  it 'keeps explicit legacy IDs and rejects duplicate claims immediately' do
    resolver = context
    expect(bind(resolver, owner('Existing', ruby_class: 'App::RenamedClass'), id: entry.fetch('id')))
      .to eq(entry.fetch('id'))
    expect { bind(resolver, owner('Impostor'), id: entry.fetch('id')) }
      .to raise_error(Mxrb::ValidationError, /claim the same record identity/)
  end

  it 'still rejects changing the family of an existing Ruby class' do
    resolver = context

    expect { bind(resolver, owner('Existing'), kind: 'page') }
      .to raise_error(Mxrb::ValidationError, /cannot change document family/)
  end

  it 'validates every integrity boundary of the private identity sidecar' do
    valid = { 'format_version' => 1, 'entries' => [bundle_entry] }
    expect(described_class.read_bundle([bundle_file(valid)])).to eq([bundle_entry])
    expect { described_class.read_bundle([bundle_file(valid, checksum: 'bad')]) }
      .to raise_error(Mxrb::SerializationError, /checksum mismatch/)
    expect { described_class.read_bundle([bundle_file('{')]) }
      .to raise_error(Mxrb::SerializationError, /invalid Ruby source identity sidecar:/)
    expect { described_class.read_bundle([bundle_file({ 'format_version' => 2, 'entries' => [] })]) }
      .to raise_error(Mxrb::SerializationError, /invalid Ruby source identity sidecar format/)
    expect { described_class.read_bundle([bundle_file({ 'format_version' => 1, 'entries' => [{}] })]) }
      .to raise_error(Mxrb::SerializationError, /invalid Ruby source identity entry/)
    unsafe = bundle_entry('path' => 'app/models/app/../other.rb')
    expect { described_class.read_bundle([bundle_file({ 'format_version' => 1, 'entries' => [unsafe] })]) }
      .to raise_error(Mxrb::SerializationError, /unsafe Ruby source identity path/)
    invalid_service = bundle_entry('kind' => 'service', 'native_kind' => 'future')
    expect do
      described_class.read_bundle([bundle_file({ 'format_version' => 1, 'entries' => [invalid_service] })])
    end
      .to raise_error(Mxrb::SerializationError, /invalid Ruby service identity kind/)
  end

  it 'rejects incomplete enumeration identity baselines and duplicate names' do
    manifest = Mxrb::RubyApp::Manifest.new(
      @directory, 'mode' => 'ruby', 'modules' => [{
        'name' => 'App', 'enumerations' => [entry('Status').merge('values' => nil)]
      }]
    )
    expect { described_class.new(manifest) }
      .to raise_error(Mxrb::ValidationError, /enumeration requires its member identity baseline/)

    resolver = context
    bind(resolver, owner('Existing'))
    expect { bind(resolver, owner('Existing', ruby_class: 'App::Duplicate')) }
      .to raise_error(Mxrb::ValidationError, /duplicate Ruby record declaration/)
  end

  it 'prevents flow-kind changes, implicit entity renames, and conflicting explicit renames' do
    service_entry = entry('Run').merge(
      'ruby_class' => 'App::Run', 'native_kind' => 'microflow', 'path' => 'app/services/app/run.rb'
    )
    manifest = Mxrb::RubyApp::Manifest.new(
      @directory, 'mode' => 'ruby', 'modules' => [{ 'name' => 'App', 'services' => [service_entry] }]
    )
    resolver = described_class.new(manifest)
    service = owner('Run')
    bind(resolver, service, path: service_entry.fetch('path'), kind: 'service')
    expect { resolver.validate_flow!(service, 'nanoflow') }
      .to raise_error(Mxrb::ValidationError, /cannot change between microflow and nanoflow/)

    resolver = context
    renamed = owner('Renamed')
    bind(resolver, renamed, id: entry.fetch('id'))
    expect { resolver.validate_entity_names! }
      .to raise_error(Mxrb::ValidationError, /requires an explicit semantic rename/)
    expect { bind(context, owner('Renamed'), renamed_from: 'App.Existing', id: 'different') }
      .to raise_error(Mxrb::ValidationError, /conflicts with renamed_from/)
    expect { bind(context, owner('Existing', ruby_class: 'App::Moved'), path: 'app/models/app/moved.rb') }
      .to raise_error(Mxrb::ValidationError, /cannot resolve moved Ruby declaration/)
  end

  it 'fails when an existing materialized identity disappears or changes' do
    empty_module = Struct.new(
      :name, :entities, :pages, :microflows, :nanoflows, :constants, :enumerations,
      :scheduled_events, :module_security_id, :domain_documents
    ).new('App', [], [], [], [], [], [], [], '', [])
    project = Struct.new(:modules).new([empty_module])

    missing = context
    bind(missing, owner('Existing'))
    expect { missing.reconcile!(project) }
      .to raise_error(Mxrb::ValidationError, /missing materialized Ruby identity/)

    changed = context
    bind(changed, owner('Existing'))
    empty_module.entities = [Struct.new(:name, :id).new('Existing', 'changed-id')]
    expect { changed.reconcile!(project) }
      .to raise_error(Mxrb::ValidationError, /materialized Ruby identity changed/)
  end

  it 'clears unmatched new identities and rejects ambiguous materialized records' do
    module_type = Struct.new(
      :name, :entities, :pages, :microflows, :nanoflows, :constants, :enumerations,
      :scheduled_events, :module_security_id, :domain_documents
    )
    record_type = Struct.new(:name, :id)
    project_type = Struct.new(:modules)

    resolver = context([])
    added = owner('Added')
    bind(resolver, added)
    empty = module_type.new('App', [], [], [], [], [], [], [], '', [])
    expect(resolver.reconcile!(project_type.new([empty]))).to equal(resolver)
    expect(resolver.bundle.fetch(:contents)).not_to include('App.Added')

    ambiguous = context([])
    duplicate = owner('Added')
    bind(ambiguous, duplicate)
    mod = module_type.new('App', [record_type.new('Added', ''), record_type.new('Added', '')],
                          [], [], [], [], [], [], '', [])
    expect { ambiguous.reconcile!(project_type.new([mod])) }
      .to raise_error(Mxrb::ValidationError, /ambiguous materialized Ruby identity/)
  end

  it 'compiles and reexports a new model before an existing one with both identities preserved' do
    source = File.join(@directory, 'Source.mpr')
    root = File.join(@directory, 'ruby')
    Mxrb.define(source) do
      mendix_version '11.12.1'
      self.module(:App) { entity(:Existing) { string :Title } }
    end
    original = Mxrb.open(source) { _1.modules.find { |mod| mod.name == 'App' }.entities.first.id }
    Mxrb::Exporter.new(source, root, mode: :ruby).export!
    manifest = Mxrb::RubyApp::Manifest.load(root)
    model = manifest.modules.find { _1.fetch('name') == 'App' }.fetch('models').first
    path = File.join(root, model.fetch('path'))
    existing_source = File.read(path)
    added_source = <<~RUBY
      module App
        class Added < Mxrb::RubyApp::Record
          mendix_name 'App.Added'
          attribute :title, type: :string, mendix_name: 'Title'
        end
      end
    RUBY
    expect(existing_source).to include("module App\n")
    edited_source = existing_source.sub("module App\n", "#{added_source}module App\n")
    File.write(path, edited_source)

    rebuilt = Mxrb::RubyApp.compile(root, File.join(@directory, 'Compiled.mpr'))
    identities = model_identities(rebuilt)
    expect(identities.fetch('Existing')).to eq(original)
    expect(identities.keys).to contain_exactly('Existing', 'Added')
    expect(identities.fetch('Added')).not_to eq(original)
    expect(identities.fetch('Added')).not_to be_empty

    restored = File.join(@directory, 'restored')
    Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
    restored_module = Mxrb::RubyApp::Manifest.load(restored).modules.find { _1.fetch('name') == 'App' }
    restored_models = restored_module.fetch('models')
    expect(restored_models.map { _1.fetch('path') }.uniq).to eq([model.fetch('path')])
    expect(File.read(File.join(restored, model.fetch('path')))).to eq(edited_source)
    final_mpr = Mxrb::RubyApp.compile(restored, File.join(@directory, 'Restored.mpr'))
    expect(model_identities(final_mpr)).to eq(identities)
  end

  def model_identities(path)
    Mxrb.open(path) do |project|
      project.modules.find { _1.name == 'App' }.entities.to_h { [_1.name, _1.id] }
    end
  end
end
# rubocop:enable Metrics/BlockLength
