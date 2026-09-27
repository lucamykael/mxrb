# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Mxrb::IO::MprFile do # rubocop:disable Metrics/BlockLength
  it 'migrates Studio 11 split storage back to the Studio 9 monolithic format' do
    Dir.mktmpdir('mxrb-storage-v1-') do |directory|
      path = File.join(directory, 'Storage.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:App) { entity(:Item) { string :Name } }
      end
      mpr = described_class.open(path)
      expect(mpr.ensure_storage_for_version!('11.12.1')).to equal(mpr)
      expect(mpr.format_version).to eq(:v2)
      expect(mpr.ensure_storage_for_version!('9.6.1.29396')).to equal(mpr)
      expect(mpr.format_version).to eq(:v1)
      expect(File).not_to exist("#{path}.mprcontents")
      expect(mpr.all_units).to all(satisfy { _1['Contents'].is_a?(String) })
    ensure
      mpr&.close
    end
  end

  it 'rejects missing backups, stale journals, readonly recovery, and malformed manifests' do
    Dir.mktmpdir('mxrb-storage-errors-') do |directory|
      path = File.join(directory, 'Storage.mpr')
      Mxrb.define(path) { mendix_version '11.12.1' }
      mpr = described_class.open(path)
      expect { mpr.send(:restore_v2_contents!, File.join(directory, 'Missing.mpr')) }
        .to raise_error(Mxrb::IncompletePackageError, /missing contents snapshot/)

      journal = mpr.send(:transaction_journal_dir)
      FileUtils.mkdir_p(journal)
      state = { writes: { 'unit' => 'bytes' }, deletes: {}, journal_dir: nil }
      mpr.instance_variable_set(:@v2_transaction, state)
      expect { mpr.send(:apply_v2_transaction!) }
        .to raise_error(Mxrb::IncompletePackageError, /stale MPR transaction journal/)
      mpr.instance_variable_set(:@v2_transaction, nil)

      mpr.instance_variable_set(:@readonly, true)
      expect { mpr.send(:recover_interrupted_v2_transaction!) }
        .to raise_error(Mxrb::IncompletePackageError, /open writable to recover/)
      mpr.instance_variable_set(:@readonly, false)
      File.write(mpr.send(:transaction_manifest_path), '{')
      expect { mpr.send(:recover_interrupted_v2_transaction!) }
        .to raise_error(Mxrb::IncompletePackageError, /invalid MPR transaction journal/)
    ensure
      mpr&.close
    end
  end

  it 'removes files created by an interrupted transaction and absorbs marker cleanup races' do
    Dir.mktmpdir('mxrb-storage-restore-') do |directory|
      path = File.join(directory, 'Storage.mpr')
      Mxrb.define(path) { mendix_version '11.12.1' }
      mpr = described_class.open(path)
      relative = File.join('aa', 'new.mxunit')
      live = File.join(mpr.send(:contents_dir), relative)
      FileUtils.mkdir_p(File.dirname(live))
      File.write(live, 'new')
      FileUtils.mkdir_p(File.join(mpr.send(:transaction_journal_dir), 'original'))
      mpr.send(:restore_interrupted_v2_files!, [{ 'relative_path' => relative, 'existed' => false }])
      expect(File).not_to exist(live)

      database = double('database')
      allow(database).to receive(:execute).and_raise(SQLite3::Exception, 'race')
      isolated = described_class.allocate
      isolated.instance_variable_set(:@db, database)
      allow(isolated).to receive(:tables).and_return(['_MxrbFileTransaction'])
      expect(isolated.send(:clear_v2_transaction_marker!, 'id')).to be_nil
    ensure
      mpr&.close
    end
  end

  it 'covers staged reads, read-only guards, invalid formats, and nested transactions' do
    isolated = described_class.allocate
    isolated.instance_variable_set(:@format_version, :v2)
    allow(isolated).to receive(:staged_v2_content).and_return([true, nil], [true, 'bytes'])
    expect(isolated.parse_contents('UnitID' => 'unit', 'Contents' => nil)).to eq({})
    expect(isolated.content_bytes('UnitID' => 'unit', 'Contents' => nil)).to eq('bytes')

    isolated.instance_variable_set(:@readonly, true)
    expect { isolated.ensure_v2_contract! }.to raise_error(Mxrb::ReadOnlyError)
    expect { isolated.migrate_storage_format!(:v1) }.to raise_error(Mxrb::ReadOnlyError)
    expect { isolated.delete_unit('unit') }.to raise_error(Mxrb::ReadOnlyError)
    expect { isolated.apply_studio_compatibility! }.to raise_error(Mxrb::ReadOnlyError)
    isolated.instance_variable_set(:@readonly, false)
    expect { isolated.migrate_storage_format!(:future) }.to raise_error(ArgumentError, /v1 or v2/)
    isolated.instance_variable_set(:@v2_transaction, {})
    expect { isolated.transaction {} }.to raise_error(Mxrb::ValidationError, /nested/)
  end

  it 'writes transaction state alternatives and rolls back only existing backups' do
    Dir.mktmpdir('mxrb-storage-transaction-') do |directory|
      isolated = described_class.allocate
      isolated.instance_variable_set(:@path, File.join(directory, 'Storage.mpr'))
      isolated.instance_variable_set(:@format_version, :v2)
      allow(isolated).to receive(:contents_dir).and_return(File.join(directory, 'contents'))

      state = { writes: {}, deletes: {}, applied: [], journal_dir: nil, id: 'transaction' }
      isolated.instance_variable_set(:@v2_transaction, state)
      expect(isolated.send(:delete_v2_unit, 'missing')).to eq([])
      expect(isolated.send(:staged_v2_content, 'missing')).to eq([true, nil])
      isolated.send(:write_v2_unit, 'written', 'bytes')
      expect(isolated.send(:staged_v2_content, 'written')).to eq([true, 'bytes'])

      journal = File.join(directory, 'journal')
      state[:journal_dir] = journal
      path = File.join(directory, 'contents', 'aa', 'unit.mxunit')
      state[:applied] << { path:, backup: File.join(journal, 'missing'), existed: false }
      expect(isolated.send(:rollback_v2_transaction!)).to eq([state[:applied].first])
      isolated.instance_variable_set(:@v2_transaction, nil)
      expect(isolated.send(:rollback_v2_transaction!)).to be_nil
      expect(isolated.send(:cleanup_v2_transaction!)).to be_nil
    end
  end

  it 'records write and delete manifest actions and applies deletion-only entries' do
    Dir.mktmpdir('mxrb-storage-manifest-') do |directory|
      isolated = described_class.allocate
      isolated.instance_variable_set(:@path, File.join(directory, 'Storage.mpr'))
      allow(isolated).to receive(:contents_dir).and_return(File.join(directory, 'contents'))
      written_manifest = nil
      allow(isolated).to receive(:write_atomic_file) { |_path, bytes| written_manifest = bytes }
      state = {
        writes: { 'write-id' => 'bytes' }, deletes: { 'delete-id' => true },
        applied: [], journal_dir: File.join(directory, 'journal'), id: 'transaction'
      }
      isolated.send(:write_v2_transaction_manifest!, state, %w[write-id delete-id])
      manifest = JSON.parse(written_manifest)
      expect(manifest.fetch('entries').map { _1.fetch('action') }).to contain_exactly('write', 'delete')

      FileUtils.mkdir_p(state.fetch(:journal_dir))
      isolated.send(:apply_v2_transaction_unit!, state, 'delete-id')
      expect(state.fetch(:applied).last.fetch(:existed)).to be(false)
    end
  end

  it 'skips stable mpr names and keeps transaction markers while rows remain' do
    Dir.mktmpdir('mxrb-storage-name-') do |directory|
      path = File.join(directory, 'Storage.mpr')
      contents = File.join(directory, 'Storage.mprcontents')
      FileUtils.mkdir_p(contents)
      File.binwrite(File.join(contents, 'mprname'), 'Storage.mpr')
      isolated = described_class.allocate
      isolated.instance_variable_set(:@path, path)
      allow(isolated).to receive(:contents_dir).and_return(contents)
      expect(isolated.send(:write_mpr_name!)).to be_nil

      database = double
      allow(database).to receive(:execute)
      allow(database).to receive(:get_first_value).and_return(1)
      isolated.instance_variable_set(:@db, database)
      allow(isolated).to receive(:tables).and_return(['_MxrbFileTransaction'])
      isolated.send(:clear_v2_transaction_marker!, 'id')
      expect(database).not_to have_received(:execute).with('DROP TABLE _MxrbFileTransaction')
    end
  end

  it 'keeps an existing Studio transaction id and rejects invalid backup databases' do
    isolated = described_class.allocate
    isolated.instance_variable_set(:@format_version, :v2)
    isolated.instance_variable_set(:@readonly, false)
    database = double
    allow(database).to receive(:execute)
    allow(database).to receive(:get_first_value).and_return('existing-id')
    isolated.instance_variable_set(:@db, database)
    allow(isolated).to receive(:write_mpr_name!)
    expect(isolated.ensure_v2_contract!).to equal(isolated)
    expect(database).not_to have_received(:execute).with(
      'INSERT INTO _Transaction (LastTransactionID) VALUES (?)', anything
    )

    Dir.mktmpdir('mxrb-storage-backup-') do |directory|
      isolated.instance_variable_set(:@path, File.join(directory, 'Storage.mpr'))
      expect { isolated.send(:preflight_backup!, File.join(directory, 'missing.mpr')) }
        .to raise_error(Mxrb::NotMprError, /not a valid SQLite file/)

      backup = File.join(directory, 'empty.mpr')
      db = SQLite3::Database.new(backup)
      db.close
      expect { isolated.send(:preflight_backup!, backup) }
        .to raise_error(Mxrb::NotMprError)
    end
  end

  it 'commits an empty v2 transaction and recognizes committed recovery journals' do
    Dir.mktmpdir('mxrb-storage-commit-') do |directory|
      isolated = described_class.allocate
      isolated.instance_variable_set(:@path, File.join(directory, 'Storage.mpr'))
      isolated.instance_variable_set(:@write_stats, { inserted: 0, updated: 0, deleted: 0 })
      database = double
      allow(database).to receive(:transaction).and_yield
      allow(database).to receive(:execute)
      allow(database).to receive(:get_first_value).and_return(1)
      isolated.instance_variable_set(:@db, database)
      allow(isolated).to receive(:cleanup_v2_transaction!)
      allow(isolated).to receive(:clear_v2_transaction_marker!)
      expect(isolated.send(:with_v2_transaction) { :done }).to eq(:done)

      journal = isolated.send(:transaction_journal_dir)
      FileUtils.mkdir_p(journal)
      File.write(
        isolated.send(:transaction_manifest_path),
        JSON.generate('id' => 'committed', 'entries' => [])
      )
      isolated.instance_variable_set(:@readonly, false)
      allow(isolated).to receive(:tables).and_return(['_MxrbFileTransaction'])
      allow(isolated).to receive(:restore_interrupted_v2_files!)
      isolated.send(:recover_interrupted_v2_transaction!)
      expect(isolated).not_to have_received(:restore_interrupted_v2_files!)
    end
  end

  it 'leaves an existing interrupted file untouched when its backup is missing' do
    Dir.mktmpdir('mxrb-storage-restore-existing-') do |directory|
      isolated = described_class.allocate
      contents = File.join(directory, 'contents')
      isolated.instance_variable_set(:@path, File.join(directory, 'Storage.mpr'))
      allow(isolated).to receive(:contents_dir).and_return(contents)
      relative = File.join('aa', 'unit.mxunit')
      live = File.join(contents, relative)
      FileUtils.mkdir_p(File.dirname(live))
      File.write(live, 'current')
      isolated.send(:restore_interrupted_v2_files!, [
                      { 'relative_path' => relative, 'existed' => true }
                    ])
      expect(File.read(live)).to eq('current')
    end
  end

  it 'cleans failed migration stages and validates backup table structure' do
    Dir.mktmpdir('mxrb-storage-stage-') do |directory|
      isolated = described_class.allocate
      contents = File.join(directory, 'Storage.mprcontents')
      allow(isolated).to receive(:contents_dir).and_return(contents)
      allow(Mxrb::IO::MxunitCodec).to receive(:write_atomic) do |path, _bytes|
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, 'staged')
      end
      allow(isolated).to receive(:rebuild_storage_tables!).and_raise('conversion failed')
      row = [Mxrb::IO::BsonCodec.uuid_to_blob(SecureRandom.uuid), nil, nil, nil, nil, nil, 'bytes']
      expect { isolated.send(:migrate_units_to_v2!, [row]) }
        .to raise_error(RuntimeError, /conversion failed/)
      expect(Dir.glob("#{contents}.mxrb-convert-*")).to be_empty

      backup = File.join(directory, 'other-table.mpr')
      database = SQLite3::Database.new(backup)
      database.execute('CREATE TABLE Other (Value TEXT)')
      database.close
      expect { isolated.send(:preflight_backup!, backup) }
        .to raise_error(Mxrb::NotMprError, /Unit table missing/)
    end
  end

  it 'does not roll back a database transaction after its commit succeeds' do
    isolated = described_class.allocate
    isolated.instance_variable_set(:@write_stats, { inserted: 0, updated: 0, deleted: 0 })
    database = double(transaction: nil)
    allow(database).to receive(:transaction).and_yield
    isolated.instance_variable_set(:@db, database)
    allow(isolated).to receive(:apply_v2_transaction!)
    allow(isolated).to receive(:cleanup_v2_transaction!)
    allow(isolated).to receive(:rollback_v2_transaction!)
    allow(isolated).to receive(:clear_v2_transaction_marker!).and_raise('marker cleanup failed')

    expect { isolated.send(:with_v2_transaction) { :done } }
      .to raise_error(RuntimeError, /marker cleanup failed/)
    expect(isolated).not_to have_received(:rollback_v2_transaction!)
  end
end
