# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/sync'
require 'mxrb/studio/model_operations'
require 'mxrb/studio/documents'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::Sync do
  around do |example|
    Dir.mktmpdir('mxrb-sync-spec-') do |directory|
      @directory = directory
      original = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'xdg')
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = original
    end
  end

  let(:model) { create_model(format: @format || :v1) }
  let(:ruby) { export(model) }
  let(:sync) { described_class.new(model, ruby_root: ruby, state_root: File.join(@directory, 'state')) }

  def create_model(format: :v1)
    path = File.join(@directory, 'app', 'Shop.mpr')
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) do
        entity(:Product) do
          string :Name
          integer :Stock
        end
        entity(:Order) { decimal :Total }
        microflow(:Recalculate) { return_value 'empty' }
      end
    end
    Mxrb.open(path, readonly: false) { _1.mpr.migrate_storage_format!(:v2) } if format == :v2
    path
  end

  def export(path)
    destination = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(path, destination, mode: :mendix).export!(parallel: false)
    destination
  end

  def ruby_file(relative) = File.join(ruby, relative)
  def product_file = ruby_file('modules/Shop/domain/entities/product.rb')
  def order_file = ruby_file('modules/Shop/domain/entities/order.rb')

  def edit(path)
    File.write(path, yield(File.read(path)))
  end

  def attributes(entity)
    Mxrb.open(model) { |project| project.entities.find { _1.name == entity }.attributes.to_h { [_1.name, _1] } }
  end

  def mendix_operation(operation)
    editor = Mxrb::Studio::ModelOperations.new(model, workspace_root: @directory)
    editor.apply(operation, revision: editor.revision)
  end

  def native_bytes(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
    mpr.all_units.to_h { [_1.fetch('UnitID'), mpr.content_bytes(_1)] }
  ensure
    mpr&.close
  end

  it 'reports an unlinked project and refuses to synchronize it' do
    expect(sync.status).to include(linked: false, state: 'unlinked')
    expect { sync.run }.to raise_error(ArgumentError, /not linked/)
    expect do
      described_class.new(model, ruby_root: @directory, state_root: File.join(@directory, 'state'))
    end.to raise_error(ArgumentError, /project\.rb/)
  end

  it 'links without changing Ruby sources and refreshes only the MXRB-owned metadata' do
    stale = ruby_file('.mxrb/obsolete.json')
    File.write(stale, '{}')
    native = ruby_file('.mxrb/native_units.json')
    expected = File.binread(native)
    File.write(native, '{}')
    before = File.read(product_file)
    status = sync.link!
    expect(status).to include(linked: true, state: 'synced', ruby_changes: [], mendix_changes: [], conflicts: [],
                              diverged: [])
    expect(File).not_to exist(stale)
    expect(File.binread(native)).to eq(expected)
    expect(File.read(product_file)).to eq(before)
    expect(sync).to be_linked
    expect(sync.unlink!).to eq(linked: false)
    expect(sync).not_to be_linked
  end

  %i[v1 v2].each do |format|
    it "applies Ruby edits element by element with #{format} storage, journaled for undo" do
      @format = format
      sync.link!
      before = native_bytes(model)
      edit(product_file) do
        _1.sub("integer :Stock\n", "integer :Stock\n  # kept\n  boolean :Active, default: \"true\"\n")
      end
      status = sync.status
      expect(status[:state]).to eq('pending')
      expect(status[:ruby_changes]).to contain_exactly(
        include(path: 'modules/Shop/domain/entities/product.rb', action: 'modified', diagnostics: [],
                artifacts: [include(kind: 'entity', name: 'Product', qualified_name: 'Shop.Product')])
      )
      ids = Mxrb.open(model) { |project| project.entities.to_h { [_1.name, _1.id] } }
      result = sync.run
      expect(result).to include(applied: true, state: 'synced', conflicts: [], mendix_units: [], files: [])
      expect(result[:ruby_units].size).to eq(1)
      expect(attributes('Product').keys).to eq(%w[Name Stock Active])
      expect(Mxrb.open(model) { |project| project.entities.to_h { [_1.name, _1.id] } }).to eq(ids)
      expect(File.read(product_file)).to include('# kept')
      expect(sync.status[:state]).to eq('synced')
      Mxrb::Studio::History.new(model, state_root: File.join(@directory, 'state')).undo
      expect(native_bytes(model)).to eq(before)
    end
  end

  it 'merges Mendix edits into Ruby text and keeps comments and unrelated code' do
    sync.link!
    edit(order_file) { _1.sub("decimal :Total\n", "decimal :Total # the order total\n") }
    sync.run
    mendix_operation('operation' => 'add_attribute', 'target' => 'Shop.Order', 'name' => 'Note', 'type' => 'string')
    status = sync.status
    expect(status[:mendix_changes]).to contain_exactly(include(action: 'modified', type: 'DomainModels$DomainModel'))
    result = sync.run
    expect(result[:files].map { _1[:path] }).to include('modules/Shop/domain/entities/order.rb')
    text = File.read(order_file)
    expect(text).to include('decimal :Total # the order total', 'string :Note')
    expect(sync.status[:state]).to eq('synced')
    backups = Dir.glob(File.join(sync.state_directory, 'backups', '*', '**', 'order.rb'))
    expect(backups).not_to be_empty
  end

  it 'synchronizes independent edits of the same document in both directions' do
    sync.link!
    edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
    mendix_operation('operation' => 'add_attribute', 'target' => 'Shop.Order', 'name' => 'Note', 'type' => 'string')
    result = sync.run
    expect(result).to include(applied: true, conflicts: [])
    expect(attributes('Product').keys).to eq(%w[Name Stock Active])
    expect(attributes('Order').keys).to eq(%w[Total Note])
    expect(File.read(order_file)).to include('string :Note')
    expect(sync.status[:state]).to eq('synced')
  end

  it 'stops on a conflict, preserves both versions and applies the chosen resolution' do
    sync.link!
    edit(product_file) { _1.sub('string :Name, length: 200', 'string :Name, length: 100') }
    mendix_operation('operation' => 'change_attribute', 'target' => 'Shop.Product/Name', 'length' => 50)
    ruby_text = File.read(product_file)
    before = native_bytes(model)
    result = sync.run
    expect(result).to include(applied: false, state: 'conflict')
    element = result[:conflicts].find { _1[:kind] == 'element' }
    expect(element).to include(unit_id: be_a(String), ruby_operation: 'set', mendix_operation: 'set',
                               resolutions: %w[ruby mendix])
    expect(element[:element]).to include(type: 'DomainModels$StringAttributeType')
    expect([element[:base], element[:mendix], element[:ruby]].map { _1[:value] }).to eq([200, 50, 100])
    file = result[:conflicts].find { _1[:kind] == 'file' }
    expect(file).to include(path: 'modules/Shop/domain/entities/product.rb', hunks: 1)
    expect(native_bytes(model)).to eq(before)
    expect(File.read(product_file)).to eq(ruby_text)
    expect(sync.status).to include(state: 'conflict', conflicts: result[:conflicts])
    expect(sync.run(dry_run: true)).to include(applied: false, dry_run: true)

    resolved = sync.run(resolutions: { element[:id] => 'ruby', file[:id] => 'ruby' })
    expect(resolved).to include(applied: true, state: 'synced')
    expect(attributes('Product')['Name'].length).to eq(100)
    expect(File.read(product_file)).to include('length: 100')
    expect(sync.status[:state]).to eq('synced')
  end

  it 'keeps the Mendix value when the conflict is resolved for Mendix' do
    sync.link!
    edit(product_file) { _1.sub('string :Name, length: 200', 'string :Name, length: 100') }
    mendix_operation('operation' => 'change_attribute', 'target' => 'Shop.Product/Name', 'length' => 50)
    conflicts = sync.run[:conflicts]
    resolved = sync.run(resolutions: conflicts.to_h { [_1[:id], 'mendix'] })
    expect(resolved).to include(applied: true, history: nil)
    expect(attributes('Product')['Name'].length).to eq(50)
    expect(File.read(product_file)).to include('length: 50')
    expect(File.read(product_file)).not_to include('<<<<<<<')
  end

  it 'leaves the model untouched and locates Ruby that does not parse or evaluate' do
    sync.link!
    before = native_bytes(model)
    edit(product_file) { _1.sub('integer :Stock', 'integer :Stock,') }
    status = sync.status
    expect(status[:state]).to eq('conversion_error')
    expect(status[:ruby_changes].first[:diagnostics].first).to include(
      file: 'modules/Shop/domain/entities/product.rb', severity: 'error', line: 6
    )
    expect { sync.run }.to raise_error(Mxrb::Studio::RubySourceError) { expect(_1.locations).not_to be_empty }

    edit(product_file) { _1.sub('integer :Stock,', 'integer :Stock') }
    edit(order_file) { _1.sub("decimal :Total\n", "decimal :Total\n  undefined_dsl_helper!\n") }
    expect { sync.run }.to raise_error(Mxrb::Studio::Protocol::Failure) do |error|
      expect(error.code).to eq(Mxrb::Studio::Protocol::RUBY_SOURCE)
      expect(error.data[:locations]).to include(include(file: order_file, line: 5))
    end
    expect(native_bytes(model)).to eq(before)
  end

  it 'rejects a project.rb that defines no model and resolutions that are not ruby or mendix' do
    sync.link!
    File.write(File.join(ruby, 'project.rb'), "# frozen_string_literal: true\n")
    expect { sync.run }.to raise_error(Mxrb::Studio::Protocol::Failure, /did not generate a model/)
    expect { sync.run(resolutions: { 'x' => 'both' }) }.to raise_error(ArgumentError, /ruby or mendix/)
    expect { sync.run(resolutions: []) }.to raise_error(ArgumentError, /object/)
  end

  it 'refuses to write when the model changes during synchronization' do
    sync.link!
    edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
    allow(sync).to receive(:model_revision).and_return('before', 'after')
    expect { sync.run }.to raise_error(Mxrb::Studio::Conflict, /changed during synchronization/)
  end

  it 'adds and removes whole documents from Ruby and reports removal conflicts' do
    sync.link!
    flow = Dir.glob(ruby_file('modules/Shop/application/**/recalculate.rb')).first
    application = ruby_file('modules/Shop/application/application.rb')
    edit(application) { _1.lines.reject { |line| line.include?('recalculate.rb') }.join }
    FileUtils.rm_f(flow)
    expect(sync.run).to include(applied: true)
    expect(Mxrb.open(model) { |project| project.microflows.map(&:name) }).not_to include('Recalculate')

    File.write(flow, "microflow :Recalculate do\n  return_value 'empty'\nend\n")
    edit(application) do
      "#{_1}evaluate File.join(__dir__, #{flow.delete_prefix("#{File.dirname(application)}/").inspect})\n"
    end
    expect(sync.run).to include(applied: true)
    expect(Mxrb.open(model) { |project| project.microflows.map(&:name) }).to include('Recalculate')
  end

  def unit_id_of(type, name = nil)
    mpr = Mxrb::IO::MprFile.open(model, readonly: true, apply_studio_compatibility: false)
    mpr.all_units.find do |unit|
      document = mpr.parse_contents(unit)
      document['$Type'] == type && (name.nil? || document['Name'] == name)
    end.fetch('UnitID')
  ensure
    mpr&.close
  end

  def write_model
    mpr = Mxrb::IO::MprFile.open(model, readonly: false, apply_studio_compatibility: false)
    yield mpr
  ensure
    mpr&.close
  end

  def patch_document(type, name, changes)
    documents = Mxrb::Studio::Documents.new(model)
    id = unit_id_of(type, name)
    documents.patch(id, revision: documents.read(id).fetch(:revision), changes:)
  end

  def flow_file = Dir.glob(ruby_file('modules/Shop/application/**/recalculate.rb')).first

  it 'regenerates a missing generated base lazily and ignores pure reserialization' do
    sync.link!
    mendix_operation('operation' => 'add_attribute', 'target' => 'Shop.Order', 'name' => 'Note', 'type' => 'string')
    sync.run
    expect(JSON.parse(File.read(File.join(sync.state_directory, 'link.json')))).not_to have_key('generated_model')
    edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
    expect(sync.run).to include(applied: true, conflicts: [])
    expect(attributes('Product').keys).to eq(%w[Name Stock Active])

    id = unit_id_of('DomainModels$DomainModel')
    write_model do |mpr|
      document = mpr.parse_contents(mpr.unit(id))
      reordered = document.slice('$ID', '$Type').merge(document.except('$ID', '$Type').to_a.reverse.to_h)
      mpr.update_unit_bytes(id, Mxrb::IO::BsonCodec.serialize(reordered))
    end
    expect(sync.status).to include(state: 'synced', mendix_changes: [])
  end

  it 'reports a removal conflict when Ruby deletes a document that Mendix changed' do
    sync.link!
    patch_document('Microflows$Microflow', 'Recalculate', { '/Documentation' => 'changed in Studio Pro' })
    application = ruby_file('modules/Shop/application/application.rb')
    edit(application) { _1.lines.reject { |line| line.include?('recalculate.rb') }.join }
    FileUtils.rm_f(flow_file)
    result = sync.run
    unit = result[:conflicts].find { _1[:kind] == 'unit' }
    expect(unit).to include(type: 'Microflows$Microflow', name: 'Recalculate',
                            reason: 'removed in Ruby, changed in Mendix')
    resolved = sync.run(resolutions: result[:conflicts].to_h { [_1[:id], 'mendix'] })
    expect(resolved).to include(applied: true)
    expect(Mxrb.open(model) { |project| project.microflows.map(&:name) }).to include('Recalculate')
  end

  it 'reports a conflict when Ruby changes a document that Mendix removed, and restores it for Ruby' do
    sync.link!
    id = unit_id_of('Microflows$Microflow', 'Recalculate')
    write_model { _1.delete_unit(id) }
    edit(flow_file) { _1.sub('return_value "empty"', 'return_value "true"') }
    result = sync.run
    unit = result[:conflicts].find { _1[:kind] == 'unit' }
    expect(unit).to include(unit_id: id, reason: 'changed in Ruby, removed in Mendix')
    choices = result[:conflicts].to_h { [_1[:id], 'ruby'] }
    expect(sync.run(resolutions: choices)).to include(applied: true)
    expect(Mxrb.open(model) { |project| project.microflows.map(&:name) }).to include('Recalculate')
  end

  it 'deletes Ruby files of documents Mendix removed and keeps or drops edited ones as resolved' do
    sync.link!
    id = unit_id_of('Microflows$Microflow', 'Recalculate')
    write_model { _1.delete_unit(id) }
    path = flow_file
    expect(sync.run).to include(applied: true)
    expect(File).not_to exist(path)
    expect(File.read(ruby_file('modules/Shop/application/application.rb'))).not_to include('recalculate.rb')
  end

  it 'treats a file both sides changed without a common text as a whole-file conflict' do
    sync.link!
    id = unit_id_of('Microflows$Microflow', 'Recalculate')
    path = flow_file
    edit(path) { "#{_1}# kept by the Ruby side\n" }
    write_model { _1.delete_unit(id) }
    result = sync.run
    file = result[:conflicts].find { _1[:kind] == 'file' && _1[:path].end_with?('recalculate.rb') }
    expect(file).to include(ruby: include('kept by the Ruby side'), mendix: nil)
    choices = result[:conflicts].to_h { [_1[:id], 'ruby'] }
    expect(sync.run(dry_run: true, resolutions: choices)).to include(applied: false, conflicts: result[:conflicts])
    expect(sync.run(resolutions: choices)).to include(applied: true)
    expect(File.read(path)).to include('kept by the Ruby side')
  end

  it 'drops an edited Ruby file when the Mendix deletion wins' do
    sync.link!
    id = unit_id_of('Microflows$Microflow', 'Recalculate')
    path = flow_file
    edit(path) { "#{_1}# local note\n" }
    write_model { _1.delete_unit(id) }
    conflicts = sync.run[:conflicts]
    expect(sync.run(resolutions: conflicts.to_h { [_1[:id], 'mendix'] })).to include(applied: true)
    expect(File).not_to exist(path)
  end

  it 'reports element conflicts for removals and for insertions into removed elements' do
    sync.link!
    edit(product_file) { _1.sub("  integer :Stock\n", '') }
    mendix_operation('operation' => 'change_attribute', 'target' => 'Shop.Product/Stock', 'default' => '5')
    edit(order_file) { _1.sub("decimal :Total\n", "decimal :Total\n  string :Code\n") }
    mendix_operation('operation' => 'remove_entity', 'target' => 'Shop.Order')
    result = sync.run
    elements = result[:conflicts].select { _1[:kind] == 'element' }
    removal = elements.find { _1[:ruby_operation] == 'remove' }
    expect(removal[:base]).to include(present: true, value: include('Name' => 'Stock'))
    insertion = elements.find { _1[:ruby_operation] == 'insert' }
    expect(insertion[:mendix]).to eq(present: false)
    expect(sync.run(resolutions: result[:conflicts].to_h { [_1[:id], 'mendix'] })).to include(applied: true)
    expect(attributes('Product').keys).to include('Stock')
  end

  it 'evaluates and exports in the isolated worker functions directly' do
    sync.link!
    target = File.join(@directory, 'direct', 'Shop.mpr')
    FileUtils.mkdir_p(File.dirname(target))
    expect(sync.send(:evaluate_project, File.join(ruby, 'project.rb'), target, ruby)).to eq(target)
    empty = File.join(@directory, 'empty.rb')
    File.write(empty, "# nothing\n")
    expect { sync.send(:evaluate_project, empty, "#{target}.none", @directory) }
      .to raise_error(Mxrb::Studio::RubySourceError, /did not generate/)
    broken = File.join(@directory, 'broken.rb')
    File.write(broken, "raise NameError, 'missing helper'\n")
    expect { sync.send(:evaluate_project, broken, target, @directory) }.to raise_error(Mxrb::Studio::RubySourceError) do
      expect(_1.message).to eq('NameError: missing helper')
      expect(_1.locations).to include(include(file: broken, line: 1))
    end
    destination = File.join(@directory, 'direct-export')
    expect(sync.send(:export_model, model, destination)).to eq(destination)
    expect(File).to exist(File.join(destination, 'project.rb'))
  end

  it 'skips links, version control, temporary and build directories and special files' do
    sync.link!
    File.symlink(product_file, ruby_file('linked.rb'))
    FileUtils.mkdir_p(ruby_file('.git'))
    File.write(ruby_file('.git/HEAD'), 'ref')
    File.write(ruby_file('.mxrb-temporary'), 'x')
    FileUtils.mkdir_p(ruby_file('node_modules/pkg'))
    File.write(ruby_file('node_modules/pkg/index.rb'), 'x')
    File.mkfifo(ruby_file('pipe'))
    expect(sync.status).to include(state: 'synced', ruby_changes: [])
  end

  it 'cleans up a partial base and propagates failures of parallel jobs' do
    sync.link!
    allow(sync).to receive(:copy_tree).and_raise(Errno::ENOSPC)
    before = Dir.children(sync.state_directory)
    expect { sync.send(:build_base, base_ruby: nil, generated: nil) }.to raise_error(Errno::ENOSPC)
    expect(Dir.children(sync.state_directory)).to match_array(before)
    expect { sync.send(:parallel, -> { 1 }, -> { raise ArgumentError, 'job failed' }) }
      .to raise_error(ArgumentError, 'job failed')
    expect(sync.send(:parallel, -> { 1 }, -> { 2 })).to eq([1, 2])
  end

  it 'reports binary file conflicts by size' do
    files = %w[ours base theirs].to_h { [_1, File.join(@directory, _1)] }
    File.binwrite(files['ours'], "ours\0")
    File.binwrite(files['base'], 'base')
    File.binwrite(files['theirs'], "the\0irs")
    merged = sync.send(:merge_file, 'theme/logo.bin', *files.values)
    expect(sync.send(:file_conflict, merged)).to include(ruby: { binary: 5 }, mendix: { binary: 7 }, hunks: 1)
  end

  it 'orders inserted units below inserted containers and inserts generated-only units' do
    changes = [{ unit_id: 'c', action: 'insert', state: { container: 'b' } },
               { unit_id: 'b', action: 'insert', state: { container: 'a' } },
               { unit_id: 'a', action: 'insert', state: { container: 'root' } }]
    expect(changes.map { sync.send(:depth, changes, _1) }).to eq([2, 1, 0])
    plan = { units: [], conflicts: [] }
    state = { container: 'x', containment: 'Documents', bytes: ''.b }
    sync.send(:plan_change, plan, 'u', base: {}, working: {}, before: {}, after: { 'u' => state }, mendix: {})
    expect(plan).to eq(units: [{ unit_id: 'u', action: 'insert', state: }], conflicts: [])
  end
end
# rubocop:enable Metrics
