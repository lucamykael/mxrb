# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/sync_preview'
require 'rbconfig'
require 'tmpdir'

# Failure paths of the isolated preview that a real project rarely reaches.
# rubocop:disable Metrics
RSpec.describe 'Studio preview branch contracts' do
  around do |example|
    Dir.mktmpdir('mxrb-preview-branches-') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:context) { Mxrb::Studio::RequestContext.new }

  describe Mxrb::Studio::PreviewSandbox do
    let(:sandbox) { described_class.new(context:, model_name: 'App.mpr') }
    let(:workspace) { File.join(@directory, 'worker') }

    def run_worker(*arguments)
      allow(sandbox).to receive(:command).and_return(arguments)
      sandbox.generate(workspace)
    end

    it 'reports missing isolation tooling as unavailable' do
      expect { run_worker(File.join(@directory, 'missing-bwrap')) }
        .to raise_error(Mxrb::Studio::PreviewIsolationUnavailable, /isolation is unavailable/)
    end

    it 'reports a sandbox that could not start with its diagnostic output' do
      expect { run_worker(RbConfig.ruby, '-e', 'warn "bwrap: setting up uid map: Permission denied"; exit 1') }
        .to raise_error(Mxrb::Studio::PreviewIsolationUnavailable, /could not start: bwrap: setting up uid map/)
    end

    it 'distinguishes a worker that started but wrote no result' do
      expect { run_worker(RbConfig.ruby, '-e', 'File.write(ARGV[0], "")', File.join(workspace, 'worker-started')) }
        .to raise_error(Mxrb::Studio::RubySourceError, /ended without a result \(status 0\)/)
    end

    it 'requires the generated model even when the worker reports success' do
      expect do
        run_worker(RbConfig.ruby, '-e', 'File.write(ARGV[0], %({"ok":true}))', File.join(workspace, 'result.json'))
      end.to raise_error(Mxrb::Studio::RubySourceError, 'generated model must be a regular file')
    end

    it 'stops a worker that exceeds the output limit' do
      expect { run_worker(RbConfig.ruby, '-e', 'STDOUT.write("x" * 200_000); STDOUT.flush; sleep 5') }
        .to raise_error(Mxrb::Studio::RubySourceError, /exceeded its output limit/)
    end

    it 'waits on a stream that has no data yet and tolerates an already finished process group' do
      reader, writer = IO.pipe
      streams = [reader]
      expect(sandbox.send(:drain, reader, streams, +'')).to be_nil
      expect(streams).to eq([reader])
      pid = Process.spawn(RbConfig.ruby, '-e', 'exit 0', pgroup: true)
      Process.wait(pid)
      expect(sandbox.send(:terminate, pid)).to be_nil
    ensure
      reader&.close
      writer&.close
    end

    it 'binds real system directories and skips absent ones' do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/sbin').and_return(false)
      allow(File).to receive(:exist?).with('/bin').and_return(true)
      allow(File).to receive(:symlink?).and_call_original
      allow(File).to receive(:symlink?).with('/bin').and_return(false)
      links = sandbox.send(:system_links)
      expect(links.each_slice(3).to_a).to include(['--ro-bind', '/bin', '/bin'])
      expect(links).not_to include('/sbin')
    end
  end

  describe Mxrb::Studio::PreviewSources do
    let(:root) { File.join(@directory, 'ruby') }

    def write(relative, text)
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    def revision(directory = root) = described_class.new(directory, context:).revision

    it 'ignores dependency, build and private MXRB directories' do
      write('app/flow.rb', 'flow')
      plain = revision
      write('.git/HEAD', 'ref')
      write('node_modules/package/index.ts', 'export {}')
      write('.mxrb-preview/cache.rb', 'cache')
      expect(revision).to eq(plain)
    end

    it 'limits the number and size of copied sources' do
      write('a.rb', '1234567890')
      write('b.rb', 'b')
      stub_const('Mxrb::Studio::PreviewSources::MAXIMUM_FILES', 1)
      expect { revision }.to raise_error(ArgumentError, /exceeds 25000 source files/)
      stub_const('Mxrb::Studio::PreviewSources::MAXIMUM_FILES', 10)
      stub_const('Mxrb::Studio::PreviewSources::MAXIMUM_BYTES', 4)
      expect { revision }.to raise_error(ArgumentError, /exceeds 512 MiB/)
    end

    it 'refuses special files' do
      FileUtils.mkdir_p(root)
      File.mkfifo(File.join(root, 'pipe'))
      expect { revision }.to raise_error(ArgumentError, 'Ruby preview requires regular source files: pipe')
    end
  end

  describe Mxrb::Studio::PreviewComparison do
    let(:before) do
      path = File.join(@directory, 'before', 'App.mpr')
      FileUtils.mkdir_p(File.dirname(path))
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Shop) do
          entity(:Product) do
            string :Name
            integer :Count
          end
          microflow(:Moved) { log_message 'moved' }
          microflow(:Removed) { log_message 'removed' }
        end
      end
      path
    end
    let(:after) do
      path = File.join(@directory, 'after', 'App.mpr')
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.cp(before, path)
      path
    end

    def units_of_type(mpr, type)
      mpr.all_units.select { mpr.parse_contents(_1)['$Type'] == type }
    end

    def edit_after
      mpr = Mxrb::IO::MprFile.open(after)
      yield mpr
    ensure
      mpr&.close
    end

    it 'reports added, removed, moved and structurally changed units' do
      edit_after do |mpr|
        flows = units_of_type(mpr, 'Microflows$Microflow').to_h { [mpr.parse_contents(_1)['Name'], _1] }
        module_id = flows.fetch('Moved').fetch('ContainerID')
        folder = mpr.insert_unit(container_uuid: module_id, containment_name: 'Folders',
                                 contents_doc: { '$Type' => 'Projects$Folder', 'Name' => 'Archive' })
        mpr.relocate_unit(flows.fetch('Moved').fetch('UnitID'), container_uuid: folder, containment_name: 'Documents')
        mpr.delete_unit(flows.fetch('Removed').fetch('UnitID'))
        domain = units_of_type(mpr, 'DomainModels$DomainModel').first
        document = mpr.parse_contents(domain)
        entity = Array(document['Entities']).find { _1.is_a?(Hash) && _1['Name'] == 'Product' }
        entity['Attributes'] = entity['Attributes'].reject { _1.is_a?(Hash) && _1['Name'] == 'Count' }
        mpr.update_unit(domain.fetch('UnitID'), document)
      end
      units = described_class.new(before, after, context:).units
      expect(units).to include(
        include(type: 'Projects$Folder', name: 'Archive', action: 'added', changes: []),
        include(name: 'Removed', action: 'removed', changes: []),
        include(name: 'Moved', action: 'modified', changes: [include(op: 'move')]),
        include(type: 'DomainModels$DomainModel',
                changes: [include(op: 'remove', key: 'Attributes', before: include('Name' => 'Count'))])
      )
    end

    it 'falls back to replacing a document whose difference has no element operation' do
      edit_after do |mpr|
        domain = units_of_type(mpr, 'DomainModels$DomainModel').first
        document = mpr.parse_contents(domain)
        document['Documentation'] = 'changed'
        mpr.update_unit(domain.fetch('UnitID'), document)
      end
      allow(Mxrb::Studio::Structure).to receive(:diff).and_return([])
      domain = described_class.new(before, after, context:).units.find { _1[:type] == 'DomainModels$DomainModel' }
      expect(domain.fetch(:changes)).to contain_exactly(include(op: 'replace'))
    end
  end

  it 'returns stale when the private Ruby snapshot differs from the measured revision' do
    service = Mxrb::Studio::Service.new(state_root: File.join(@directory, 'state'))
    model = File.join(@directory, 'native', 'App.mpr')
    FileUtils.mkdir_p(File.dirname(model))
    Mxrb.define(model) { self.module(:Shop) { entity(:Product) { string :Name } } }
    service.dispatch('project/convert', { 'source_model' => model }, context)
    allow_any_instance_of(Mxrb::Studio::PreviewSources).to receive(:revision).and_wrap_original do |original, **options|
      options[:destination] ? '0' * 64 : original.call(**options)
    end
    expect_any_instance_of(Mxrb::Studio::PreviewSandbox).not_to receive(:generate)
    expect(service.dispatch('sync/preview', { 'source_model' => model }, context))
      .to include(state: 'stale', reason: 'snapshot_changed', applied: false)
  end
end
# rubocop:enable Metrics
