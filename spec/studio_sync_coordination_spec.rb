# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio'
require 'mxrb/studio/sync'
require 'mxrb/studio/model_operations'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe 'Studio synchronization coordination' do
  around do |example|
    Dir.mktmpdir('mxrb-sync-coordination-') do |directory|
      @directory = directory
      original = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'xdg')
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = original
    end
  end

  let(:state_root) { File.join(@directory, 'state') }
  let(:model) { create_model }
  let(:ruby) { export(model) }
  let(:sync) { sync_with(:process) }

  def sync_with(isolation)
    Mxrb::Studio::Sync.new(model, ruby_root: ruby, state_root:, isolation:)
  end

  def create_model
    path = File.join(@directory, 'app', 'Shop.mpr')
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) do
        entity(:Product) do
          string :Name
          integer :Stock
        end
        entity(:Order) { decimal :Total }
        microflow(:Recalculate) { return_value 'empty' }
      end
    end
    path
  end

  def export(path)
    destination = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(path, destination, mode: :mendix).export!(parallel: false)
    destination
  end

  def product_file = File.join(ruby, 'modules/Shop/domain/entities/product.rb')
  def order_file = File.join(ruby, 'modules/Shop/domain/entities/order.rb')
  def edit(path) = File.write(path, yield(File.read(path)))

  def add_attribute(entity, name)
    editor = Mxrb::Studio::ModelOperations.new(model, workspace_root: @directory)
    editor.apply({ 'operation' => 'add_attribute', 'target' => "Shop.#{entity}", 'name' => name,
                   'type' => 'string' }, revision: editor.revision)
  end

  def native_bytes
    mpr = Mxrb::IO::MprFile.open(model, readonly: true, apply_studio_compatibility: false)
    mpr.all_units.to_h { [_1.fetch('UnitID'), mpr.content_bytes(_1)] }
  ensure
    mpr&.close
  end

  def attributes(entity)
    Mxrb.open(model) { |project| project.entities.find { _1.name == entity }.attributes.map(&:name) }
  end

  def domain_model_id
    mpr = Mxrb::IO::MprFile.open(model, readonly: true, apply_studio_compatibility: false)
    mpr.all_units.find { mpr.parse_contents(_1)['$Type'] == 'DomainModels$DomainModel' }.fetch('UnitID')
  ensure
    mpr&.close
  end

  describe 'revisions' do
    it 'reports the compared revisions and refuses to apply anything else' do
      sync.link!
      edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
      compared = sync.run(dry_run: true)
      expect(compared).to include(applied: false, state: 'pending')
      expect(compared[:revisions]).to eq(sync.status[:revisions])
      expect(compared[:revisions].values).to all(match(/\A[0-9a-f]{64}\z/))

      add_attribute('Order', 'Note')
      before = native_bytes
      expect { sync.run(expected_revisions: compared[:revisions]) }
        .to raise_error(Mxrb::Studio::Conflict, /changed since they were compared/)
      expect(native_bytes).to eq(before)

      current = sync.run(dry_run: true)
      result = sync.run(expected_revisions: current[:revisions])
      expect(result).to include(applied: true, state: 'synced')
      expect(result[:revisions]).to eq(sync.status[:revisions])
      expect(attributes('Product')).to include('Active')
      expect(attributes('Order')).to include('Note')
    end

    it 'validates expected revisions' do
      sync.link!
      expect { sync.run(expected_revisions: { 'model' => 'x' }) }.to raise_error(ArgumentError, /SHA-256/)
    end
  end

  describe 'IDE caches' do
    it 'exports the open model with the inputs of a conversion, without caches the IDE rewrites' do
      cache = File.join(File.dirname(model), 'theme-cache', 'web', 'theme.compiled.css')
      FileUtils.mkdir_p(File.dirname(cache))
      File.write(cache, '/* compiled by the IDE */')
      sync.link!
      manifest = File.read(File.join(ruby, '.mxrb', 'assets.json'))
      expect(manifest).not_to include('theme-cache')
      File.write(cache, '/* recompiled */')
      edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
      expect(sync.run).to include(applied: true)
      expect(attributes('Product')).to include('Active')
    end
  end

  describe 'Ruby saved during a run' do
    it 'keeps a Ruby edit saved mid-run pending instead of folding it into the base' do
      sync.link!
      edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
      original = sync.method(:prepare)
      allow(sync).to receive(:prepare) do |*arguments, **options|
        edit(order_file) { _1.sub("decimal :Total\n", "decimal :Total\n  string :Late\n") }
        original.call(*arguments, **options)
      end
      expect(sync.run).to include(applied: true)
      expect(attributes('Product')).to include('Active')
      expect(attributes('Order')).not_to include('Late')
      status = sync.status
      expect(status[:state]).to eq('pending')
      expect(status[:ruby_changes].map { _1[:path] }).to eq(['modules/Shop/domain/entities/order.rb'])

      allow(sync).to receive(:prepare).and_call_original
      expect(sync.run).to include(applied: true)
      expect(attributes('Order')).to include('Late')
      expect(sync.status[:state]).to eq('synced')
    end

    it 'refuses to merge into a Ruby file that was saved after the run copied it' do
      sync.link!
      add_attribute('Order', 'Note')
      original = sync.method(:merge_text)
      allow(sync).to receive(:merge_text) do |*arguments, **options|
        result = original.call(*arguments, **options)
        edit(order_file) { "#{_1}# saved meanwhile\n" }
        result
      end
      before = native_bytes
      expect { sync.run }.to raise_error(Mxrb::Studio::Conflict, /order\.rb was saved during synchronization/)
      expect(native_bytes).to eq(before)
      expect(File.read(order_file)).to end_with("# saved meanwhile\n")
      expect(File.read(order_file)).not_to include('string :Note')
    end
  end

  describe 'artifact states without conflicts' do
    it 'reports an unlinked model, a pending Ruby file and files that declare no artifact' do
      path = 'modules/Shop/domain/entities/order.rb'
      expect(sync.document_state(path:)).to eq(linked: false, state: 'unlinked')
      sync.link!
      edit(order_file) { "#{_1}# touched\n" }
      expect(sync.document_state(path:)).to include(state: 'pending', ruby: { path:, action: 'modified' })
      expect(sync.document_state(path: 'missing.rb')).to include(state: 'synced', unit_ids: [])
      File.write(File.join(ruby, 'notes.md'), "# Notes\n")
      expect(sync.document_state(path: 'notes.md')).to include(unit_ids: [])
    end

    it 'names the state of a document entry from its conflicts, diagnostics and changes' do
      entry = { conflicts: [], diagnostics: [], ruby: nil, mendix: nil }
      expect(sync.send(:document_state_of, entry)).to eq('synced')
      expect(sync.send(:document_state_of, entry.merge(conflicts: ['x']))).to eq('conflict')
      errors = entry.merge(diagnostics: [{ severity: 'error' }])
      expect(sync.send(:document_state_of, errors)).to eq('conversion_error')
    end

    it 'maps only entities, DTOs and known document kinds to units' do
      index = { ['DomainModels$DomainModel', 'Shop'] => 'domain' }
      expect(sync.send(:artifact_unit, index, { kind: 'entity', qualified_name: 'Shop.Order' })).to eq('domain')
      expect(sync.send(:artifact_unit, index, { kind: 'module', qualified_name: 'Shop' })).to be_nil
    end

    it 'ignores stored conflicts without revisions' do
      sync.link!
      FileUtils.mkdir_p(File.dirname(sync.send(:conflicts_path)))
      File.write(sync.send(:conflicts_path), JSON.generate(conflicts: [{ id: 'x' }]))
      expect(sync.status[:conflicts]).to eq([])
    end

    it 'keeps error locations outside the Ruby project and removes a temporary file it could not rename' do
      error = Mxrb::Studio::RubySourceError.new('boom', locations: [{ file: '/usr/lib/ruby/x.rb', line: 1 }])
      expect(sync.send(:relocate, error, ruby).locations).to eq([{ file: '/usr/lib/ruby/x.rb', line: 1 }])
      target = File.join(@directory, 'merged.rb')
      allow(File).to receive(:rename).and_raise(Errno::EXDEV)
      expect { sync.send(:write_file, target, "x\n") }.to raise_error(Errno::EXDEV)
      expect(Dir.glob(File.join(@directory, '.mxrb-sync-*'))).to be_empty
    end

    it 'fails a sandboxed run before copying when no temporary workspace can be made' do
      allow(Dir).to receive(:mktmpdir).and_call_original
      allow(Dir).to receive(:mktmpdir).with('mxrb-sync-sandbox-').and_raise(Errno::ENOSPC)
      expect { sync_with(:sandbox).link! }.to raise_error(Errno::ENOSPC)
    end
  end

  describe 'conflicts and artifact states' do
    before do
      sync.link!
      edit(product_file) { _1.sub('string :Name, length: 200', 'string :Name, length: 100') }
      editor = Mxrb::Studio::ModelOperations.new(model, workspace_root: @directory)
      editor.apply({ 'operation' => 'change_attribute', 'target' => 'Shop.Product/Name', 'length' => 50 },
                   revision: editor.revision)
    end

    it 'records conflicts of a dry run with their revisions and drops them once either side changes' do
      expect(sync.status[:state]).to eq('pending')
      result = sync.run(dry_run: true)
      expect(result).to include(state: 'conflict', applied: false)
      status = sync.status
      expect(status).to include(state: 'conflict')
      expect(status[:conflicts].map { _1[:id] }).to match_array(result[:conflicts].map { _1[:id] })

      edit(order_file) { "#{_1}# touched\n" }
      expect(sync.status).to include(state: 'pending', conflicts: [])
    end

    it 'reads a corrupt link or stored conflicts as absent' do
      sync.run(dry_run: true)
      File.write(sync.send(:conflicts_path), '{')
      expect(sync.status).to include(state: 'pending', conflicts: [])
      File.write(sync.send(:link_path), '{')
      expect(sync.linked?).to be(false)
    end

    it 'reports an untouched microflow document as synchronized' do
      path = Dir.glob('**/recalculate.rb', base: ruby).first
      expect(sync.document_state(path:)).to include(state: 'synced', ruby: nil)
    end

    it 'reports each changed artifact with what each side did' do
      id = domain_model_id
      document = sync.status[:documents].find { _1[:unit_id] == id }
      expect(document).to include(type: 'DomainModels$DomainModel', qualified_name: 'Shop', ruby: 'modified',
                                  mendix: 'modified', state: 'pending',
                                  files: ['modules/Shop/domain/entities/product.rb'])

      conflicts = sync.run(dry_run: true)[:conflicts]
      document = sync.status[:documents].find { _1[:unit_id] == id }
      expect(document[:state]).to eq('conflict')
      expect(document[:conflicts]).to match_array(conflicts.map { _1[:id] })

      by_unit = sync.document_state(unit_id: id)
      expect(by_unit).to include(linked: true, state: 'conflict', unit_ids: [id])
      by_path = sync.document_state(path: 'modules/Shop/domain/entities/product.rb')
      expect(by_path).to include(state: 'conflict', ruby: { path: 'modules/Shop/domain/entities/product.rb',
                                                            action: 'modified' })
      untouched = sync.document_state(path: 'modules/Shop/domain/entities/order.rb')
      expect(untouched).to include(state: 'conflict', unit_ids: [id], ruby: nil)

      sync.run(resolutions: conflicts.to_h { [_1[:id], 'ruby'] })
      expect(sync.document_state(unit_id: id)).to include(state: 'synced')
      expect(sync.status[:documents]).to eq([])
    end

    it 'marks the artifact of Ruby that does not parse as a conversion error' do
      edit(order_file) { _1.sub('decimal :Total', 'decimal :Total,') }
      state = sync.document_state(path: 'modules/Shop/domain/entities/order.rb')
      expect(state[:state]).to eq('conversion_error')
      expect(state[:diagnostics]).to include(include(severity: 'error', file: 'modules/Shop/domain/entities/order.rb'))
      expect { sync.document_state }.to raise_error(ArgumentError, /unit_id or a path/)
    end
  end

  describe 'sandboxed generation' do
    def sandboxed_or_skip
      yield
    rescue Mxrb::Studio::Protocol::Failure => e
      raise unless e.data.is_a?(Hash) && e.data[:reason] == 'isolation_unavailable'

      skip "OS isolation unavailable in this test environment: #{e.message}"
    end

    it 'fails a sandboxed run as a toolchain error when OS isolation is unavailable' do
      allow_any_instance_of(Mxrb::Studio::PreviewSandbox).to receive(:generate)
        .and_raise(Mxrb::Studio::PreviewIsolationUnavailable, 'bubblewrap unavailable')
      expect { sync_with(:sandbox).link! }.to raise_error(Mxrb::Studio::Protocol::Failure) do |error|
        expect(error.data).to eq(reason: 'isolation_unavailable')
      end
    end

    it 'links and applies Ruby edits through the sandbox, which cannot write the user files' do
      sandbox = sync_with(:sandbox)
      sandboxed_or_skip { sandbox.link! }
      escape = File.join(@directory, 'escaped.txt')
      File.open(File.join(ruby, 'project.rb'), 'a') do |file|
        file.write(<<~RUBY)
          begin
            File.write(#{escape.inspect}, 'must not be written')
          rescue SystemCallError
          end
        RUBY
      end
      edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
      expect(sandboxed_or_skip { sandbox.run }).to include(applied: true)
      expect(attributes('Product')).to include('Active')
      expect(File).not_to exist(escape)
    end

    it 'generates MPR v2 projects in the sandbox with their external unit contents' do
      Mxrb.open(model, readonly: false) { _1.mpr.migrate_storage_format!(:v2) }
      sandbox = sync_with(:sandbox)
      sandboxed_or_skip { sandbox.link! }
      edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
      expect(sandboxed_or_skip { sandbox.run }).to include(applied: true)
      expect(attributes('Product')).to include('Active')
    end

    it 'locates Ruby errors in the linked project files' do
      sandbox = sync_with(:sandbox)
      sandboxed_or_skip { sandbox.link! }
      edit(order_file) { _1.sub("decimal :Total\n", "decimal :Total\n  undefined_dsl_helper!\n") }
      expect { sandboxed_or_skip { sandbox.run } }.to raise_error(Mxrb::Studio::RubySourceError) do |error|
        expect(error.locations).to include(include(file: order_file, path: 'modules/Shop/domain/entities/order.rb'))
      end
    end

    it 'rejects an unknown isolation' do
      expect { sync_with(:none) }.to raise_error(ArgumentError, /isolation/)
    end
  end

  describe 'service' do
    let(:service) { Mxrb::Studio::Service.new(state_root:) }

    around do |example|
      previous = ENV.fetch('MXRB_STUDIO_SYNC_ISOLATION', nil)
      ENV['MXRB_STUDIO_SYNC_ISOLATION'] = 'process'
      example.run
    ensure
      ENV['MXRB_STUDIO_SYNC_ISOLATION'] = previous
    end

    def call(method, params) = service.dispatch(method, params)

    it 'applies under a lease the client holds while other writers wait' do
      params = { 'model' => model, 'ruby_root' => ruby }
      call('sync/link', params)
      edit(product_file) { _1.sub("integer :Stock\n", "integer :Stock\n  boolean :Active\n") }
      lease = call('locks/acquire', { 'target' => model, 'timeout' => 1 })
      expect(call('locks/status', { 'target' => model })).to include(locked: true)
      expect { Mxrb::Studio::WriteLock.synchronize(model, timeout: 0.2) { nil } }
        .to raise_error(Mxrb::Studio::Busy)

      result = call('sync/run', params.merge('lease' => lease[:lease]))
      expect(result).to include(applied: true, state: 'synced')
      expect(Thread.current[Mxrb::Studio::WriteLock::HELD].to_a).not_to include(lease[:path])
      expect(call('locks/status', { 'target' => model })).to include(locked: true)
      call('locks/release', { 'lease' => lease[:lease] })
      expect(call('locks/status', { 'target' => model })).to include(locked: false)
      expect(attributes('Product')).to include('Active')
    ensure
      service.close
    end

    it 'rejects unknown leases and leases of another target' do
      params = { 'model' => model, 'ruby_root' => ruby }
      call('sync/link', params)
      expect { call('sync/run', params.merge('lease' => 'missing')) }.to raise_error(ArgumentError, /unknown lease/)
      lease = call('locks/acquire', { 'target' => ruby })
      expect { call('sync/run', params.merge('lease' => lease[:lease])) }
        .to raise_error(ArgumentError, /does not hold this model/)
    ensure
      service.close
    end

    it 'reports one artifact state and converts with an immediate synchronization base' do
      params = { 'model' => model, 'ruby_root' => ruby }
      call('sync/link', params)
      expect(call('sync/document', params.merge('path' => 'modules/Shop/domain/entities/order.rb')))
        .to include(state: 'synced')

      converted = call('project/convert', { 'source_model' => model, 'link' => true })
      expect(converted).to include(state: 'ready')
      expect(converted[:sync]).to include(linked: true, state: 'synced')
    end

    it 'keeps a conversion whose link fails and still lets cancellation through' do
      sync = instance_double(Mxrb::Studio::Sync, linked?: false)
      allow(Mxrb::Studio::Sync).to receive(:new).and_return(sync)
      allow(sync).to receive(:link!).and_raise(ArgumentError, 'base unavailable')
      converted = call('project/convert', { 'source_model' => model, 'link' => true })
      expect(converted).to include(state: 'ready')
      expect(converted[:sync]).to eq(linked: false, state: 'unlinked', error: 'base unavailable')
      allow(sync).to receive(:link!).and_raise(Mxrb::Studio::Cancelled)
      expect { call('project/convert', { 'source_model' => model, 'link' => true }) }
        .to raise_error(Mxrb::Studio::Cancelled)
    end

    it 'reports the existing synchronization of a conversion that is already linked' do
      sync = instance_double(Mxrb::Studio::Sync, linked?: true, status: { linked: true, state: 'synced' })
      allow(Mxrb::Studio::Sync).to receive(:new).and_return(sync)
      converted = call('project/convert', { 'source_model' => model, 'link' => true })
      expect(converted[:sync]).to eq(linked: true, state: 'synced')
    end
  end
end
# rubocop:enable Metrics
