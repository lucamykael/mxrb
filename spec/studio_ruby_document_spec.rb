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
        entity(:Product) { string :Name }
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
    expect(lookup(document('DomainModels$DomainModel')))
      .to include(state: 'unavailable', reason: 'unsupported_type')
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

  it 'observes cancellation before reading a native model' do
    context = Mxrb::Studio::RequestContext.new
    context.cancel!
    expect { call('documents/ruby', { 'source_model' => model, 'unit_id' => document.fetch('UnitID') }, context) }
      .to raise_error(Mxrb::Studio::Cancelled)
  end
end
# rubocop:enable Metrics
