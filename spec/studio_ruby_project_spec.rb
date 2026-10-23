# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/ruby_project'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::RubyProject do
  around do |example|
    Dir.mktmpdir('mxrb-ruby-explorer-') do |directory|
      @directory = directory
      @state_root = File.join(directory, 'state')
      example.run
    end
  end

  def model_at(relative = 'native/project.mpr', format: :v1)
    path = File.join(@directory, relative)
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) { entity(:Product) { string :Name } }
    end
    Mxrb.open(path, readonly: false) { _1.mpr.migrate_storage_format!(:v2) } if format == :v2
    path
  end

  def identity(path)
    Mxrb.open(path) { _1.mpr.root_unit.fetch('UnitID') }
  end

  def write_ruby(path, project_id, suffix: '')
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'project.rb'), <<~RUBY)
      require 'mxrb'
      Mxrb.define('output.mpr') do
        mendix_project_id #{project_id.inspect}
      end
      #{suffix}
    RUBY
    path
  end

  def files_below(root)
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).select { File.file?(_1) }.to_h do |path|
      [path.delete_prefix(root), File.binread(path)]
    end
  end

  it 'returns a missing representation without evaluating nearby Ruby' do
    path = model_at
    marker = File.join(@directory, 'must-not-execute')
    write_ruby(File.join(File.dirname(path), 'ruby'), SecureRandom.uuid,
               suffix: "File.write(#{marker.inspect}, 'executed')")
    expect(described_class.new(path, state_root: @state_root).status).to eq(
      source_model: File.realpath(path), root: nil, entrypoint: nil, state: 'missing', discovered: false
    )
    expect(File).not_to exist(marker)
  end

  it 'discovers sibling ruby beside model, persists it, and reopens using a canonical source path' do
    path = model_at('workspace/model/Sudoku.mpr')
    root = write_ruby(File.join(@directory, 'workspace/ruby'), identity(path))
    expected = { source_model: File.realpath(path), root:, entrypoint: File.join(root, 'project.rb'),
                 state: 'ready', discovered: true }
    expect(described_class.new(path, state_root: @state_root).status).to eq(expected)
    link = File.join(@directory, 'alias.mpr')
    File.symlink(path, link)
    expect(described_class.new(link, state_root: @state_root).status).to eq(expected)
    bindings = Dir.glob(File.join(@state_root, 'ruby-projects', '*.json'))
    expect(bindings.length).to eq(1)
    expect(File.stat(bindings.first).mode & 0o777).to eq(0o600)
  end

  it 'attaches another worktree of the same identity and preserves all Ruby content' do
    path = model_at
    marker = File.join(@directory, 'must-not-run')
    root = write_ruby(File.join(@directory, 'worktrees/branch'), identity(path),
                      suffix: "File.write(#{marker.inspect}, 'executed')")
    before = files_below(root)
    attached = described_class.new(path, state_root: @state_root).attach(root:)
    expect(attached).to include(state: 'ready', root:, discovered: false)
    expect(described_class.new(path, state_root: @state_root).status).to eq(attached)
    expect(files_below(root)).to eq(before)
    expect(File).not_to exist(marker)
  end

  it 'refuses different projects, missing IDs, comments, dynamic declarations and multiple declarations' do
    path = model_at
    editor = described_class.new(path, state_root: @state_root)
    candidate = File.join(@directory, 'candidate')
    FileUtils.mkdir_p(candidate)
    id = identity(path)
    invalid = ["# mendix_project_id #{id.inspect}\n", "mendix_project_id ENV.fetch('PROJECT_ID')\n",
               "mendix_project_id #{SecureRandom.uuid.inspect}\n",
               "mendix_project_id #{id.inspect}\nmendix_project_id #{id.inspect}\n", 'def broken(']
    invalid.each do |source|
      File.write(File.join(candidate, 'project.rb'), source)
      expect { editor.attach(root: candidate) }.to raise_error(ArgumentError)
      expect(editor.status[:state]).to eq('missing')
    end
  end

  it 'accepts a literal declaration with parentheses without evaluating the program' do
    path = model_at
    root = File.join(@directory, 'parenthesized')
    FileUtils.mkdir_p(root)
    File.write(File.join(root, 'project.rb'), "mendix_project_id(#{identity(path).inspect})\nraise 'never evaluate'\n")
    expect(described_class.new(path, state_root: @state_root).attach(root:)[:state]).to eq('ready')
  end

  %i[v1 v2].each do |format|
    it "converts a real #{format} snapshot once and preserves both the saved model and existing Ruby edits" do
      path = model_at(format:)
      before = files_below(File.dirname(path))
      copy = Mxrb::Studio::Snapshot.new(path, destination_root: File.join(@directory, 'snapshots')).create
      Dir.glob(File.join(copy[:root], '**', '*'), File::FNM_DOTMATCH).select { File.file?(_1) }
         .each { File.chmod(0o444, _1) }
      snapshot_before = files_below(copy[:root])
      project = described_class.new(path, state_root: @state_root)
      result = project.convert(model: copy[:model])
      expect(result).to include(state: 'ready', discovered: false)
      expect(result[:root]).to start_with(File.join(@state_root, 'ruby-conversions'))
      expect(File.read(result[:entrypoint])).to include("mendix_project_id #{identity(path).inspect}")
      expect(File).to exist(File.join(result[:root], 'modules', 'Shop', 'module.rb'))
      File.write(result[:entrypoint], "#{File.read(result[:entrypoint])}\n# user edit preserved\n")
      ruby_before = files_below(result[:root])
      expect(project.convert(model: copy[:model])).to eq(result)
      expect(described_class.new(path, state_root: @state_root).status).to eq(result)
      expect(files_below(result[:root])).to eq(ruby_before)
      expect(files_below(copy[:root])).to eq(snapshot_before)
      expect(files_below(File.dirname(path))).to eq(before)
    end
  end

  it 'takes a private snapshot when no model is supplied for conversion' do
    path = model_at
    before = files_below(File.dirname(path))
    expect(described_class.new(path, state_root: @state_root).convert).to include(state: 'ready')
    expect(files_below(File.dirname(path))).to eq(before)
  end

  it 'rejects a conversion snapshot from another project without publishing a link' do
    path = model_at
    other = model_at('another/other.mpr')
    editor = described_class.new(path, state_root: @state_root)
    expect { editor.convert(model: other) }.to raise_error(ArgumentError, /different Mendix project/)
    expect(editor.status[:state]).to eq('missing')
    expect(Dir.glob(File.join(@state_root, 'ruby-projects', '*.json'))).to be_empty
  end

  it 'cleans only its failed output and preserves pre-existing conversions and Ruby files' do
    path = model_at
    preserved = File.join(@state_root, 'ruby-conversions', 'pre-existing')
    FileUtils.mkdir_p(preserved)
    File.write(File.join(preserved, 'keep.rb'), '# preserve')
    before = files_below(preserved)
    allow_any_instance_of(Mxrb::Exporter).to receive(:export!) do |exporter|
      output = exporter.instance_variable_get(:@output_dir)
      FileUtils.mkdir_p(output)
      File.write(File.join(output, 'partial.rb'), 'incomplete')
      raise 'export failed'
    end
    editor = described_class.new(path, state_root: @state_root)
    expect { editor.convert }.to raise_error(RuntimeError, 'export failed')
    expect(editor.status[:state]).to eq('missing')
    expect(Dir.children(File.join(@state_root, 'ruby-conversions'))).to eq(['pre-existing'])
    expect(files_below(preserved)).to eq(before)
  end

  it 'wires all three actions into the framework-neutral backend' do
    path = model_at
    backend = Mxrb::Studio::Backend.new
    common = { 'source_model' => path, 'state_root' => @state_root }
    expect(backend.call(common.merge('action' => 'ruby_project_status'))[:state]).to eq('missing')
    converted = backend.call(common.merge('action' => 'ruby_project_convert'))
    expect(converted[:state]).to eq('ready')
    expect(backend.call(common.merge('action' => 'ruby_project_attach', 'root' => converted[:root])))
      .to eq(converted)
  end
  it 'rejects a directory or a non-MPR file as source model' do
    expect { described_class.new(@directory, state_root: @state_root) }.to raise_error(ArgumentError, /must be a file/)
    text = File.join(@directory, 'notes.mpr')
    File.write(text, 'not sqlite')
    expect { described_class.new(text, state_root: @state_root).send(:project_id, text) }.to raise_error(StandardError)
  end

  it 'falls back to discovery when the bound root disappears or the binding is unreadable' do
    path = model_at
    root = write_ruby(File.join(@directory, 'bound'), identity(path))
    editor = described_class.new(path, state_root: @state_root)
    editor.attach(root:)
    FileUtils.rm_rf(root)
    expect(editor.status[:state]).to eq('missing')
    binding = Dir.glob(File.join(@state_root, 'ruby-projects', '*.json')).first
    File.write(binding, '[]')
    expect(editor.status[:state]).to eq('missing')
    File.write(binding, '{')
    expect(editor.status[:state]).to eq('missing')
  end

  it 'refuses empty, file, escaping, oversized and forwarded-argument entrypoints' do
    path = model_at
    editor = described_class.new(path, state_root: @state_root)
    expect { editor.attach(root: '') }.to raise_error(ArgumentError, /directory path/)
    file = File.join(@directory, 'file-root')
    File.write(file, '')
    expect { editor.attach(root: file) }.to raise_error(ArgumentError, /must be a directory/)
    escaping = File.join(@directory, 'escaping')
    FileUtils.mkdir_p(escaping)
    outside = write_ruby(File.join(@directory, 'outside'), identity(path))
    File.symlink(File.join(outside, 'project.rb'), File.join(escaping, 'project.rb'))
    expect { editor.attach(root: escaping) }.to raise_error(ArgumentError, /inside the selected project/)
    large = File.join(@directory, 'large')
    FileUtils.mkdir_p(large)
    File.write(File.join(large, 'project.rb'), "# #{'x' * described_class::MAXIMUM_SOURCE_BYTES}\n")
    expect { editor.attach(root: large) }.to raise_error(ArgumentError, /exceeds 4 MiB/)
    forwarded = File.join(@directory, 'forwarded')
    FileUtils.mkdir_p(forwarded)
    File.write(File.join(forwarded, 'project.rb'), "def declare(...) = mendix_project_id(...)\n")
    expect { editor.attach(root: forwarded) }.to raise_error(ArgumentError, /one literal/)
  end

  it 'removes its temporary binding when publishing the link fails' do
    path = model_at
    root = write_ruby(File.join(@directory, 'link-fails'), identity(path))
    allow(File).to receive(:rename).and_raise(Errno::EACCES)
    expect { described_class.new(path, state_root: @state_root).attach(root:) }.to raise_error(Errno::EACCES)
    expect(Dir.glob(File.join(@state_root, 'ruby-projects', '*.tmp'), File::FNM_DOTMATCH)).to be_empty
  end
end
# rubocop:enable Metrics
