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
end
