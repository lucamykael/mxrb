# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/history'
require 'securerandom'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::History do
  around do |example|
    Dir.mktmpdir('mxrb-history-') do |directory|
      @directory = directory
      original = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'xdg')
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = original
    end
  end

  def create_model(format)
    path = File.join(@directory, 'project.mpr')
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) { entity(:Product) { string :Name } }
    end
    Mxrb.open(path, readonly: false) { _1.mpr.migrate_storage_format!(:v2) } if format == :v2
    path
  end

  def native_state(path)
    model = Mxrb::IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
    model.all_units.to_h do |unit|
      [unit.fetch('UnitID'), [unit.fetch('ContainerID'), unit.fetch('ContainmentName'), model.content_bytes(unit)]]
    end
  ensure
    model&.close
  end

  def writable(path)
    model = Mxrb::IO::MprFile.open(path, readonly: false, apply_studio_compatibility: false)
    model.transaction { yield model }
  ensure
    model&.close
  end

  def unit_of_type(path, type)
    model = Mxrb::IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
    model.all_units.find { model.parse_contents(_1)['$Type'] == type }
  ensure
    model&.close
  end

  def documented(path, unit_id, text)
    writable(path) do |model|
      document = model.parse_contents(model.unit(unit_id))
      model.update_unit(unit_id, document.merge('Documentation' => text))
    end
  end

  %i[v1 v2].each do |format|
    context "with #{format} storage" do
      let(:path) { create_model(format) }
      let(:history) { described_class.new(path, state_root: File.join(@directory, 'state')) }
      let(:domain) { unit_of_type(path, 'DomainModels$DomainModel').fetch('UnitID') }
      let(:module_unit) { unit_of_type(path, 'Projects$ModuleImpl').fetch('UnitID') }

      it 'journals changed, added and removed units and restores their exact bytes on undo and redo' do
        original = native_state(path)
        added = SecureRandom.uuid
        result, entry = history.record('Edit') do
          documented(path, domain, 'changed')
          writable(path) do |model|
            model.insert_unit(container_uuid: module_unit, containment_name: 'Documents', unit_uuid: added,
                              contents_doc: { '$Type' => 'Projects$Folder', 'Name' => 'Extra' })
          end
          :done
        end
        expect(result).to eq(:done)
        expect(entry).to include(label: 'Edit')
        expect(entry[:units]).to contain_exactly({ 'unit_id' => domain, 'kind' => 'changed' },
                                                 { 'unit_id' => added, 'kind' => 'added' })
        edited = native_state(path)

        expect(history.undo).to include(id: entry[:id], direction: 'undo')
        expect(native_state(path)).to eq(original)
        expect(history.entries).to include(undo: [], redo: [include(id: entry[:id])])
        expect(history.redo).to include(direction: 'redo')
        expect(native_state(path)).to eq(edited)

        _, removal = history.record('Remove') { writable(path) { _1.delete_unit(added) } }
        expect(removal[:units]).to eq([{ 'unit_id' => added, 'kind' => 'removed' }])
        history.undo
        expect(native_state(path)).to eq(edited)
        expect(history.entries[:undo].map { _1[:label] }).to eq(['Edit'])
      end

      it 'journals relocations, ignores writes that change nothing and clears redo on a new edit' do
        _, nothing = history.record('Nothing') { nil }
        expect(nothing).to be_nil
        folder = SecureRandom.uuid
        writable(path) do |model|
          model.insert_unit(container_uuid: module_unit, containment_name: 'Documents', unit_uuid: folder,
                            contents_doc: { '$Type' => 'Projects$Folder', 'Name' => 'Target' })
        end
        before = native_state(path)
        _, moved = history.record('Move') do
          writable(path) { _1.relocate_unit(domain, container_uuid: folder, containment_name: 'Documents') }
        end
        expect(moved[:units]).to eq([{ 'unit_id' => domain, 'kind' => 'changed' }])
        history.undo
        expect(native_state(path)).to eq(before)
        history.record('Other') { documented(path, domain, 'other') }
        expect(history.entries[:redo]).to eq([])
        expect { history.redo }.to raise_error(ArgumentError, 'nothing to redo')
      end

      it 'refuses to undo over newer work and keeps the entry' do
        _, entry = history.record('Edit') { documented(path, domain, 'mine') }
        documented(path, domain, 'someone else')
        expect { history.undo }.to raise_error(Mxrb::Studio::Conflict, /changed after this edit/)
        expect(history.entries[:undo].map { _1[:id] }).to eq([entry[:id]])

        added = SecureRandom.uuid
        history.record('Add') do
          writable(path) do |model|
            model.insert_unit(container_uuid: module_unit, containment_name: 'Documents', unit_uuid: added,
                              contents_doc: { '$Type' => 'Projects$Folder', 'Name' => 'Gone' })
          end
        end
        writable(path) { _1.delete_unit(added) }
        expect { history.undo }.to raise_error(Mxrb::Studio::Conflict)
      end
    end
  end

  it 'keeps at most LIMIT entries' do
    stub_const("#{described_class}::LIMIT", 2)
    path = create_model(:v1)
    history = described_class.new(path, state_root: File.join(@directory, 'state'))
    domain = unit_of_type(path, 'DomainModels$DomainModel').fetch('UnitID')
    ids = 3.times.map { |index| history.record("Edit #{index}") { documented(path, domain, "v#{index}") }.last[:id] }
    expect(history.entries[:undo].map { _1[:id] }).to eq(ids.last(2).reverse)
    expect(Dir.children(File.join(history.directory, 'entries')).sort).to eq(ids.last(2).sort)
    2.times { history.undo }
    expect { history.undo }.to raise_error(ArgumentError, 'nothing to undo')
  end

  it 'fails before writing when the model cannot be read' do
    path = create_model(:v1)
    history = described_class.new(path, state_root: File.join(@directory, 'state'))
    File.write(path, 'not a model')
    expect { history.record('Edit') { :never } }.to raise_error(Mxrb::Error)
  end

  it 'inserts native bytes exactly and refuses in read-only mode' do
    path = create_model(:v2)
    domain = unit_of_type(path, 'DomainModels$DomainModel')
    model = Mxrb::IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
    bytes = model.content_bytes(domain)
    expect do
      model.insert_unit_bytes(unit_uuid: SecureRandom.uuid, container_uuid: domain.fetch('ContainerID'),
                              containment_name: 'Documents', bson_bytes: bytes)
    end.to raise_error(Mxrb::ReadOnlyError)
    model.close
    copy = SecureRandom.uuid
    writable(path) do |mpr|
      expect(mpr.insert_unit_bytes(unit_uuid: copy, container_uuid: domain.fetch('ContainerID'),
                                   containment_name: 'Documents', bson_bytes: bytes)).to eq(copy)
    end
    expect(native_state(path).fetch(copy).last).to eq(bytes)
  end
end
# rubocop:enable Metrics
