# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/files'
require 'tmpdir'

RSpec.describe Mxrb::Studio::Files do # rubocop:disable Metrics/BlockLength
  around do |example|
    Dir.mktmpdir('mxrb-studio-files-') do |directory|
      @directory = directory
      @old_state = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'state')
      @root = File.join(directory, 'workspace')
      Dir.mkdir(@root)
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = @old_state
    end
  end

  subject(:files) { described_class.new(@root) }

  def write_fixture(path, text = 'original')
    File.write(File.join(@root, path), text)
  end

  def git(*arguments)
    output, error, status = Open3.capture3('git', '-C', @root, *arguments)
    raise error unless status.success?

    output
  end

  it 'lists files and folders with Unicode paths, folders first, hiding generated folders and symlinks' do
    %w[Árvore beta .git node_modules vendor .bundle coverage].each { Dir.mkdir(File.join(@root, _1)) }
    write_fixture('z.rb')
    write_fixture('a.rb')
    File.symlink(File.join(@root, 'a.rb'), File.join(@root, 'link.rb'))

    expect(files.list.map { _1[:name] }).to eq(%w[beta Árvore a.rb z.rb])
    expect(files.list.first).to include(path: 'beta', directory: true)
    expect(files.list('Árvore')).to eq([])
    names = files.list('.', include_ignored: true).map { _1[:name] }
    expect(names).to include('vendor', 'node_modules', '.bundle', 'coverage')
    expect(files.list('.', include_ignored: true).map { _1[:name] }).not_to include('.git')
  end

  it 'creates, reads and atomically saves UTF-8 text with a content revision' do
    files.create('Módulo', directory: true)
    files.create('Módulo/ação.rb', text: "puts 'Olá 🐧'\n")
    current = files.read('Módulo/ação.rb')
    expect(current).to include(path: 'Módulo/ação.rb', text: "puts 'Olá 🐧'\n")
    expect(current[:revision]).to eq(Digest::SHA256.hexdigest(current[:text]))
    saved = files.write('Módulo/ação.rb', text: "puts 'Novo'\n", revision: current[:revision])
    expect(files.read('Módulo/ação.rb')).to include(saved.merge(text: "puts 'Novo'\n"))
    expect(Dir.children(File.join(@root, 'Módulo'))).to eq(['ação.rb'])
  end

  it 'preserves executable permissions even with a restrictive process umask' do
    write_fixture('executable.rb')
    File.chmod(0o751, File.join(@root, 'executable.rb'))
    revision = files.read('executable.rb')[:revision]
    previous_umask = File.umask(0o077)
    begin
      files.write('executable.rb', text: 'new', revision:)
    ensure
      File.umask(previous_umask)
    end
    expect(File.stat(File.join(@root, 'executable.rb')).mode & 0o777).to eq(0o751)
  end

  it 'preserves the external file and the caller buffer on a revision conflict' do
    write_fixture('file.rb')
    revision = files.read('file.rb')[:revision]
    write_fixture('file.rb', 'external')
    buffer = 'unsaved editor buffer'
    expect { files.write('file.rb', text: buffer, revision:) }.to raise_error(Mxrb::Studio::Conflict)
    expect(File.read(File.join(@root, 'file.rb'))).to eq('external')
    expect(buffer).to eq('unsaved editor buffer')
    expect(Dir.children(@root)).to eq(['file.rb'])
  end

  it 'serializes independent writers so exactly one shared-revision write succeeds' do
    write_fixture('file.rb')
    revision = files.read('file.rb')[:revision]
    results = Queue.new
    threads = %w[first second].map do |text|
      Thread.new do
        described_class.new(@root).write('file.rb', text:, revision:)
        results << :saved
      rescue Mxrb::Studio::Conflict
        results << :conflict
      end
    end
    threads.each(&:join)
    expect(2.times.map { results.pop }).to contain_exactly(:saved, :conflict)
    expect(%w[first second]).to include(files.read('file.rb')[:text])
  end

  it 'detects an external edit during preparation and cleans its temporary file' do
    write_fixture('file.rb')
    revision = files.read('file.rb')[:revision]
    allow(files).to receive(:read_at).and_wrap_original do |original, *arguments|
      result = original.call(*arguments)
      write_fixture('file.rb', 'external') if result[:text] == 'original'
      result
    end
    expect { files.write('file.rb', text: 'editor', revision:) }.to raise_error(Mxrb::Studio::Conflict)
    expect(files.read('file.rb')[:text]).to eq('external')
    expect(Dir.children(@root)).to eq(['file.rb'])
  end

  it 'refuses overwrites when creating files or directories' do
    write_fixture('existing.rb')
    expect { files.create('existing.rb', text: 'replacement') }.to raise_error(Mxrb::Studio::Conflict)
    expect { files.create('existing.rb', directory: true) }.to raise_error(Mxrb::Studio::Conflict)
    expect(files.read('existing.rb')[:text]).to eq('original')
  end

  it 'moves files and directories without replacing any existing destination' do
    files.create('folder', directory: true)
    files.create('folder/file.rb', text: 'source')
    expect(files.move('folder', destination: 'Módulo')).to eq(path: 'Módulo', previous_path: 'folder')
    write_fixture('existing.rb', 'destination')
    expect { files.move('Módulo/file.rb', destination: 'existing.rb') }.to raise_error(Mxrb::Studio::Conflict)
    expect(files.read('Módulo/file.rb')[:text]).to eq('source')
    expect(files.read('existing.rb')[:text]).to eq('destination')
  end

  it 'uses an atomic no-replace move even when another process creates the destination just before rename' do
    write_fixture('source.rb')
    allow(files).to receive(:rename).and_wrap_original do |original, *arguments, **options|
      write_fixture('destination.rb', 'external')
      original.call(*arguments, **options)
    end
    expect { files.move('source.rb', destination: 'destination.rb') }.to raise_error(Mxrb::Studio::Conflict)
    expect(files.read('source.rb')[:text]).to eq('original')
    expect(files.read('destination.rb')[:text]).to eq('external')
  end

  it 'rejects absolute paths, traversal outside the root, NUL and workspace-root mutations' do
    [nil, '', '../outside', '/etc/passwd', "file\0.rb"].each do |path|
      expect { files.read(path) }.to raise_error(ArgumentError)
      expect { files.create(path) }.to raise_error(ArgumentError)
      expect { files.move(path, destination: 'file.rb') }.to raise_error(ArgumentError)
    end
    expect { files.create('.') }.to raise_error(ArgumentError)
    expect { files.move('.', destination: 'renamed') }.to raise_error(ArgumentError)
    expect { files.move('missing', destination: '..') }.to raise_error(ArgumentError)
  end

  it 'does not follow symlinks to files or directories, including broken links and destinations' do
    write_fixture('file.rb')
    Dir.mkdir(File.join(@directory, 'outside'))
    File.symlink(File.join(@root, 'file.rb'), File.join(@root, 'link.rb'))
    File.symlink(File.join(@directory, 'outside'), File.join(@root, 'outside'))
    File.symlink(File.join(@directory, 'missing'), File.join(@root, 'broken'))
    expect { files.read('link.rb') }.to raise_error(ArgumentError, /symlink/)
    expect { files.create('outside/new.rb') }.to raise_error(ArgumentError, /symlink/)
    expect { files.list('outside') }.to raise_error(ArgumentError, /symlink/)
    expect { files.move('link.rb', destination: 'moved.rb') }.to raise_error(ArgumentError, /symlink/)
    expect { files.move('file.rb', destination: 'broken') }.to raise_error(Mxrb::Studio::Conflict)
    expect { files.write('link.rb', text: 'bad', revision: 'anything') }.to raise_error(ArgumentError, /symlink/)
    expect(files.read('file.rb')[:text]).to eq('original')
    expect(Dir.children(File.join(@directory, 'outside'))).to eq([])
  end

  it 'anchors a write to its opened directory if an external process replaces the parent with a symlink' do
    files.create('folder', directory: true)
    files.create('folder/file.rb', text: 'inside')
    revision = files.read('folder/file.rb')[:revision]
    outside = File.join(@directory, 'outside')
    Dir.mkdir(outside)
    File.write(File.join(outside, 'file.rb'), 'outside')
    changed = false
    allow(files).to receive(:read_at).and_wrap_original do |original, *arguments|
      result = original.call(*arguments)
      unless changed
        File.rename(File.join(@root, 'folder'), File.join(@root, 'old-folder'))
        File.symlink(outside, File.join(@root, 'folder'))
        changed = true
      end
      result
    end
    files.write('folder/file.rb', text: 'editor', revision:)
    expect(File.read(File.join(outside, 'file.rb'))).to eq('outside')
    expect(File.read(File.join(@root, 'old-folder', 'file.rb'))).to eq('editor')
  end

  it 'rejects binary, NUL, incompatible encodings and oversized buffers without changing the existing file' do
    write_fixture('file.rb')
    revision = files.read('file.rb')[:revision]
    invalid = ["\xFF".b, "a\0b", 'hello'.encode('UTF-16LE'), 'x' * (described_class::MAXIMUM_BYTES + 1)]
    invalid.each do |text|
      expect { files.write('file.rb', text:, revision:) }.to raise_error(ArgumentError)
      expect { files.create('new.rb', text:) }.to raise_error(ArgumentError)
    end
    expect(files.read('file.rb')[:text]).to eq('original')
    expect(File.exist?(File.join(@root, 'new.rb'))).to be(false)
  end

  it 'rejects existing binary and oversized files and does not block on a FIFO' do
    File.binwrite(File.join(@root, 'binary'), "\xFF".b)
    File.binwrite(File.join(@root, 'nul'), "a\0b")
    File.binwrite(File.join(@root, 'large'), 'x' * (described_class::MAXIMUM_BYTES + 1))
    File.mkfifo(File.join(@root, 'fifo'))
    %w[binary nul large fifo].each { |path| expect { files.read(path) }.to raise_error(ArgumentError) }
    expect(files.list.map { _1[:name] }).not_to include('fifo')
  end

  it 'allows a buffer exactly at the byte limit and UTF-8 bytes tagged as binary' do
    text = 'x' * described_class::MAXIMUM_BYTES
    files.create('limit.rb', text:)
    expect(files.read('limit.rb')[:text]).to eq(text)
    bytes = 'Olá'.b
    files.create('unicode.rb', text: bytes)
    expect(files.read('unicode.rb')[:text]).to eq('Olá')
    expect(bytes.encoding).to eq(Encoding::ASCII_8BIT)
  end

  it 'returns no worktrees when the workspace is not a Git repository' do
    expect(files.worktrees).to eq([])
  end

  it 'lists real local Git worktrees with Unicode, branch, head and current markers' do
    git('init', '--initial-branch=main')
    git('-c', 'user.name=Studio Test', '-c', 'user.email=studio@example.invalid',
        'commit', '--allow-empty', '-m', 'Initial')
    other = File.join(@directory, 'árvore de trabalho')
    git('worktree', 'add', '-b', 'feature', other)
    entries = files.worktrees
    expect(entries).to contain_exactly(
      include(path: @root, branch: 'refs/heads/main', current: true, detached: false),
      include(path: other, branch: 'refs/heads/feature', current: false, detached: false)
    )
    expect(entries.map { _1[:head] }).to eq([git('rev-parse', 'HEAD').strip] * 2)
    expect(described_class.new(other).worktrees.find { _1[:path] == other }[:current]).to be(true)
    FileUtils.remove_entry(other)
    expect(files.worktrees.map { _1[:path] }).to include(@root, other)
  end

  it 'requires Linux x86_64 or aarch64 for atomic renames' do
    rename = described_class.const_get(:NativeRename)
    stub_const('RUBY_PLATFORM', 'arm64-darwin23')
    expect { rename.call }.to raise_error(NotImplementedError, /require Linux/)
    stub_const('RUBY_PLATFORM', 'riscv64-linux')
    stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_cpu' => 'riscv64'))
    expect { rename.call }.to raise_error(NotImplementedError, /x86_64 or aarch64/)
  end

  it 'rejects a file as workspace root, a file as directory and absolute paths' do
    write_fixture('plain.rb')
    expect { described_class.new(File.join(@root, 'plain.rb')) }.to raise_error(ArgumentError, /must be a directory/)
    expect { files.list('plain.rb') }.to raise_error(ArgumentError, /not a directory/)
    expect { files.list('/etc') }.to raise_error(ArgumentError, /relative/)
  end

  it 'skips entries removed while they are listed' do
    write_fixture('kept.rb')
    write_fixture('gone.rb')
    allow(File).to receive(:lstat).and_call_original
    allow(File).to receive(:lstat).with(end_with('/gone.rb')).and_raise(Errno::ENOENT)
    expect(files.list.map { _1[:name] }).to eq(['kept.rb'])
  end

  it 'reports no worktrees outside git, without git, and ignores blocks without a worktree' do
    expect(files.worktrees).to eq([])
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return(["bare\0\0worktree #{@root}\0HEAD abc\0detached\0\0", '', status])
    expect(files.worktrees).to eq([{ path: @root, branch: nil, head: 'abc', detached: true, current: true }])
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    expect(files.worktrees).to eq([])
  end
end
