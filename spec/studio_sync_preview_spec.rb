# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/sync_preview'
require 'tmpdir'

# These tests only use generated public fixtures in disposable directories.
# rubocop:disable Metrics
RSpec.describe 'Studio isolated Ruby compilation preview' do
  around do |example|
    Dir.mktmpdir('mxrb-sync-preview-spec-') do |directory|
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
        microflow(:Run) { log_message 'preview' }
      end
    end
    path
  end
  let(:root) { call('project/convert', 'source_model' => model).fetch(:root) }
  let(:product) { File.join(root, 'modules/Shop/domain/entities/product.rb') }

  def call(method, params, context = Mxrb::Studio::RequestContext.new)
    service.dispatch(method, params, context)
  end

  def preview(params = {}, context = Mxrb::Studio::RequestContext.new)
    call('sync/preview', { 'source_model' => model }.merge(params), context)
  end

  def hashes(directory)
    Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).select { File.file?(_1) }
       .to_h { [_1, Digest::SHA256.file(_1).hexdigest] }
  end

  def assert_real_preview(result)
    if result[:state] == 'unavailable' && result[:reason] == 'isolation_unavailable'
      skip "OS isolation unavailable in this test environment: #{result[:message]}"
    end
    expect(result).to include(state: 'ready', applied: false, comparison: 'saved_model_to_generated_ruby',
                              conflicts: { assessed: false, reason: 'no_sync_baseline' })
  end

  it 'advertises preview and requires a linked project without creating a synchronization base' do
    expect(service.methods_list).to include('sync/preview')
    expect(preview).to include(state: 'missing_project', applied: false, root: nil)
    expect(Dir.glob(File.join(state, 'sync', '*'))).to be_empty
  end

  %i[v1 v2].each do |format|
    it "compiles a Ruby copy and reports an attribute insertion with untouched #{format} originals" do
      if format == :v2
        mpr = Mxrb::IO::MprFile.open(model)
        mpr.migrate_storage_format!(:v2)
        mpr.close
      end
      File.write(product, File.read(product).sub('string :Name', 'string :Name; integer :Stock'))
      before_native = hashes(File.dirname(model))
      before_ruby = hashes(root)
      before_state = hashes(File.join(state, 'ruby-projects'))
      result = preview('root' => '/untrusted/root')
      assert_real_preview(result)
      expect(result[:root]).to eq(root)
      domain = result.fetch(:units).find { _1[:type] == 'DomainModels$DomainModel' }
      expect(domain).to include(action: 'modified')
      expect(domain.fetch(:changes)).to include(include(op: 'insert', after: include('Name' => 'Stock')))
      expect(hashes(File.dirname(model))).to eq(before_native)
      expect(hashes(root)).to eq(before_ruby)
      expect(hashes(File.join(state, 'ruby-projects'))).to eq(before_state)
      expect(Dir.glob(File.join(state, 'sync', '*'))).to be_empty
    ensure
      mpr&.close
    end
  end

  it 'does not expose original paths, personal credentials, parent secrets or the host network namespace' do
    root
    source = <<~RUBY
      raise 'parent environment leaked' if ENV.key?('MXRB_PREVIEW_TEST_SECRET')
      raise 'home credentials exposed' if File.exist?(#{File.join(Dir.home, '.aws').inspect})
      raise 'agent credentials exposed' if File.exist?(#{File.join(Dir.home, '.codex').inspect})
      raise 'host network namespace shared' if File.readlink('/proc/self/ns/net') == #{File.readlink('/proc/self/ns/net').inspect}
      begin
        File.write(#{model.inspect}, 'must never reach the saved model')
        raise 'native source path writable'
      rescue Errno::ENOENT, Errno::EROFS, Errno::EACCES
      end
      begin
        File.write(#{product.inspect}, 'must never reach the linked Ruby')
        raise 'linked Ruby path writable'
      rescue Errno::ENOENT, Errno::EROFS, Errno::EACCES
      end
    RUBY
    File.open(File.join(root, 'project.rb'), 'a') { _1.write(source) }
    before = hashes(@directory)
    previous = ENV.fetch('MXRB_PREVIEW_TEST_SECRET', nil)
    ENV['MXRB_PREVIEW_TEST_SECRET'] = 'not-for-the-worker'
    assert_real_preview(preview)
    expect(hashes(@directory)).to eq(before)
  ensure
    ENV['MXRB_PREVIEW_TEST_SECRET'] = previous
  end

  it 'reports an unavailable sandbox without executing Ruby or falling back to a fork' do
    root
    allow_any_instance_of(Mxrb::Studio::PreviewSandbox).to receive(:generate)
      .and_raise(Mxrb::Studio::PreviewIsolationUnavailable, 'bubblewrap unavailable')
    before = hashes(@directory)
    expect(preview).to include(state: 'unavailable', reason: 'isolation_unavailable', applied: false)
    expect(hashes(@directory)).to eq(before)
  end

  it 'reports compiler normalization explicitly even for unchanged exported Ruby' do
    root
    result = preview
    assert_real_preview(result)
    domain = result.fetch(:units).find { _1[:type] == 'DomainModels$DomainModel' }
    expect(domain.fetch(:changes)).to include(include(key: 'IsRemote', before_present: false, after: false))
    expect(result.fetch(:limitations)).to include(/normalize native defaults/)
  end

  it 'cancels a running Ruby worker and removes its temporary workspace' do
    root
    File.open(File.join(root, 'project.rb'), 'a') do |file|
      file.puts "File.write('/work/entered', 'yes'); loop { sleep 0.05 }"
    end
    context = Mxrb::Studio::RequestContext.new
    workspace = nil
    canceller = nil
    allow_any_instance_of(Mxrb::Studio::PreviewSandbox).to receive(:generate).and_wrap_original do |original, directory|
      workspace = directory
      canceller = Thread.new do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until File.file?(File.join(directory, 'entered')) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.01
        end
        context.cancel!
      end
      original.call(directory)
    end
    before = hashes(@directory)
    result = preview({}, context)
    skip result[:message] if result[:reason] == 'isolation_unavailable'
    raise 'expected cancellation'
  rescue Mxrb::Studio::Cancelled
    expect(hashes(@directory)).to eq(before)
    expect(File).not_to exist(workspace)
  ensure
    canceller&.kill
    canceller&.join
  end

  it 'enforces the timeout even when Ruby closes both output streams' do
    root
    File.open(File.join(root, 'project.rb'), 'a') { _1.puts 'STDOUT.close; STDERR.close; sleep 30' }
    stub_const('Mxrb::Studio::PreviewSandbox::TIMEOUT', 0.5)
    before = hashes(@directory)
    result = preview
    skip result[:message] if result[:reason] == 'isolation_unavailable'
    raise 'expected timeout'
  rescue Mxrb::Studio::RubySourceError => e
    expect(e.message).to include('timed out')
    expect(hashes(@directory)).to eq(before)
  end

  it 'returns stale before compiling when the caller revisions no longer match' do
    root
    expect_any_instance_of(Mxrb::Studio::PreviewSandbox).not_to receive(:generate)
    expect(preview('expected_revisions' => { 'model' => '0' * 64, 'ruby' => '0' * 64 }))
      .to include(state: 'stale', reason: 'revision_changed', applied: false)
    expect { preview('expected_revisions' => { 'model' => 'bad' }) }.to raise_error(ArgumentError)
  end

  it 'detects Ruby or native edits made while compilation is running' do
    root
    allow_any_instance_of(Mxrb::Studio::PreviewSandbox).to receive(:generate).and_wrap_original do |original, workspace|
      generated = original.call(workspace)
      File.open(product, 'a') { _1.puts '# changed during preview' }
      documents = Mxrb::Studio::Documents.new(model)
      flow = documents.list.find { _1[:type] == 'Microflows$Microflow' }
      document = documents.read(flow.fetch(:unit_id))
      documents.patch(flow.fetch(:unit_id), revision: document.fetch(:revision),
                                            changes: [{ 'path' => ['Name'], 'value' => 'RenamedDuringPreview' }])
      generated
    end
    result = preview
    skip result[:message] if result[:reason] == 'isolation_unavailable'
    expect(result).to include(state: 'stale', applied: false)
    expect(result.dig(:current_revisions, 'ruby')).not_to eq(result.dig(:revisions, 'ruby'))
    expect(result.dig(:current_revisions, 'model')).not_to eq(result.dig(:revisions, 'model'))
    expect(File.read(product)).to end_with("# changed during preview\n")
  end

  it 'returns stale when the project is relinked without changing either original input' do
    alternative = File.join(@directory, 'other-ruby')
    FileUtils.cp_r(root, alternative)
    before_root = hashes(root)
    allow_any_instance_of(Mxrb::Studio::PreviewSandbox).to receive(:generate).and_wrap_original do |original, workspace|
      generated = original.call(workspace)
      call('project/attach', 'source_model' => model, 'root' => alternative)
      generated
    end
    result = preview
    skip result[:message] if result[:reason] == 'isolation_unavailable'
    expect(result).to include(state: 'stale', reason: 'linked_project_changed', root:, current_root: alternative)
    expect(hashes(root)).to eq(before_root)
    expect(call('project/status', 'source_model' => model)).to include(root: alternative)
  end

  it 'can inspect a discovered Ruby root without persisting a new binding' do
    discovered = File.join(File.dirname(model), 'ruby')
    FileUtils.cp_r(root, discovered)
    bindings = File.join(state, 'ruby-projects')
    Dir.glob(File.join(bindings, '*.json')).each { File.unlink(_1) }
    allow_any_instance_of(Mxrb::Studio::PreviewSandbox).to receive(:generate)
      .and_raise(Mxrb::Studio::PreviewIsolationUnavailable, 'test isolation unavailable')
    expect(preview).to include(root: discovered, state: 'unavailable')
    expect(Dir.glob(File.join(bindings, '*.json'))).to be_empty
  end

  it 'reports Ruby source locations without changing originals when the copy fails to evaluate' do
    root
    File.open(product, 'a') { _1.puts "raise 'preview-fixture-failure'" }
    before = hashes(@directory)
    result = preview
    skip result[:message] if result[:reason] == 'isolation_unavailable'
    raise 'expected RubySourceError'
  rescue Mxrb::Studio::RubySourceError => e
    expect(e.message).to include('preview-fixture-failure')
    expect(e.locations).to include(include(file: 'modules/Shop/domain/entities/product.rb'))
    expect(hashes(@directory)).to eq(before)
  end

  it 'rejects source symlinks instead of reading through them' do
    root
    outside = File.join(@directory, 'outside.rb')
    File.write(outside, 'raise "never execute"')
    File.symlink(outside, File.join(root, 'outside.rb'))
    expect { preview }.to raise_error(ArgumentError, /source symlinks/)
  end

  it 'cancels before taking snapshots or evaluating the Ruby project' do
    context = Mxrb::Studio::RequestContext.new
    context.cancel!
    expect { preview({}, context) }.to raise_error(Mxrb::Studio::Cancelled)
  end
end
# rubocop:enable Metrics
