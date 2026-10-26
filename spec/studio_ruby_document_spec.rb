# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe 'Studio native document Ruby source resolution' do
  around do |example|
    Dir.mktmpdir('mxrb-ruby-document-') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:state) { File.join(@directory, 'state') }
  let(:service) { Mxrb::Studio::Service.new(state_root: state) }
  let(:model) do
    path = File.join(@directory, 'native', 'App.mpr')
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Shop) do
        module_role :Reader
        entity(:Product) { string :Name }
        entity(:Filter) { non_persistent! }
        microflow(:ACT_DealGame) { log_message 'shop' }
        nanoflow(:ACT_DealGame) { log_message 'nano' }
        page(:Home) { text 'Home' }
      end
      self.module(:Other) { microflow(:ACT_DealGame) { log_message 'other' } }
    end
    path
  end

  let(:root) { call('project/convert', 'source_model' => model).fetch(:root) }

  def call(method, params = {}, context = Mxrb::Studio::RequestContext.new)
    service.dispatch(method, params, context)
  end

  def document(type = 'Microflows$Microflow', mod = 'Shop')
    Mxrb.open(model) do |project|
      target = project.modules.find { _1.name == mod }
      project.all_units.find do |unit|
        unit['ContainerID'] == target.id && project.parse_bson(unit)['$Type'] == type
      end
    end
  end

  def lookup(unit = document, **parameters)
    call('documents/ruby',
         { 'source_model' => model, 'unit_id' => unit.fetch('UnitID') }.merge(parameters.transform_keys(&:to_s)))
  end

  def source_path
    File.join(root, 'modules/Shop/application/use_cases/act_deal_game.rb')
  end

  def metadata_path = File.join(root, '.mxrb/semantic_metadata.json')

  it 'advertises the operation and asks for conversion only for supported documents' do
    expect(service.methods_list).to include('documents/ruby')
    expect(lookup).to include(state: 'missing_project', root: nil, path: nil,
                              qualified_name: 'Shop.ACT_DealGame', type: 'Microflows$Microflow')
    expect(lookup(document('DomainModels$DomainModel'))).to include(state: 'missing_project')
    expect(Dir.glob(File.join(state, 'ruby-conversions', '*'))).to be_empty
  end

  it 'resolves an actual exported main_line flow without evaluating Ruby or changing the model' do
    root
    marker = File.join(@directory, 'never-execute')
    File.open(source_path, 'a') { _1.puts "File.write(#{marker.inspect}, 'executed')" }
    before = File.binread(model)
    expect(lookup(qualified_name: 'Shop.ACT_DealGame', type: 'Microflows$Microflow'))
      .to include(state: 'ready', root:, path: 'modules/Shop/application/use_cases/act_deal_game.rb', line: 3)
    expect(File.read(source_path)).to include('def main_line')
    expect(File).not_to exist(marker)
    expect(File.binread(model)).to eq(before)
  end

  it 'distinguishes the same name in different modules and between microflow and nanoflow' do
    root
    expect(lookup(document('Microflows$Microflow', 'Other')))
      .to include(state: 'ready', path: 'modules/Other/application/use_cases/act_deal_game.rb')
    nano = lookup(document('Microflows$Nanoflow'))
    expect(nano).to include(state: 'ready', type: 'Microflows$Nanoflow')
    expect(File.read(File.join(root, nano.fetch(:path)))).to include('nanoflow :ACT_DealGame')
  end

  it 'locates a moved Ruby file by its declaration and returns its actual line' do
    moved = File.join(root, 'modules/Shop/custom/renamed.rb')
    FileUtils.mkdir_p(File.dirname(moved))
    File.write(moved, "# moved source\n#{File.read(source_path)}")
    File.unlink(source_path)
    expect(lookup).to include(state: 'ready', path: 'modules/Shop/custom/renamed.rb', line: 4)
  end

  it 'supports a page without transport UUID noise in its declaration' do
    root
    found = lookup(document('Forms$Page'))
    expect(found).to include(state: 'ready', qualified_name: 'Shop.Home')
    expect(File.read(File.join(root, found.fetch(:path)))).to include('page :Home')
  end

  it 'offers the actual domain index, entities and DTOs as files of one native domain model' do
    root
    found = lookup(document('DomainModels$DomainModel'))
    expect(found).to include(state: 'choose', root:, path: nil)
    expect(found.fetch(:files)).to contain_exactly(
      include(path: 'modules/Shop/domain/model.rb', line: 1, label: 'Shop — Domain model'),
      include(path: 'modules/Shop/domain/entities/product.rb', label: 'Shop.Product'),
      include(path: 'modules/Shop/domain/dtos/filter_dto.rb', label: 'Shop.Filter')
    )
  end

  it 'finds moved domain members and refuses ambiguous entity declarations' do
    original = File.join(root, 'modules/Shop/domain/entities/product.rb')
    moved = File.join(root, 'modules/Shop/custom_product.rb')
    FileUtils.mv(original, moved)
    expect(lookup(document('DomainModels$DomainModel')).fetch(:files))
      .to include(include(path: 'modules/Shop/custom_product.rb', label: 'Shop.Product'))
    FileUtils.cp(moved, original)
    expect(lookup(document('DomainModels$DomainModel'))).to include(state: 'unavailable', reason: 'ambiguous_source')
  end

  it 'opens a verified empty domain index and rejects an unrelated or invalid replacement' do
    path = File.join(root, 'modules/Other/domain/model.rb')
    expect(lookup(document('DomainModels$DomainModel', 'Other')))
      .to include(state: 'ready', path: 'modules/Other/domain/model.rb')
    ['puts "unrelated"', 'def broken'].each do |source|
      File.write(path, source)
      expect(lookup(document('DomainModels$DomainModel', 'Other')))
        .to include(state: 'unavailable', reason: 'source_not_found')
    end
  end

  it 'resolves every global Ruby projection and the module and project declarations' do
    root
    expected = {
      'Security$ProjectSecurity' => 'app/security/security.rb',
      'Navigation$NavigationDocument' => 'app/navigation/navigation.rb',
      'Settings$ProjectSettings' => 'app/settings/settings.rb',
      'Texts$SystemTextCollection' => 'app/texts/system_texts.rb',
      'Projects$Project' => 'project.rb'
    }
    Mxrb.open(model) do |project|
      expected.each do |type, path|
        unit = project.all_units.find { project.parse_bson(_1)['$Type'] == type }
        expect(unit).not_to be_nil, "missing native fixture for #{type}"
        expect(lookup(unit)).to include(state: 'ready', path:)
      end
      mod = project.modules.find { _1.name == 'Shop' }
      expect(lookup(project.mpr.unit(mod.id), qualified_name: 'Shop'))
        .to include(state: 'ready', path: 'modules/Shop/module.rb', qualified_name: 'Shop')
    end
    expect(lookup(document('Security$ModuleSecurity')))
      .to include(state: 'ready', path: 'modules/Shop/security/security.rb')
  end

  it 'does not silently choose one of duplicate declarations' do
    FileUtils.cp(source_path, File.join(root, 'modules/Shop/duplicate.rb'))
    expect(lookup).to include(state: 'unavailable', reason: 'ambiguous_source', path: nil)
  end

  it 'does not invent a Ruby file when the linked project lacks that declaration' do
    File.unlink(source_path)
    expect(lookup).to include(state: 'unavailable', root:, reason: 'source_not_found')
    expect(Dir.children(File.join(state, 'ruby-conversions')).size).to eq(1)
  end

  it 'rejects stale flow identity metadata and does not match only the filename' do
    metadata = JSON.parse(File.read(metadata_path))
    entry = metadata.dig('modules', 'Shop', 'flows', 'ACT_DealGame').find do
      _1['native_type'] == 'Microflows$Microflow'
    end
    entry['unit_id'] = SecureRandom.uuid
    File.write(metadata_path, JSON.generate(metadata))
    expect(lookup).to include(state: 'unavailable', reason: 'source_not_found')
  end

  it 'requires valid unambiguous flow metadata when the declaration omits unit_id' do
    root
    [nil, '[]', '{broken'].each do |contents|
      contents ? File.write(metadata_path, contents) : File.unlink(metadata_path)
      expect(lookup).to include(state: 'unavailable', reason: 'source_not_found')
    end
  end

  it 'rejects a declaration that claims a different explicit unit_id' do
    File.write(source_path, "microflow :ACT_DealGame, unit_id: #{SecureRandom.uuid.inspect} do\nend\n")
    expect(lookup).to include(state: 'unavailable', reason: 'source_not_found')
  end

  it 'rejects executable, interpolated or nested declarations and invalid Ruby' do
    source_path
    ['microflow ENV.fetch("NAME")', 'microflow :ACT_DealGame do',
     "def fake\n microflow :ACT_DealGame\nend", 'other.microflow :ACT_DealGame',
     "microflow \"ACT_\#{\"DealGame\"}\""].each do |source|
      File.write(source_path, source)
      expect(lookup).to include(state: 'unavailable', reason: 'source_not_found')
    end
  end

  it 'never traverses a source symlink or accepts a root supplied by the caller' do
    outside = File.join(@directory, 'outside.rb')
    FileUtils.mv(source_path, outside)
    File.symlink(outside, source_path)
    expect(lookup(root: @directory)).to include(state: 'unavailable', root:, reason: 'source_not_found')
    File.unlink(source_path)
    File.symlink(@directory, File.join(root, 'modules/Shop/outside'))
    expect(lookup).to include(state: 'unavailable', reason: 'source_not_found')
  end

  it 'refuses unknown or stale native document hints' do
    expect(lookup({ 'UnitID' => SecureRandom.uuid })).to include(state: 'unavailable', reason: 'unknown_document')
    expect(lookup(type: 'Forms$Page')).to include(state: 'unavailable', reason: 'document_changed')
    expect(lookup(qualified_name: 'Other.ACT_DealGame')).to include(state: 'unavailable', reason: 'document_changed')
    expect { lookup({ 'UnitID' => '../escape' }) }.to raise_error(ArgumentError, 'unit_id must be a UUID')
  end

  it 'resolves all exporter document families and universal native unit declarations' do
    mpr = Mxrb::IO::MprFile.open(model)
    mod = Mxrb.open(model) { _1.modules.find { |entry| entry.name == 'Shop' } }
    types = Mxrb::Model::Module::EDITABLE_DOCUMENT_TYPES + ['Future$ExtensionDocument']
    units = types.to_h do |type|
      contents_doc = { '$Type' => type, 'Name' => type.split('$').last }
      contents_doc['Marker'] = 'native fallback projection' unless type.start_with?('Forms$')
      contents_doc['FontData'] = BSON::Binary.new('') if type == 'CustomIcons$CustomIconCollection'
      id = mpr.insert_unit(container_uuid: mod.id, containment_name: 'Documents',
                           contents_doc:)
      [type, { 'UnitID' => id }]
    end
    mpr.close
    root
    units.each do |type, unit|
      found = lookup(unit)
      expect(found).to include(state: 'ready', type:), "#{type}: #{found}"
      expect(File).to exist(File.join(root, found.fetch(:path)))
    end
    expect(lookup(units.fetch('Future$ExtensionDocument'))).to include(path: '.mxrb/native_units.rb')
  ensure
    mpr&.close
  end

  it 'requires exact identity for a generic native document regardless of its BSON type' do
    root
    unit = document('Microflows$Microflow')
    File.write(source_path, "native_document :ACT_DealGame, type: 'Microflows$Microflow', " \
                            "unit_id: #{unit.fetch('UnitID').inspect}, deep_structure: {}\n")
    expect(lookup(unit)).to include(state: 'ready')
    File.write(source_path, File.read(source_path).sub('Microflows$Microflow', 'Microflows$Nanoflow'))
    expect(lookup(unit)).to include(state: 'unavailable', reason: 'source_not_found')
  end

  it 'does not present baseline metadata as a Ruby file, or reconvert an existing project' do
    mpr = Mxrb::IO::MprFile.open(model)
    id = mpr.insert_unit(container_uuid: document.fetch('ContainerID'), containment_name: 'Folders',
                         contents_doc: { '$Type' => 'Projects$Folder', 'Name' => 'Folder' })
    mpr.close
    unit = { 'UnitID' => id }
    expect(lookup(unit)).to include(state: 'unavailable', reason: 'unsupported_type')
    root
    expect(lookup(unit)).to include(state: 'unavailable', reason: 'source_not_found')
    expect(Dir.children(File.join(state, 'ruby-conversions')).size).to eq(1)
  ensure
    mpr&.close
  end

  it 'opens an empty module security source only when the loader evaluates it' do
    security = File.join(root, 'modules/Other/security/security.rb')
    mod = Mxrb.open(model) { _1.modules.find { |entry| entry.name == 'Other' } }
    mpr = Mxrb::IO::MprFile.open(model)
    unit = { 'UnitID' => mpr.insert_unit(container_uuid: mod.id, containment_name: 'ModuleSecurity',
                                         contents_doc: { '$Type' => 'Security$ModuleSecurity', 'ModuleRoles' => [3] }) }
    mpr.close
    expect(lookup(unit)).to include(state: 'ready', path: 'modules/Other/security/security.rb', line: 1)
    File.write(security, "puts 'not a declaration'\n")
    expect(lookup(unit)).to include(state: 'unavailable', reason: 'source_not_found')
  ensure
    mpr&.close
  end

  it 'accepts only literal loader paths below the module directory' do
    loader = File.join(root, 'modules/Other/module.rb')
    expect(lookup(document('DomainModels$DomainModel', 'Other'))).to include(state: 'ready')
    [
      "self.module :Other do\n  evaluate 'domain/model.rb'\n  evaluate File.join('domain', 'model.rb')\n" \
      "  evaluate File.join(__dir__)\n  evaluate File.join(__dir__, '..', 'model.rb')\n  evaluate File.join()\n" \
      "  log_message 'x'\nend\n",
      "self.module :Other\n"
    ].each do |source|
      File.write(loader, source)
      expect(lookup(document('DomainModels$DomainModel', 'Other')))
        .to include(state: 'unavailable', reason: 'source_not_found')
    end
  end

  it 'requires the module loader, one module declaration and the evaluated domain index' do
    loader = File.join(root, 'modules/Other/module.rb')
    original = File.read(loader)
    [
      -> { File.unlink(loader) },
      -> { File.write(loader, "puts 'no module declaration'\n") },
      -> { File.unlink(File.join(root, 'modules/Other/domain/model.rb')) }
    ].each do |change|
      File.write(loader, original)
      change.call
      expect(lookup(document('DomainModels$DomainModel', 'Other')))
        .to include(state: 'unavailable', reason: 'source_not_found')
    end
  end

  it 'refuses duplicate module declarations and ignores unrelated project definitions' do
    FileUtils.cp(File.join(root, 'modules/Shop/module.rb'), File.join(root, 'modules/Shop/module_copy.rb'))
    Mxrb.open(model) do |project|
      mod = project.modules.find { _1.name == 'Shop' }
      expect(lookup(project.mpr.unit(mod.id))).to include(state: 'unavailable', reason: 'ambiguous_source')
      File.open(File.join(root, 'project.rb'), 'a') { _1.puts "Mxrb.define('Other.mpr') do\n  mendix_version '11.12.1'\nend" }
      unit = project.all_units.find { project.parse_bson(_1)['$Type'] == 'Projects$Project' }
      expect(lookup(unit)).to include(state: 'ready', path: 'project.rb')
    end
  end

  it 'skips argument-less, splatted and non-Ruby entries while scanning declarations' do
    File.write(File.join(root, 'modules/Shop/README.md'), "microflow :ACT_DealGame\n")
    File.write(File.join(root, 'modules/Shop/extra.rb'),
               "native_unit\nnative_unit unit_reference\nmicroflow :Other, **options\n")
    expect(lookup).to include(state: 'ready', path: 'modules/Shop/application/use_cases/act_deal_game.rb')
  end

  it 'treats a missing module folder or a file removed during lookup as no declaration' do
    FileUtils.rm_rf(File.join(root, 'modules/Other'))
    expect(lookup(document('Microflows$Microflow', 'Other')))
      .to include(state: 'unavailable', reason: 'source_not_found')
    allow_any_instance_of(Mxrb::Studio::Files).to receive(:read).and_wrap_original do |original, path|
      raise Errno::ENOENT, path if path == 'modules/Shop/domain/model.rb'

      original.call(path)
    end
    found = lookup(document('DomainModels$DomainModel'))
    expect(found.fetch(:files).map { _1.fetch(:path) }).not_to include('modules/Shop/domain/model.rb')
  end

  it 'bounds the number of entries scanned for a declaration' do
    root
    stub_const('Mxrb::Studio::RubyDocument::MAXIMUM_FILES', 1)
    expect { lookup }.to raise_error(ArgumentError, 'Ruby document lookup exceeds 10000 entries')
  end

  it 'observes cancellation before reading a native model' do
    context = Mxrb::Studio::RequestContext.new
    context.cancel!
    expect { call('documents/ruby', { 'source_model' => model, 'unit_id' => document.fetch('UnitID') }, context) }
      .to raise_error(Mxrb::Studio::Cancelled)
  end
end
# rubocop:enable Metrics
