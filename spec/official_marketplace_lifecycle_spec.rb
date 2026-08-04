# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::OfficialMarketplace::Lifecycle do
  def create_project(path, module_name:)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module module_name do
        entity(:Item) { string :Name }
        microflow :Process
      end
    end
  end

  def create_package(path, source, version:, asset:, module_name: 'MarketplaceModule')
    xml = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <package xmlns="http://www.mendix.com/package/1.0/">
        <modelerProject xmlns="http://www.mendix.com/modelerProject/1.0/">
          <module name="#{module_name}" />
          <projectFile path="project.mpr" />
          <files><file path="widgets/lifecycle.mpk" /></files>
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
      zip.get_output_stream('widgets/lifecycle.mpk') { _1.write(asset) }
    end
    path
  end

  def official_package(version)
    Mxrb::OfficialMarketplace::OfficialPackage.new(
      'Marketplace Module', version, :mendix, nil, 'content:170', 170,
      "version-#{version}", 'Module', 'Regular', [], false, true
    )
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.join(dir, 'project')
      FileUtils.mkdir_p(@root)
      @target = File.join(@root, 'App.mpr')
      @source_v1 = File.join(dir, 'source-v1.mpr')
      @source_v2 = File.join(dir, 'source-v2.mpr')
      create_project(@target, module_name: :Host)
      create_project(@source_v1, module_name: :MarketplaceModule)
      FileUtils.cp(@source_v1, @source_v2)
      Mxrb.open(@source_v2, readonly: false) do |project|
        unit = project.find_artifact('MarketplaceModule.Process')
        document = project.parse_bson(project.raw_unit(unit.unit_id))
        document['Name'] = 'ProcessV2'
        project.mpr.update_unit(unit.unit_id, document)
      end
      @package_v1 = create_package(
        File.join(dir, 'v1.mpk'), @source_v1, version: '1.0.0', asset: 'one'
      )
      @package_v2 = create_package(
        File.join(dir, 'v2.mpk'), @source_v2, version: '2.0.0', asset: 'two'
      )
      @installer = Mxrb::OfficialMarketplace::Installer.new(target: @root, mpr: @target)
      @installation = @installer.send(
        :import_module, @package_v1, official_package('1.0.0'), @target
      )
      @lifecycle = described_class.new(target: @root, mpr: @target, installer: @installer)
      example.run
    end
  end

  it 'previews and explicitly applies a complete module removal' do
    plan = @installer.remove('170')
    expect(plan).to be_safe
    expect(plan).not_to be_applied
    expect(plan.changes).to include(match(/delete 3 MPR units/), match(/delete 1 package assets/))

    plan.apply!
    expect(plan).to be_applied
    expect(Mxrb::OfficialMarketplace.lock(@root).fetch('packages')).to be_empty
    expect(File).not_to exist(File.join(@root, 'widgets', 'lifecycle.mpk'))
    expect(File).not_to exist(@installation.archive)
    Mxrb.open(@target) do |project|
      expect(project.modules.map(&:name)).to eq(['Host'])
    end
    expect { plan.apply! }.to raise_error(Mxrb::MarketplaceError, /already applied/)
  end

  it 'blocks removal when another unit references the module or an asset changed' do
    Mxrb.open(@target, readonly: false) do |project|
      root = project.mpr.root_unit
      document = project.mpr.parse_contents(root)
      document['LifecycleReference'] = @installation.module_id
      project.mpr.update_unit(root.fetch('UnitID'), document)
    end
    plan = @lifecycle.plan_remove('MarketplaceModule')
    expect(plan).not_to be_safe
    expect(plan.blockers.join(' ')).to include('references 1 unit')
    expect { plan.apply! }.to raise_error(Mxrb::MarketplaceError, /blocked/)

    File.write(File.join(@root, 'widgets', 'lifecycle.mpk'), 'locally changed')
    expect(@lifecycle.plan_remove('MarketplaceModule').blockers.join(' '))
      .to include('package asset changed or missing')
    FileUtils.rm_f(File.join(@root, 'widgets', 'lifecycle.mpk'))
    expect(@lifecycle.plan_remove('MarketplaceModule').blockers.join(' '))
      .to include('package asset changed or missing')
    external = File.join(File.dirname(@root), 'external-asset')
    File.write(external, 'one')
    FileUtils.ln_s(external, File.join(@root, 'widgets', 'lifecycle.mpk'))
    expect(@lifecycle.plan_remove('MarketplaceModule').blockers.join(' '))
      .to include('package asset changed or missing')
    expect { @installer.send(:preserve_asset, 'widgets/lifecycle.mpk', 'MarketplaceModule') }
      .to raise_error(Mxrb::MarketplaceError, /symbolic link/)

    staged = File.join(File.dirname(@root), 'staged-asset')
    File.write(staged, 'replacement')
    assets = Mxrb::OfficialMarketplace::ModulePackageAssets.new(@root, File.dirname(@root))
    expect { assets.install('widgets/lifecycle.mpk' => staged) }
      .to raise_error(Mxrb::MarketplaceError, /symbolic link/)
  end

  it 'updates in place while preserving module identity and replacing assets and lock metadata' do
    plan = @lifecycle.plan_update('MarketplaceModule', @package_v2, official_package('2.0.0'))
    expect(plan).to have_attributes(
      safe?: true, applied?: false, installed_version: '1.0.0', target_version: '2.0.0'
    )
    plan.apply!

    expect(File.read(File.join(@root, 'widgets', 'lifecycle.mpk'))).to eq('two')
    lock = Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'MarketplaceModule')
    expect(lock).to include('version' => '2.0.0', 'version_id' => 'version-2.0.0')
    expect(File).not_to exist(@installation.archive)
    expect(Mxrb::OfficialMarketplace.verify(@root).dig('MarketplaceModule', :valid)).to be(true)
    Mxrb.open(@target) do |project|
      expect(project.find_artifact('MarketplaceModule.ProcessV2')).not_to be_nil
    end
  end

  it 'downloads an authenticated official update for preview and applies only when requested' do
    package = official_package('2.0.0')
    api = instance_double(Mxrb::OfficialMarketplace::ContentApi, resolve: package)
    allow(api).to receive(:download) do |_version_id, destination, **|
      FileUtils.cp(@package_v2, destination)
      destination
    end

    preview = @installer.update_official('MarketplaceModule', api:)
    expect(preview).to have_attributes(safe?: true, applied?: false)
    expect(Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'MarketplaceModule', 'version'))
      .to eq('1.0.0')

    applied = @installer.update_official('170', api:, apply: true)
    expect(applied).to have_attributes(safe?: true, applied?: true)
    expect(Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'MarketplaceModule', 'version'))
      .to eq('2.0.0')
  end

  it 'restores MPR, assets, cache, and lock when an update fails after deletion' do
    plan = @lifecycle.plan_update('MarketplaceModule', @package_v2, official_package('2.0.0'))
    allow(@installer).to receive(:import_module).and_raise(Errno::ENOSPC, 'disk full')
    expect { plan.apply! }.to raise_error(Errno::ENOSPC)

    expect(File.read(File.join(@root, 'widgets', 'lifecycle.mpk'))).to eq('one')
    expect(File).to exist(@installation.archive)
    expect(Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'MarketplaceModule', 'version'))
      .to eq('1.0.0')
    expect(Mxrb::OfficialMarketplace.verify(@root).dig('MarketplaceModule', :valid)).to be(true)
  end

  it 'fails closed for identity changes, no-op versions, mismatched MPRs, and unknown packages' do
    changed = @lifecycle.plan_update('MarketplaceModule', @package_v2, official_package('1.0.0'))
    expect(changed.blockers).to include('version 1.0.0 is already installed')
    expect { @lifecycle.installed('missing') }
      .to raise_error(Mxrb::MarketplaceError, /not installed/)

    other = described_class.new(target: @root, mpr: File.join(@root, 'Other.mpr'), installer: @installer)
    expect { other.plan_remove('MarketplaceModule') }
      .to raise_error(Mxrb::MarketplaceError, /does not match/)
  end

  it 'rejects replacement packages whose module name, identity, or manifest version changed' do
    fresh_source = File.join(File.dirname(@source_v1), 'fresh.mpr')
    create_project(fresh_source, module_name: :MarketplaceModule)
    fresh_package = create_package(
      File.join(File.dirname(@package_v1), 'fresh.mpk'), fresh_source,
      version: '2.0.0', asset: 'fresh'
    )
    identity = @lifecycle.plan_update(
      'MarketplaceModule', fresh_package, official_package('2.0.0')
    )
    expect(identity.blockers).to include('replacement module identity changed')

    renamed_source = File.join(File.dirname(@source_v1), 'renamed.mpr')
    create_project(renamed_source, module_name: :RenamedModule)
    renamed_package = create_package(
      File.join(File.dirname(@package_v1), 'renamed.mpk'), renamed_source,
      version: '2.0.0', asset: 'renamed', module_name: 'RenamedModule'
    )
    renamed = @lifecycle.plan_update(
      'MarketplaceModule', renamed_package, official_package('2.0.0')
    )
    expect(renamed.blockers.join(' ')).to include('module name changed')

    mismatch = @lifecycle.plan_update(
      'MarketplaceModule', @package_v2, official_package('3.0.0')
    )
    expect(mismatch.blockers.join(' ')).to include('downloaded package version 2.0.0')
  end

  it 'fails closed for malformed locks, missing state, shared assets, and invalid packages' do
    lock_path = File.join(@root, '.mxrb', 'marketplace.lock.json')
    lock = Mxrb::OfficialMarketplace.lock(@root)
    lock['packages']['TreePackage'] = {
      'destination' => 'modules/TreePackage', 'sha256' => 'x',
      'files' => ['widgets/lifecycle.mpk']
    }
    File.write(lock_path, JSON.generate(lock))
    expect { @lifecycle.installed('TreePackage') }
      .to raise_error(Mxrb::MarketplaceError, /not an imported module/)
    expect(@lifecycle.plan_remove('MarketplaceModule').changes)
      .to include('delete 0 package assets')

    expect { @lifecycle.send(:safe_path, '../outside') }
      .to raise_error(Mxrb::MarketplaceError, /outside marketplace target/)
    expect { @installer.send(:safe_target_path, '../outside') }
      .to raise_error(Mxrb::MarketplaceError, /outside marketplace target/)
    FileUtils.rm_f(@installation.archive)
    expect { @lifecycle.plan_remove('MarketplaceModule') }
      .to raise_error(Mxrb::MarketplaceError, /cached Marketplace package is missing/)

    FileUtils.cp(@package_v1, @installation.archive)
    FileUtils.mv(@target, "#{@target}.saved")
    expect { @lifecycle.plan_remove('MarketplaceModule') }
      .to raise_error(Mxrb::MarketplaceError, /MPR not found/)
    FileUtils.mv("#{@target}.saved", @target)

    lock = Mxrb::OfficialMarketplace.lock(@root)
    lock['packages'].delete('TreePackage')
    lock['packages']['MarketplaceModule']['module_id'] = SecureRandom.uuid
    File.write(lock_path, JSON.generate(lock))
    expect { @lifecycle.plan_remove('MarketplaceModule') }
      .to raise_error(Mxrb::MarketplaceError, /absent from target MPR/)

    host_only = File.join(File.dirname(@source_v1), 'host-only.mpr')
    create_project(host_only, module_name: :HostOnly)
    invalid = create_package(
      File.join(File.dirname(@package_v1), 'absent.mpk'), host_only,
      version: '2.0.0', asset: 'absent'
    )
    expect { Mxrb::OfficialMarketplace::ModulePackageInventory.read(invalid) }
      .to raise_error(Mxrb::MarketplaceError, /absent from package MPR/)

    broken_mpr = File.join(File.dirname(@source_v1), 'broken.mpr')
    File.write(broken_mpr, 'not sqlite')
    broken = create_package(
      File.join(File.dirname(@package_v1), 'broken.mpk'), broken_mpr,
      version: '2.0.0', asset: 'broken'
    )
    expect { Mxrb::OfficialMarketplace::ModulePackageInventory.read(broken) }
      .to raise_error(Mxrb::Error)
    invalid_zip = File.join(File.dirname(@package_v1), 'invalid.zip')
    File.write(invalid_zip, 'not a zip')
    expect { Mxrb::OfficialMarketplace::ModulePackageInventory.read(invalid_zip) }
      .to raise_error(Mxrb::MarketplaceError, /invalid Mendix module package/)
  end

  it 'covers conservative lock blockers and complete file-or-directory rollback' do
    entry = Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'MarketplaceModule')
    inventory = Mxrb::OfficialMarketplace::ModulePackageInventory.read(@installation.archive)
    mpr = Mxrb::IO::MprFile.open(@target, readonly: true)
    host = mpr.units_by_containment('Modules').find { mpr.parse_contents(_1)['Name'] == 'Host' }
    host_id = host.fetch('UnitID')
    mpr.close
    changed = entry.merge('module_id' => host_id, 'units' => 999)
    blockers = @lifecycle.send(:base_blockers, changed, inventory, ['one'])
    expect(blockers).to contain_exactly(
      'locked module identity does not match cached package',
      'locked unit count does not match target module tree'
    )

    directory = File.join(@root, 'rollback-directory')
    file = File.join(@root, 'rollback-file')
    missing = File.join(@root, 'rollback-missing')
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'value'), 'before')
    File.write(file, 'before')
    expect do
      @lifecycle.send(:with_rollback, [directory, file, missing]) do
        File.write(File.join(directory, 'value'), 'after')
        File.write(file, 'after')
        File.write(missing, 'created')
        raise 'rollback'
      end
    end.to raise_error('rollback')
    expect(File.read(File.join(directory, 'value'))).to eq('before')
    expect(File.read(file)).to eq('before')
    expect(File).not_to exist(missing)
  end

  it 'removes the Atlas variables import only when its managed file exists' do
    expect(@lifecycle.send(:remove_atlas_variables)).to be_nil
    path = File.join(@root, 'theme', 'web', 'custom-variables.scss')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "before\n#{Mxrb::OfficialMarketplace::Installer::ATLAS_VARIABLES_IMPORT}\nafter\n")
    @lifecycle.send(:remove_atlas_variables)
    expect(File.read(path)).to eq("before\nafter\n")
  end

  it 'covers alias, Atlas, equal-cache, and unopened-MPR refusal branches' do
    lock_path = File.join(@root, '.mxrb', 'marketplace.lock.json')
    lock = Mxrb::OfficialMarketplace.lock(@root)
    lock['packages']['Alias'] = lock['packages'].delete('MarketplaceModule')
    File.write(lock_path, JSON.generate(lock))
    expect(@lifecycle.plan_remove('Alias').blockers.join(' '))
      .to include('locked module name does not match cached package')

    lifecycle = described_class.new(target: @root, mpr: @target, installer: @installer)
    allow(lifecycle).to receive(:with_rollback).and_yield
    allow(lifecycle).to receive(:delete_units)
    allow(lifecycle).to receive(:safe_path).and_return(File.join(@root, 'absent'))
    allow(lifecycle).to receive(:delete_lock_entry)
    expect(lifecycle).to receive(:remove_atlas_variables)
    lifecycle.send(:apply_remove, 'Atlas_Core', { 'archive' => 'archive' }, @target, [], [])

    inventory = Mxrb::OfficialMarketplace::ModulePackageInventory.read(@package_v1)
    entry = { 'archive' => '.mxrb/marketplace/MarketplaceModule-1.0.0.mpk', 'files' => [] }
    allow(lifecycle).to receive(:safe_path).and_call_original
    allow(@installer).to receive(:import_module)
    lifecycle.send(
      :apply_update, entry, @target, [], [], @package_v1, official_package('1.0.0'), inventory
    )

    unopened = described_class.new(target: @root, mpr: @target, installer: @installer)
    expect { unopened.send(:delete_units, File.join(@root, 'missing.mpr'), []) }
      .to raise_error(Mxrb::Error)

    expect(unopened.send(:package_version_matches?, '', '2.0.0')).to be(true)
    expect(unopened.send(:package_version_matches?, 'unknown', '2.0.0')).to be(true)
    expect(unopened.send(:package_version_matches?, '2.0.0', '2.0.0')).to be(true)
    expect(unopened.send(:package_version_matches?, '1.0.0', '2.0.0')).to be(false)
  end

  it 'applies removal directly through the installer opt-in' do
    plan = @installer.remove('MarketplaceModule', apply: true)
    expect(plan).to have_attributes(safe?: true, applied?: true)
  end

  it 'restores an asset that existed before the package was installed' do
    root = File.join(File.dirname(@source_v1), 'preexisting-project')
    target = File.join(root, 'App.mpr')
    asset = File.join(root, 'widgets', 'lifecycle.mpk')
    FileUtils.mkdir_p(File.dirname(asset))
    create_project(target, module_name: :Host)
    File.write(asset, 'user original')
    installer = Mxrb::OfficialMarketplace::Installer.new(target: root, mpr: target)
    installation = installer.send(
      :import_module, @package_v1, official_package('1.0.0'), target
    )
    entry = Mxrb::OfficialMarketplace.lock(root).dig('packages', 'MarketplaceModule')
    backup = File.join(root, entry.dig('asset_originals', 'widgets/lifecycle.mpk'))
    expect(File.read(asset)).to eq('one')
    expect(File.read(backup)).to eq('user original')

    lifecycle = described_class.new(target: root, mpr: target, installer: installer)
    lifecycle.plan_update(
      'MarketplaceModule', @package_v2, official_package('2.0.0')
    ).apply!
    expect(File.read(asset)).to eq('two')
    expect(File.read(backup)).to eq('user original')

    plan = installer.remove('MarketplaceModule', apply: true)
    expect(plan).to be_applied
    expect(File.read(asset)).to eq('user original')
    expect(File).not_to exist(backup)
    expect(File).not_to exist(installation.archive)
  end

  it 'cleans a newly persisted original-asset backup when import fails' do
    root = File.join(File.dirname(@source_v1), 'failed-project')
    target = File.join(root, 'App.mpr')
    asset = File.join(root, 'widgets', 'lifecycle.mpk')
    FileUtils.mkdir_p(File.dirname(asset))
    create_project(target, module_name: :Host)
    File.write(asset, 'user original')
    installer = Mxrb::OfficialMarketplace::Installer.new(target: root, mpr: target)
    importer = double
    allow(importer).to receive(:import!).and_raise(Errno::ENOSPC, 'disk full')
    allow(installer).to receive(:module_importer).and_return(importer)

    expect do
      installer.send(:import_module, @package_v1, official_package('1.0.0'), target)
    end.to raise_error(Errno::ENOSPC)
    backup = File.join(
      root, '.mxrb', 'marketplace-originals', 'MarketplaceModule', 'widgets', 'lifecycle.mpk'
    )
    expect(File).not_to exist(backup)
    expect(File.read(asset)).to eq('user original')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
