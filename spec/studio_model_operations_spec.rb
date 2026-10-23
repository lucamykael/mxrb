# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/model_operations'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::ModelOperations do
  around do |example|
    Dir.mktmpdir('mxrb-structural-edit-') do |directory|
      @directory = directory
      original = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'state')
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = original
    end
  end

  def create_model(format, references: false)
    path = File.join(@directory, 'project.mpr')
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) do
        entity(:Product) { string :Name }
        entity(:Other) { integer :Count }
        if references
          microflow :UseName do
            retrieve_objects 'Shop.Product', as: :items
            change_object(:items) { set 'Shop.Product/Name', to: "'hello'" }
          end
        end
      end
    end
    Mxrb.open(path, readonly: false) { _1.mpr.migrate_storage_format!(:v2) } if format == :v2
    path
  end

  def native_state(path)
    model = Mxrb::IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
    model.all_units.to_h { |unit| [unit.fetch('UnitID'), [unit, model.content_bytes(unit)]] }
  ensure
    model&.close
  end

  %i[v1 v2].each do |format|
    context "with #{format} storage" do
      let(:path) { create_model(format) }
      let(:editor) { described_class.new(path, workspace_root: @directory) }

      it 'previews without modifying source and applies typed attributes with native validation rules' do
        operation = { 'operation' => 'add_attribute', 'target' => 'Shop.Product', 'name' => 'Price',
                      'type' => 'decimal', 'default' => '0.0', 'required' => true, 'unique' => true }
        before = native_state(path)
        revision = editor.revision
        preview = editor.preview(operation, revision:)
        expect(preview).to include(safe: true, applied: false, revision:)
        expect(native_state(path)).to eq(before)
        applied = editor.apply(operation, revision:)
        expect(applied).to include(applied: true)
        expect(applied[:revision]).not_to eq(revision)
        Mxrb.open(path) do |project|
          product = project.entities.find { _1.name == 'Product' }
          price = product.attributes.find { _1.name == 'Price' }
          expect(price).to have_attributes(type: :decimal, default_value: '0.0', required: true, unique: true)
          expect(project.format_version).to eq(format)
        end
        after = native_state(path)
        domain_id = Mxrb.open(path) { _1.modules.first.domain_model.id }
        before.each { |id, native| expect(after[id]).to eq(native) unless id == domain_id }
      end

      it 'updates selected attribute properties preserving identity, other attributes and references' do
        before = Mxrb.open(path) { _1.entities.first.attributes.first }
        editor.apply({ operation: 'change_attribute', target: 'Shop.Product/Name',
                       documentation: 'Nome 🐧', length: 80, required: true, unique: true }, revision: editor.revision)
        changed = Mxrb.open(path) { _1.entities.first.attributes.first }
        expect(changed).to have_attributes(id: before.id, type: :string, documentation: 'Nome 🐧',
                                           length: 80, required: true, unique: true)
        editor.apply({ operation: 'change_attribute', target: 'Shop.Product/Name', required: false, unique: false },
                     revision: editor.revision)
        removed = Mxrb.open(path) { _1.entities.first.attributes.first }
        expect(removed.required).not_to be(true)
        expect(removed.unique).not_to be(true)
      end

      it 'creates and removes an entity and safely removes an unused attribute' do
        editor.apply({ operation: 'add_entity', target: 'Shop', name: 'Temporary', non_persistent: true,
                       attributes: [{ name: 'Caption', type: 'string', required: true }] }, revision: editor.revision)
        created = Mxrb.open(path) { _1.entities.find { |entity| entity.name == 'Temporary' } }
        expect(created).to have_attributes(persistable: false)
        expect(created.attributes.first).to have_attributes(name: 'Caption', required: true)
        editor.apply({ operation: 'remove_attribute', target: 'Shop.Other/Count' }, revision: editor.revision)
        expect(Mxrb.open(path) { _1.entities.find { |entity| entity.name == 'Other' }.attributes }).to be_empty
        editor.apply({ operation: 'add_entity', target: 'Shop', name: 'Unused' }, revision: editor.revision)
        editor.apply({ operation: 'remove_entity', target: 'Shop.Unused' }, revision: editor.revision)
        expect(Mxrb.open(path) { _1.entities.map(&:name) }).not_to include('Unused')
      end

      it 'preserves the saved source while applying to an explicit snapshot working copy' do
        before = native_state(path)
        snapshot = Mxrb::Studio::Snapshot.new(path, destination_root: File.join(@directory, 'workspaces')).create
        working = described_class.new(snapshot[:model], workspace_root: snapshot[:root], source_model: path)
        working.apply({ operation: 'add_attribute', target: 'Shop.Product', name: 'OnlyInCopy' },
                      revision: working.revision)
        expect(native_state(path)).to eq(before)
        expect(Mxrb.open(snapshot[:model]) { _1.entities.first.attributes.map(&:name) }).to include('OnlyInCopy')
      end

      it 'rejects a typed operation that introduces an integrity validation error during preview' do
        before = native_state(path)
        revision = editor.revision
        valid = Mxrb::Integrity::Result.new(errors: [], warnings: [])
        invalid = Mxrb::Integrity::Result.new(errors: ['new structural integrity error'], warnings: [])
        allow(Mxrb).to receive(:validate).and_return(valid, invalid)
        expect do
          editor.apply({ operation: 'add_attribute', target: 'Shop.Product', name: 'Rejected' }, revision:)
        end.to raise_error(ArgumentError, /introduces integrity errors/)
        expect(native_state(path)).to eq(before)
      end

      it 'rejects an attribute name inherited from a native generalization target' do
        inherited = File.join(@directory, 'inheritance.mpr')
        Mxrb.define(inherited) do
          mendix_version '10.18.0'
          self.module(:Shop) do
            entity(:Base) { string :Name }
            entity(:Specialized) { generalizes 'Shop.Base' }
          end
        end
        Mxrb.open(inherited, readonly: false) { _1.mpr.migrate_storage_format!(:v2) } if format == :v2
        inherited_editor = described_class.new(inherited, workspace_root: @directory)
        before = native_state(inherited)
        expect do
          inherited_editor.apply({ operation: 'add_attribute', target: 'Shop.Specialized', name: 'Name' },
                                 revision: inherited_editor.revision)
        end.to raise_error(ArgumentError, /ancestor/)
        expect(native_state(inherited)).to eq(before)
      end

      it 'allows one of two clients using the same revision to commit and preserves the winning edit' do
        revision = editor.revision
        model_path = path
        root = @directory
        results = Queue.new
        workers = %w[First Second].map do |name|
          Thread.new do
            client = described_class.new(model_path, workspace_root: root)
            client.apply({ operation: 'add_attribute', target: 'Shop.Product', name: }, revision:)
            results << :saved
          rescue Mxrb::Studio::Conflict
            results << :conflict
          end
        end
        workers.each(&:join)
        expect(2.times.map { results.pop }).to contain_exactly(:saved, :conflict)
        names = Mxrb.open(path) { _1.entities.first.attributes.map(&:name) }
        expect(names & %w[First Second]).to have_attributes(size: 1)
      end

      it 'rejects malformed types, flags, options, duplicates and unsupported operations before writing' do
        revision = editor.revision
        before = native_state(path)
        base = { operation: 'add_attribute', target: 'Shop.Product', name: 'Extra' }
        invalid = [base.merge(type: 'arbitrary'), base.merge(required: 'true'), base.merge(length: -1),
                   base.merge(type: 'integer', length: 80), base.merge(name: 'name'),
                   base.merge(calculated: 'Shop.Flow'), base.merge(name: 'bad.name'),
                   { operation: 'add_association', target: 'Shop.Product' },
                   { operation: 'change_attribute', target: 'Shop.Product/Name' }]
        invalid.each do |operation|
          expect { editor.apply(operation, revision:) }.to raise_error(ArgumentError)
          expect(native_state(path)).to eq(before)
        end
      end

      it 'rejects stale revisions including references introduced in a different unit' do
        revision = editor.revision
        editor.apply({ operation: 'add_entity', target: 'Shop', name: 'External' }, revision:)
        before = native_state(path)
        expect { editor.apply({ operation: 'add_attribute', target: 'Shop.Product', name: 'Extra' }, revision:) }
          .to raise_error(Mxrb::Studio::Conflict)
        expect(native_state(path)).to eq(before)
      end

      it 'rolls back actual native payload writes when a planner fails during apply' do
        operation = { operation: 'add_attribute', target: 'Shop.Product', name: 'Rejected' }
        before = native_state(path)
        model = path
        allow_any_instance_of(Mxrb::IO::MprFile).to receive(:update_unit).and_wrap_original do |original, *arguments|
          original.call(*arguments)
          raise 'planned write failure' if original.receiver.path == model
        end
        expect do
          editor.apply(operation, revision: editor.revision)
        end.to raise_error(RuntimeError, 'planned write failure')
        expect(native_state(path)).to eq(before)
      end

      it 'refuses attribute removal and type changes when actual microflow references exist' do
        referenced_path = create_model(format, references: true)
        referenced_editor = described_class.new(referenced_path, workspace_root: @directory)
        before = native_state(referenced_path)
        revision = referenced_editor.revision
        preview = referenced_editor.preview({ operation: 'remove_attribute', target: 'Shop.Product/Name' }, revision:)
        expect(preview).to include(safe: false)
        expect(preview[:incoming]).not_to be_empty
        expect { referenced_editor.apply({ operation: 'remove_attribute', target: 'Shop.Product/Name' }, revision:) }
          .to raise_error(ArgumentError, /incoming reference/)
        expect do
          referenced_editor.apply({ operation: 'change_attribute', target: 'Shop.Product/Name', type: 'integer' },
                                  revision:)
        end.to raise_error(ArgumentError, /incoming reference/)
        expect(native_state(referenced_path)).to eq(before)
      end
    end
  end

  it 'requires an explicit working-copy root and rejects the identified source model' do
    path = create_model(:v1)
    FileUtils.mkdir_p(File.join(@directory, 'state'))
    expect { described_class.new(path, workspace_root: File.join(@directory, 'state')) }
      .to raise_error(ArgumentError, /inside/)
    expect { described_class.new(path, workspace_root: @directory, source_model: path) }
      .to raise_error(ArgumentError, /source model/)
    linked = File.join(@directory, 'hard-link.mpr')
    File.link(path, linked)
    expect { described_class.new(linked, workspace_root: @directory, source_model: path) }
      .to raise_error(ArgumentError, /source model/)
    expect(described_class.new(path, workspace_root: @directory).capabilities[:unsupported])
      .to include(:add_association, :change_generalization)
  end
end
# rubocop:enable Metrics
