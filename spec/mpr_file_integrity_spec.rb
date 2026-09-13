# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Integrity scenarios intentionally exercise complete package lifecycles in isolated directories.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::IO::MprFile do
  def make_v2_project(dir)
    path = File.join(dir, 'project.mpr')
    manifest = File.join(dir, 'native_units.json')
    File.write(manifest, JSON.generate('format_version' => 'v2', 'units' => []))
    Mxrb.define(path) do
      mendix_version '11.12.1'
      native_units manifest
      self.module(:App) { entity(:Item) { string :Name } }
    end
    path
  end

  def mxunit_snapshot(contents_dir)
    prefix_length = contents_dir.length + 1
    Dir.glob(File.join(contents_dir, '**', '*.mxunit')).sort.to_h do |path|
      [path[prefix_length..], File.binread(path)]
    end
  end

  def add_test_unit(mpr, name)
    mpr.insert_unit(
      container_uuid: mpr.root_unit.fetch('UnitID'),
      containment_name: 'ProjectDocuments',
      contents_doc: { '$Type' => 'Tests$SnapshotUnit', 'Name' => name }
    )
  end

  it 'fails closed when an external-contents schema has no mprcontents directory' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      FileUtils.rm_rf(File.join(dir, 'mprcontents'))

      expect { described_class.open(path) }
        .to raise_error(Mxrb::IncompletePackageError, /stores unit contents externally.*missing/)
    end
  end

  it 'opens and parses an external-contents schema when mprcontents is present' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      mpr = described_class.open(path, readonly: true)

      expect(mpr.format_version).to eq(:v2)
      expect(mpr.table_info('Unit').map { _1['name'] }).not_to include('Contents')
      expect(mpr.parse_contents(mpr.root_unit)).to include('$Type' => 'Projects$Project')
    ensure
      mpr&.close
    end
  end

  it 'rejects duplicate nested object identities before Studio Pro conversion' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      duplicate_id = SecureRandom.uuid
      mpr = described_class.open(path)
      add_test_unit(mpr, 'Duplicate identities').then do |unit_id|
        mpr.update_unit(
          unit_id,
          {
            '$ID' => unit_id, '$Type' => 'Tests$SnapshotUnit', 'Name' => 'Duplicate identities',
            'Children' => [
              { '$ID' => duplicate_id, '$Type' => 'Tests$Child' },
              { '$ID' => duplicate_id, '$Type' => 'Tests$Child' }
            ]
          }
        )
      end
      mpr.close
      mpr = nil

      result = Mxrb.validate(path)
      expect(result).not_to be_valid
      expect(result.errors.join("\n")).to include('contains duplicate nested $ID')
    ensure
      mpr&.close
    end
  end

  it 'rejects an AutoNumber attribute with an empty default value' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      mpr = described_class.open(path)
      add_test_unit(mpr, 'Invalid AutoNumber').then do |unit_id|
        mpr.update_unit(
          unit_id,
          {
            '$ID' => unit_id, '$Type' => 'Tests$SnapshotUnit', 'Name' => 'Invalid AutoNumber',
            'Attribute' => {
              '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$Attribute', 'Name' => 'Number',
              'NewType' => {
                '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$AutoNumberAttributeType'
              },
              'Value' => {
                '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$StoredValue',
                'DefaultValue' => ''
              }
            }
          }
        )
      end
      mpr.close
      mpr = nil

      result = Mxrb.validate(path)
      expect(result).not_to be_valid
      expect(result.errors.join("\n")).to include(
        'AutoNumber attribute Number must have a default value of 1 or higher'
      )
    ensure
      mpr&.close
    end
  end

  it 'canonicalizes storage objects so $ID is serialized first' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      mpr = described_class.open(path)
      unit_id = add_test_unit(mpr, 'Misordered identity')
      mpr.update_unit(
        unit_id,
        { '$Type' => 'Tests$SnapshotUnit', '$ID' => unit_id, 'Name' => 'Misordered identity' }
      )
      parsed = mpr.parse_contents(mpr.unit(unit_id))
      expect(parsed.keys.first).to eq('$ID')
      mpr.close
      mpr = nil

      result = Mxrb.validate(path)
      expect(result).to be_valid
    ensure
      mpr&.close
    end
  end

  it 'stages v2 files and rolls database and files back when the transaction block fails' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      contents_dir = File.join(dir, 'mprcontents')
      mpr = described_class.open(path)
      updated_id = add_test_unit(mpr, 'Original')
      deleted_id = add_test_unit(mpr, 'Keep')
      before_units = mpr.all_units
      before_files = mxunit_snapshot(contents_dir)

      expect do
        mpr.transaction do
          mpr.update_unit(
            updated_id,
            { '$ID' => updated_id, '$Type' => 'Tests$SnapshotUnit', 'Name' => 'Staged' }
          )
          expect(mpr.parse_contents(mpr.unit(updated_id))).to include('Name' => 'Staged')
          mpr.delete_unit(deleted_id)
          add_test_unit(mpr, 'New')
          raise 'planned transaction failure'
        end
      end.to raise_error(RuntimeError, /planned transaction failure/)

      expect(mpr.all_units).to eq(before_units)
      expect(mxunit_snapshot(contents_dir)).to eq(before_files)
      expect(mpr.parse_contents(mpr.unit(updated_id))).to include('Name' => 'Original')
    ensure
      mpr&.close
    end
  end

  it 'restores every v2 file and rolls SQLite back when staged-file promotion fails' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      contents_dir = File.join(dir, 'mprcontents')
      mpr = described_class.open(path)
      first_id = add_test_unit(mpr, 'First')
      second_id = add_test_unit(mpr, 'Second')
      before_units = mpr.all_units
      before_files = mxunit_snapshot(contents_dir)
      promotions = 0
      allow(Mxrb::IO::MxunitCodec).to receive(:write_atomic).and_wrap_original do |method, *args|
        promotions += 1
        raise IOError, 'planned promotion failure' if promotions == 2

        method.call(*args)
      end

      expect do
        mpr.transaction do
          mpr.update_unit(
            first_id, { '$ID' => first_id, '$Type' => 'Tests$SnapshotUnit', 'Name' => 'Changed' }
          )
          mpr.update_unit(
            second_id, { '$ID' => second_id, '$Type' => 'Tests$SnapshotUnit', 'Name' => 'Changed' }
          )
        end
      end.to raise_error(IOError, /planned promotion failure/)

      expect(mpr.all_units).to eq(before_units)
      expect(mxunit_snapshot(contents_dir)).to eq(before_files)
      expect(File).not_to exist("#{path}.mxrb-transaction")
    ensure
      mpr&.close
    end
  end

  it 'recovers an interrupted uncommitted v2 file journal on the next writable open' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      mpr = described_class.open(path)
      unit_id = add_test_unit(mpr, 'Original')
      raw = mpr.unit(unit_id)
      original = mpr.content_bytes(raw)
      live_path = mpr.content_path(raw)
      relative = live_path.delete_prefix("#{File.join(dir, 'mprcontents')}/")
      journal = "#{path}.mxrb-transaction"
      backup = File.join(journal, 'original', relative)
      FileUtils.mkdir_p(File.dirname(backup))
      File.rename(live_path, backup)
      Mxrb::IO::MxunitCodec.write_atomic(
        live_path,
        Mxrb::IO::BsonCodec.serialize(
          '$ID' => unit_id, '$Type' => 'Tests$SnapshotUnit', 'Name' => 'Interrupted'
        )
      )
      File.write(
        File.join(journal, 'journal.json'),
        JSON.generate(
          'version' => 1, 'id' => SecureRandom.uuid,
          'entries' => [{
            'uuid' => unit_id, 'relative_path' => relative,
            'existed' => true, 'action' => 'write'
          }]
        )
      )
      mpr.close
      mpr = nil

      recovered = described_class.open(path)

      expect(recovered.content_bytes(recovered.unit(unit_id))).to eq(original)
      expect(recovered.parse_contents(recovered.unit(unit_id))).to include('Name' => 'Original')
      expect(File).not_to exist(journal)
    ensure
      recovered&.close
      mpr&.close
    end
  end

  it 'backs up and restores v1 using only the SQLite file' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'project.mpr')
      backup = File.join(dir, 'backup.mpr')
      Mxrb.define(path) do
        mendix_version '10.18.0'
        self.module(:App) { entity :Original }
      end
      mpr = described_class.open(path)
      original_count = mpr.all_units.length

      mpr.backup!(backup)
      added_id = add_test_unit(mpr, 'Added after backup')
      expect(mpr.unit(added_id)).not_to be_nil
      mpr.restore_from!(backup)

      expect(mpr.format_version).to eq(:v1)
      expect(mpr.all_units.length).to eq(original_count)
      expect(mpr.unit(added_id)).to be_nil
      expect(File).not_to exist(File.join(dir, 'mprcontents'))
      expect(File).not_to exist("#{backup}.mprcontents")
    ensure
      mpr&.close
    end
  end

  it 'restores modified, deleted, inserted, and untouched v2 unit files exactly' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      backup = File.join(dir, 'backup.mpr')
      contents_dir = File.join(dir, 'mprcontents')
      mpr = described_class.open(path)
      untouched_id = add_test_unit(mpr, 'Untouched')
      modified_id = add_test_unit(mpr, 'Original')
      deleted_id = add_test_unit(mpr, 'Deleted later')
      original_ids = [untouched_id, modified_id, deleted_id]
      before_units = original_ids.to_h do |unit_id|
        raw = mpr.unit(unit_id)
        [unit_id, { raw:, contents: mpr.parse_contents(raw) }]
      end
      before_files = mxunit_snapshot(contents_dir)

      mpr.backup!(backup)
      mpr.update_unit(
        modified_id,
        { '$ID' => modified_id, '$Type' => 'Tests$SnapshotUnit', 'Name' => 'Modified' }
      )
      mpr.delete_unit(deleted_id)
      inserted_id = add_test_unit(mpr, 'Inserted later')
      mpr.restore_from!(backup)

      original_ids.each do |unit_id|
        expect(mpr.unit(unit_id)).to eq(before_units.dig(unit_id, :raw))
        expect(mpr.parse_contents(mpr.unit(unit_id))).to eq(before_units.dig(unit_id, :contents))
      end
      expect(mpr.unit(inserted_id)).to be_nil
      expect(mxunit_snapshot(contents_dir)).to eq(before_files)
    ensure
      mpr&.close
    end
  end

  it 'removes both backup artifacts during cleanup' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      backup = File.join(dir, 'backup.mpr')
      mpr = described_class.open(path)

      mpr.backup!(backup)
      expect(File).to exist(backup)
      expect(File).to be_directory("#{backup}.mprcontents")
      mpr.cleanup_backup!(backup)

      expect(File).not_to exist(backup)
      expect(File).not_to exist("#{backup}.mprcontents")
    ensure
      mpr&.close
    end
  end

  it 'raises when a v2 restore has no contents snapshot' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      backup = File.join(dir, 'backup.mpr')
      contents_dir = File.join(dir, 'mprcontents')
      mpr = described_class.open(path)
      add_test_unit(mpr, 'Live unit')
      mpr.backup!(backup)
      before_units = mpr.all_units
      before_files = mxunit_snapshot(contents_dir)
      FileUtils.rm_rf("#{backup}.mprcontents")

      expect { mpr.restore_from!(backup) }
        .to raise_error(Mxrb::IncompletePackageError, /missing contents snapshot/)
      expect(mpr.all_units).to eq(before_units)
      expect(mxunit_snapshot(contents_dir)).to eq(before_files)
      expect { add_test_unit(mpr, 'Still usable') }.not_to raise_error
    ensure
      mpr&.close
    end
  end

  it 'restores mprcontents even when the live folder was deleted entirely' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      backup = File.join(dir, 'backup.mpr')
      contents_dir = File.join(dir, 'mprcontents')
      mpr = described_class.open(path)
      add_test_unit(mpr, 'First unit')
      add_test_unit(mpr, 'Second unit')
      before_units = mpr.all_units
      before_files = mxunit_snapshot(contents_dir)
      mpr.backup!(backup)

      FileUtils.rm_rf(contents_dir)
      mpr.restore_from!(backup)

      expect(mpr.all_units).to eq(before_units)
      expect(mxunit_snapshot(contents_dir)).to eq(before_files)
    ensure
      mpr&.close
    end
  end

  it 'backup! leaves no artifacts after a mid-backup failure' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      backup = File.join(dir, 'backup.mpr')
      contents_dir = File.join(dir, 'mprcontents')
      mpr = described_class.open(path)
      add_test_unit(mpr, 'Live unit')
      before_units = mpr.all_units
      before_files = mxunit_snapshot(contents_dir)
      allow(FileUtils).to receive(:cp_r).and_call_original
      allow(FileUtils).to receive(:cp_r)
        .with(contents_dir, "#{backup}.mprcontents")
        .and_raise(IOError, 'planned snapshot failure')

      expect { mpr.backup!(backup) }.to raise_error(IOError, /planned snapshot failure/)

      expect(File).not_to exist(backup)
      expect(File).not_to exist("#{backup}.mprcontents")
      expect(mpr.all_units).to eq(before_units)
      expect(mxunit_snapshot(contents_dir)).to eq(before_files)
    ensure
      mpr&.close
    end
  end

  it 'fully rolls back v2 files and database state after a batch plan fails' do
    Dir.mktmpdir do |dir|
      path = make_v2_project(dir)
      contents_dir = File.join(dir, 'mprcontents')
      mpr = described_class.open(path)
      modified_id = add_test_unit(mpr, 'Original')
      deleted_id = add_test_unit(mpr, 'Keep')
      before_files = mxunit_snapshot(contents_dir)
      inserted_id = nil
      insert_orphan = -> { add_test_unit(mpr, 'Orphan') }
      first_applied = false
      first = Object.new
      first.define_singleton_method(:applied?) { first_applied }
      first.define_singleton_method(:apply!) do
        mpr.update_unit(
          modified_id,
          { '$ID' => modified_id, '$Type' => 'Tests$SnapshotUnit', 'Name' => 'Changed' }
        )
        first_applied = true
      end
      second = Object.new
      second.define_singleton_method(:applied?) { false }
      second.define_singleton_method(:apply!) do
        mpr.delete_unit(deleted_id)
        inserted_id = insert_orphan.call
        raise 'planned failure'
      end
      project = double(mpr:, refresh!: true)
      batch = Mxrb::Semantic::BatchPlan.new(project:, plans: [first, second])

      expect { batch.apply! }.to raise_error(Mxrb::BatchError, /planned failure/)

      expect(mpr.parse_contents(mpr.unit(modified_id))).to include('Name' => 'Original')
      expect(mpr.parse_contents(mpr.unit(deleted_id))).to include('Name' => 'Keep')
      expect(mpr.unit(inserted_id)).to be_nil
      expect(mxunit_snapshot(contents_dir)).to eq(before_files)
      expect(File).not_to exist("#{path}.mxrb_batch_backup")
      expect(File).not_to exist("#{path}.mxrb_batch_backup.mprcontents")
    ensure
      mpr&.close
    end
  end
end
# rubocop:enable Metrics/BlockLength
