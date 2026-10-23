# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/snapshot'
require 'tmpdir'

# Snapshot tests use generated projects and an isolated state root only.
# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::Snapshot do
  around do |example|
    Dir.mktmpdir('mxrb-studio-snapshot-') do |directory|
      @directory = directory
      @source = File.join(directory, 'projeto com ação 🐧')
      @destination = File.join(directory, 'estado e cópias')
      Dir.mkdir(@source)
      previous = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'state')
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = previous
    end
  end

  def model(format = :v1)
    path = File.join(@source, 'Aplicação.mpr')
    Mxrb.define(path) { mendix_version '11.12.1' }
    mpr = Mxrb::IO::MprFile.open(path, apply_studio_compatibility: false)
    identifier = mpr.insert_unit(container_uuid: mpr.root_unit.fetch('UnitID'), containment_name: 'Documents',
                                 contents_doc: { '$Type' => 'Tests$Native', 'Name' => 'Preserved' })
    native = BSON::Document.new(
      'Name' => 'Unnormalized', '$Type' => 'Tests$Native', '$ID' => identifier,
      'Position' => { 'X' => 1, 'Y' => BSON::Int64.new(2) },
      'Binary' => BSON::Binary.new("\0\xFF".b, :user), 'Unknown' => [3, { 'Unrecognized' => 'ação' }]
    ).to_bson.to_s
    mpr.update_unit_bytes(identifier, native)
    mpr.migrate_storage_format!(:v2) if format == :v2
    path
  ensure
    mpr&.close
  end

  def source_bytes
    Dir.glob(File.join(@source, '**', '*'), File::FNM_DOTMATCH).filter_map do |path|
      next if File.symlink?(path) || !File.file?(path)

      [path, File.binread(path)]
    end.to_h
  end

  def units(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
    mpr.all_units.to_h { |raw| [raw.fetch('UnitID'), [raw, mpr.content_bytes(raw)]] }
  ensure
    mpr&.close
  end

  def create(path)
    described_class.new(path, destination_root: @destination).create
  end

  %i[v1 v2].each do |format|
    it "copies #{format} Unicode projects with exact native unit bytes, IDs, layouts, assets and untouched source" do
      path = model(format)
      %w[theme themesource widgets userlib javasource resources javascriptsource .mxrb].each do |name|
        directory = File.join(@source, name)
        Dir.mkdir(directory)
        File.binwrite(File.join(directory, 'ação.txt'), "\0asset 🐧".b)
      end
      Dir.mkdir(File.join(@source, '.git'))
      File.write(File.join(@source, '.git', 'unrelated'), 'must not copy')
      File.write(File.join(@source, '.env'), 'unrelated configuration')
      sidecar = "#{path}.mprcontents"
      Dir.mkdir(sidecar)
      File.binwrite(File.join(sidecar, 'original.mxunit'), 'original sidecar bytes')
      before = source_bytes
      original_units = units(path)
      result = create(path)
      expect(result).to include(source: path, format: format.to_s, units: original_units.length)
      expect(result[:fingerprint]).to match(/\A[0-9a-f]{64}\z/)
      expect(result[:root]).to start_with("#{@destination}/")
      expect(File.basename(result[:model])).to eq('Aplicação.mpr')
      expect(units(result[:model])).to eq(original_units)
      expect(File.binread(File.join(File.dirname(result[:model]), 'resources', 'ação.txt'))).to eq("\0asset 🐧".b)
      expect(File.binread(File.join("#{result[:model]}.mprcontents",
                                    'original.mxunit'))).to eq('original sidecar bytes')
      expect(File).not_to exist(File.join(File.dirname(result[:model]), '.git'))
      expect(File).not_to exist(File.join(File.dirname(result[:model]), '.env'))
      expect(source_bytes).to eq(before)
      second = create(path)
      expect(second[:root]).not_to eq(result[:root])
      expect(units(result[:model])).to eq(original_units)
    end
  end

  it 'uses SQLite online backup to include committed data still present only in WAL' do
    path = model
    database = SQLite3::Database.new(path)
    database.execute('PRAGMA journal_mode = WAL')
    database.execute('PRAGMA wal_autocheckpoint = 0')
    database.execute('CREATE TABLE SnapshotWal (Name TEXT)')
    database.execute('INSERT INTO SnapshotWal VALUES (?)', ['committed Unicode 🐧'])
    expect(File).to exist("#{path}-wal")
    result = create(path)
    snapshot = SQLite3::Database.new(result[:model], flags: SQLite3::Constants::Open::READONLY)
    expect(snapshot.get_first_value('SELECT Name FROM SnapshotWal')).to eq('committed Unicode 🐧')
  ensure
    snapshot&.close
    database&.close
  end

  it 'does not follow asset symlinks or copy Git directories nested inside allowed assets' do
    path = model
    outside = File.join(@directory, 'outside')
    Dir.mkdir(outside)
    File.write(File.join(outside, 'external.txt'), 'external')
    File.symlink(outside, File.join(@source, 'theme'))
    Dir.mkdir(File.join(@source, 'resources'))
    File.symlink(File.join(outside, 'external.txt'), File.join(@source, 'resources', 'linked.txt'))
    Dir.mkdir(File.join(@source, 'resources', '.git'))
    File.write(File.join(@source, 'resources', '.git', 'config'), 'unrelated')
    File.write(File.join(@source, 'resources', 'normal.txt'), 'kept')
    result = create(path)
    copied = File.dirname(result[:model])
    expect(File).not_to exist(File.join(copied, 'theme'))
    expect(File).not_to exist(File.join(copied, 'resources', 'linked.txt'))
    expect(File).not_to exist(File.join(copied, 'resources', '.git'))
    expect(File.read(File.join(copied, 'resources', 'normal.txt'))).to eq('kept')
    expect(File.read(File.join(outside, 'external.txt'))).to eq('external')
  end

  it 'cleans only its private staging directory when required V2 contents are missing' do
    path = model(:v2)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true)
    missing = mpr.content_path(mpr.root_unit)
    mpr.close
    File.unlink(missing)
    FileUtils.mkdir_p(@destination)
    File.write(File.join(@destination, 'keep.txt'), 'unrelated')
    expect { create(path) }.to raise_error(Mxrb::IncompletePackageError)
    expect(Dir.children(@destination)).to eq(['keep.txt'])
    expect(File.read(File.join(@destination, 'keep.txt'))).to eq('unrelated')
    expect(File).not_to exist(missing)
  end

  it 'rejects native-unit symlinks and leaves no partial result' do
    path = model(:v2)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true)
    unit_path = mpr.content_path(mpr.root_unit)
    mpr.close
    outside = File.join(@directory, 'external.mxunit')
    File.rename(unit_path, outside)
    File.symlink(outside, unit_path)
    before = File.binread(outside)
    expect { create(path) }.to raise_error(ArgumentError, /symlinks/)
    expect(Dir.children(@destination)).to eq([])
    expect(File.binread(outside)).to eq(before)
  end

  it 'detects source unit changes while creating the copy and removes the inconsistent result' do
    path = model
    service = described_class.new(path, destination_root: @destination)
    allow(service).to receive(:copy_storage).and_wrap_original do |original, *arguments|
      original.call(*arguments)
      mpr = Mxrb::IO::MprFile.open(path, apply_studio_compatibility: false)
      root = mpr.root_unit
      contents = mpr.parse_contents(root)
      contents['Name'] = 'Saved by another editor'
      mpr.update_unit(root.fetch('UnitID'), contents)
      mpr.close
    end
    expect { service.create }.to raise_error(Mxrb::Studio::Conflict, /changed/)
    expect(Dir.children(@destination)).to eq([])
    mpr = Mxrb::IO::MprFile.open(path, readonly: true)
    expect(mpr.parse_contents(mpr.root_unit)['Name']).to eq('Saved by another editor')
  ensure
    mpr&.close unless mpr&.instance_variable_get(:@db)&.closed?
  end

  it 'rejects destinations nested inside source assets before starting a recursive copy' do
    path = model
    unsafe = File.join(@source, '.mxrb', 'snapshots')
    expect { described_class.new(path, destination_root: unsafe).create }
      .to raise_error(ArgumentError, /inside source assets/)
    expect(File).not_to exist(unsafe)
  end
end
# rubocop:enable Metrics
