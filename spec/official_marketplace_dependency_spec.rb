# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::OfficialMarketplace::DependencyResolver do
  def create_project(path, module_name:, dependency: nil)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module module_name do
        microflow(:Work) { call_microflow "#{dependency}.Work" if dependency }
      end
    end
  end

  def create_package(path, source, module_name:, version: '1.0.0')
    xml = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <package xmlns="http://www.mendix.com/package/1.0/">
        <modelerProject xmlns="http://www.mendix.com/modelerProject/1.0/">
          <module name="#{module_name}" />
          <projectFile path="project.mpr" />
          <files />
        </modelerProject>
      </package>
    XML
    manifest = {
      'package' => { 'name' => module_name, 'version' => version, 'type' => 'Module' },
      'model-version' => '11.12.1'
    }
    Zip::File.open(path, create: true) do |zip|
      zip.add('project.mpr', source)
      zip.get_output_stream('package.xml') { _1.write(xml) }
      zip.get_output_stream('manifest.json') { _1.write(JSON.generate(manifest)) }
    end
    path
  end

  def package(name, id)
    Mxrb::OfficialMarketplace::OfficialPackage.new(
      name, '1.0.0', :mendix, "https://marketplace.test/#{id}", "content:#{id}", id,
      "00000000-0000-0000-0000-#{id.to_s.rjust(12, '0')}",
      'Module', 'Regular', [], false, true
    )
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.join(dir, 'project')
      FileUtils.mkdir_p(@root)
      @target = File.join(@root, 'App.mpr')
      host = File.join(dir, 'host.mpr')
      root_source = File.join(dir, 'root.mpr')
      dependency_source = File.join(dir, 'dependency.mpr')
      transitive_source = File.join(dir, 'transitive.mpr')
      create_project(host, module_name: :Host)
      create_project(root_source, module_name: :RootModule, dependency: 'DependencyModule')
      create_project(
        dependency_source, module_name: :DependencyModule, dependency: 'TransitiveModule'
      )
      create_project(transitive_source, module_name: :TransitiveModule)
      FileUtils.cp(host, @target)
      @archives = {
        1 => create_package(File.join(dir, 'root.mpk'), root_source, module_name: 'RootModule'),
        2 => create_package(
          File.join(dir, 'dependency.mpk'), dependency_source, module_name: 'DependencyModule'
        ),
        3 => create_package(
          File.join(dir, 'transitive.mpk'), transitive_source, module_name: 'TransitiveModule'
        )
      }
      @packages = {
        1 => package('Root Module', 1),
        2 => package('Dependency Module', 2),
        3 => package('Transitive Module', 3)
      }
      @installer = Mxrb::OfficialMarketplace::Installer.new(target: @root, mpr: @target)
      @installer.send(:import_module, @archives.fetch(1), @packages.fetch(1), @target)
      example.run
    end
  end

  before do
    @api = instance_double(Mxrb::OfficialMarketplace::ContentApi)
    allow(@api).to receive(:search) do |name:, **|
      id = 2 if name.delete(' _').casecmp('DependencyModule').zero?
      id = 3 if name.delete(' _').casecmp('TransitiveModule').zero?
      id ? [{ 'contentId' => id, 'type' => 'Module' }] : []
    end
    allow(@api).to receive(:resolve) { |id, **| @packages.fetch(id) }
    allow(@api).to receive(:download) do |_version_id, destination, download_url:|
      id = download_url.split('/').last.to_i
      FileUtils.cp(@archives.fetch(id), destination)
      destination
    end
  end

  it 'previews and applies verified dependencies in transitive-first order' do
    plan = @installer.dependencies('RootModule', api: @api)
    expect(plan).to have_attributes(root: 'RootModule', safe?: true, applied?: false)
    expect(plan.changes).to eq(
      ['install TransitiveModule 1.0.0', 'install DependencyModule 1.0.0']
    )
    expect(Mxrb::OfficialMarketplace.lock(@root).fetch('packages').keys).to eq(['RootModule'])
    expect { plan.apply! }.to raise_error(Mxrb::MarketplaceError, /preview expired/)

    applied = @installer.dependencies('1', api: @api, apply: true)
    expect(applied).to have_attributes(safe?: true, applied?: true)
    expect(Mxrb::OfficialMarketplace.lock(@root).fetch('packages').keys)
      .to contain_exactly('RootModule', 'DependencyModule', 'TransitiveModule')
    expect(Mxrb.validate(@target)).to be_valid
    expect { applied.apply! }.to raise_error(Mxrb::MarketplaceError, /already applied/)
    expect(applied.expire!).to equal(applied)

    complete = @installer.dependencies('RootModule', api: @api)
    expect(complete).to be_safe
    expect(complete.changes).to be_empty
  end

  it 'fails closed when no official MPK proves the requested module identity' do
    allow(@api).to receive(:search).and_return([])
    plan = @installer.dependencies('RootModule', api: @api)
    expect(plan).not_to be_safe
    expect(plan.blockers).to include(
      'DependencyModule: no official Marketplace package matched the module identity'
    )
    expect { plan.apply! }.to raise_error(Mxrb::MarketplaceError, /blocked/)
  end

  it 'ignores a failed candidate when a later verified candidate matches' do
    allow(@api).to receive(:search) do |name:, **|
      next [] unless name.delete(' _').casecmp('DependencyModule').zero?

      [{ 'contentId' => 99, 'type' => 'Module' }, { 'contentId' => 2, 'type' => 'Module' }]
    end
    allow(@api).to receive(:resolve) do |id, **|
      raise Mxrb::MarketplaceError, 'candidate unavailable' if id == 99

      @packages.fetch(id)
    end
    plan = @installer.dependencies('RootModule', api: @api)
    expect(plan.blockers).to include(
      'TransitiveModule: no official Marketplace package matched the module identity'
    )
    expect(plan.blockers.join(' ')).not_to include('candidate unavailable')
    expect(plan.changes).to eq(['install DependencyModule 1.0.0'])
  end

  it 'rejects candidates without a compatible package or matching module identity' do
    allow(@api).to receive(:search).and_return([{ 'contentId' => 2, 'type' => 'Module' }])
    allow(@api).to receive(:resolve).and_return(nil)
    expect(@installer.dependencies('RootModule', api: @api).blockers).to include(
      'DependencyModule: no official Marketplace package matched the module identity'
    )

    allow(@api).to receive(:search).and_return([{ 'contentId' => 3, 'type' => 'Module' }])
    allow(@api).to receive(:resolve).and_return(@packages.fetch(3))
    expect(@installer.dependencies('RootModule', api: @api).blockers).to include(
      'DependencyModule: no official Marketplace package matched the module identity'
    )
  end

  it 'applies only verified packages with an explicit partial opt-in' do
    allow(@api).to receive(:search) do |name:, **|
      next [] unless name.delete(' _').casecmp('DependencyModule').zero?

      [{ 'contentId' => 2, 'type' => 'Module' }]
    end
    plan = @installer.dependencies('RootModule', api: @api, apply_resolved: true)
    expect(plan).to have_attributes(safe?: false, applied?: true)
    expect(plan.blockers).to include(
      'TransitiveModule: no official Marketplace package matched the module identity'
    )
    expect(Mxrb::OfficialMarketplace.lock(@root).fetch('packages').keys)
      .to contain_exactly('RootModule', 'DependencyModule')
    expect { plan.apply_resolved! }.to raise_error(Mxrb::MarketplaceError, /already applied/)

    preview = @installer.dependencies('RootModule', api: @api)
    expect { preview.apply_resolved! }.to raise_error(Mxrb::MarketplaceError, /preview expired/)
  end

  it 'rolls back dependencies already installed when a later import fails' do
    calls = 0
    allow(@installer).to receive(:import_module).and_wrap_original do |original, *args|
      calls += 1
      raise Errno::ENOSPC, 'disk full' if calls == 2

      original.call(*args)
    end
    expect { @installer.dependencies('RootModule', api: @api, apply: true) }
      .to raise_error(Errno::ENOSPC)
    expect(Mxrb::OfficialMarketplace.lock(@root).fetch('packages').keys).to eq(['RootModule'])
    Mxrb.open(@target) { expect(_1.modules.map(&:name)).to contain_exactly('Host', 'RootModule') }
  end

  it 'rejects non-module search results, wrong module identities, and paths outside the target' do
    wrong = { 'contentId' => 3, 'type' => 'Widget' }
    allow(@api).to receive(:search).and_return([wrong])
    plan = @installer.dependencies('RootModule', api: @api)
    expect(plan).not_to be_safe

    resolver = described_class.new(
      target: @root, mpr: @target, installer: @installer, api: @api,
      mendix_version: '11.12.1'
    )
    expect { resolver.send(:safe_path, '../outside') }
      .to raise_error(Mxrb::MarketplaceError, /outside marketplace target/)
    expect(resolver.send(:queries, 'Atlas_Core')).to eq(['Atlas Core', 'Atlas_Core'])
    expect(resolver.send(:queries, 'Encryption')).to eq(['Encryption'])
    expect(described_class::PLATFORM_MODULES).to eq(['System'])
  end

  it 'uses a verified official content ID when the API name index differs from the module name' do
    resolver = described_class.new(
      target: @root, mpr: @target, installer: @installer, api: @api,
      mendix_version: '11.12.1'
    )
    content = { 'contentId' => 205_506, 'type' => 'Module' }
    allow(@api).to receive(:content).with(205_506).and_return(content)
    allow(@api).to receive(:search).and_return([])

    expect(resolver.send(:candidates, 'feedbackmodule')).to eq([content])
    expect(@api).to have_received(:content).with(205_506)
  end

  it 'short-circuits cycles and platform/self references and reuses a downloaded archive' do
    resolver = described_class.new(
      target: @root, mpr: @target, installer: @installer, api: @api,
      mendix_version: '11.12.1'
    )
    allow(resolver).to receive(:dependency_names).and_return(%w[System RootModule])
    resolver.send(:visit, 'RootModule', @archives.fetch(1))
    resolver.send(:visit, 'RootModule', @archives.fetch(1))
    expect(@api).not_to have_received(:search)

    Dir.mktmpdir do |temporary|
      resolver.instance_variable_set(:@temporary, temporary)
      first = resolver.send(:download_candidate, @packages.fetch(2))
      expect(resolver.send(:download_candidate, @packages.fetch(2))).to eq(first)
    end
    expect(@api).to have_received(:download).once
  end

  it 'reports malformed dependency archives as Marketplace errors' do
    resolver = described_class.new(
      target: @root, mpr: @target, installer: @installer, api: @api,
      mendix_version: '11.12.1'
    )
    expect { resolver.send(:extract_project, @target, @root) }
      .to raise_error(Mxrb::MarketplaceError, /invalid Mendix dependency package/)
  end

  it 'accepts a host-owned dependency module without pretending it is a Marketplace package' do
    Mxrb.define(@target) do
      mendix_version '11.12.1'
      self.module(:DependencyModule) { microflow :Work }
    end
    plan = @installer.dependencies('RootModule', api: @api)
    expect(plan).to be_safe
    expect(plan.changes).to be_empty
    expect(@api).not_to have_received(:search)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
