# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength, Metrics/ParameterLists
RSpec.describe Mxrb::OfficialMarketplace::ModulePackageImporter do
  def create_project(path, module_name:, version: '11.12.1')
    Mxrb.define(path) do
      mendix_version version
      self.module module_name do
        entity(:Item) { string :Name }
        enumeration(:Status) { value :Active }
        microflow :Process
      end
    end
  end

  def package_xml(module_name, files:, project_file: 'project.mpr')
    entries = files.map { |path| %(<file path="#{path}" />) }.join
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <package xmlns="http://www.mendix.com/package/1.0/">
        <modelerProject xmlns="http://www.mendix.com/modelerProject/1.0/">
          <module name="#{module_name}" />
          <projectFile path="#{project_file}" />
          <files>#{entries}</files>
        </modelerProject>
      </package>
    XML
  end

  def create_package(path, source_mpr, module_name: 'MarketplaceModule', files: {},
                     model_version: '11.12.1', xml: nil, manifest: nil)
    package_manifest = manifest || {
      'package' => { 'name' => module_name, 'version' => '2.3.0', 'type' => 'Module' },
      'model-version' => model_version
    }
    Zip::File.open(path, create: true) do |zip|
      zip.add('project.mpr', source_mpr)
      zip.get_output_stream('package.xml') do |stream|
        stream.write(xml || package_xml(module_name, files: files.keys))
      end
      manifest_contents = package_manifest.is_a?(String) ? package_manifest : JSON.generate(package_manifest)
      zip.get_output_stream('manifest.json') { _1.write(manifest_contents) }
      files.each { |name, content| zip.get_output_stream(name) { _1.write(content) } }
    end
    path
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      @source = File.join(dir, 'source.mpr')
      @target = File.join(dir, 'target', 'Host.mpr')
      FileUtils.mkdir_p(File.dirname(@target))
      create_project(@source, module_name: :MarketplaceModule)
      create_project(@target, module_name: :Host)
      @package = create_package(
        File.join(dir, 'MarketplaceModule.mpk'), @source,
        files: { 'widgets/marketplace-widget.mpk' => 'widget-content' }
      )
      example.run
    end
  end

  it 'imports the complete module tree and declared assets directly into the MPR' do
    result = described_class.new(@package, @target).import!
    expect(result).to have_attributes(
      module_name: 'MarketplaceModule', package_version: '2.3.0', units: 4,
      source_version: '11.12.1', target_version: '11.12.1'
    )
    expect(File.binread(File.join(File.dirname(@target), 'widgets', 'marketplace-widget.mpk')))
      .to eq('widget-content')
    expect(Mxrb.validate(@target)).to be_valid

    Mxrb.open(@target) do |project|
      mod = project.modules.find { _1.name == 'MarketplaceModule' }
      expect(mod).not_to be_nil
      expect(mod.entities.map(&:name)).to include('Item')
      expect(mod.enumerations.map { _1['Name'] }).to include('Status')
    end
  end

  it 'overwrites package assets recoverably and rejects duplicate modules' do
    asset = File.join(File.dirname(@target), 'widgets', 'marketplace-widget.mpk')
    FileUtils.mkdir_p(File.dirname(asset))
    File.write(asset, 'old')
    described_class.new(@package, @target).import!
    expect(File.read(asset)).to eq('widget-content')
    expect { described_class.new(@package, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /already exists/)
  end

  it 'rolls back units and files when asset installation fails' do
    destination = File.join(File.dirname(@target), 'widgets', 'marketplace-widget.mpk')
    FileUtils.mkdir_p(destination)
    expect { described_class.new(@package, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /is a directory/)
    Mxrb.open(@target) do |project|
      expect(project.modules.map(&:name)).to eq(['Host'])
    end
  end

  it 'requires matching Mendix model versions without an external converter' do
    old_target = File.join(@dir, 'old.mpr')
    create_project(old_target, module_name: :Host, version: '10.18.0')
    expect { described_class.new(@package, old_target).import! }
      .to raise_error(Mxrb::MarketplaceError, /requires matching model versions/)

    mismatched = create_package(
      File.join(@dir, 'mismatch.mpk'), @source, model_version: '11.11.0'
    )
    expect { described_class.new(mismatched, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /manifest version/)
  end

  it 'rejects malformed packages and protected or missing declared files' do
    missing_xml = File.join(@dir, 'missing-xml.mpk')
    Zip::File.open(missing_xml, create: true) { _1.add('project.mpr', @source) }
    expect { described_class.new(missing_xml, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /package.xml is missing/)

    protected_xml = package_xml('MarketplaceModule', files: ['.mxrb/credentials'])
    protected_package = create_package(
      File.join(@dir, 'protected.mpk'), @source, xml: protected_xml
    )
    expect { described_class.new(protected_package, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /protected package path/)

    missing_file_xml = package_xml('MarketplaceModule', files: ['widgets/missing.mpk'])
    missing_file = create_package(File.join(@dir, 'missing-file.mpk'), @source, xml: missing_file_xml)
    expect { described_class.new(missing_file, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /declared package file is missing/)

    invalid_name = package_xml('Bad-Name', files: [])
    invalid_name_package = create_package(File.join(@dir, 'invalid-name.mpk'), @source, xml: invalid_name)
    expect { described_class.new(invalid_name_package, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /invalid module name/)

    invalid_manifest = create_package(
      File.join(@dir, 'invalid-manifest.mpk'), @source, manifest: '{broken'
    )
    expect { described_class.new(invalid_manifest, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /invalid module manifest/)
  end

  it 'validates package shape, inputs, and safe paths before mutating the MPR' do
    no_module = package_xml('MarketplaceModule', files: []).sub('<module name="MarketplaceModule" />', '')
    no_module_package = create_package(File.join(@dir, 'no-module.mpk'), @source, xml: no_module)
    expect { described_class.new(no_module_package, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /does not contain a Mendix module/)

    no_project = package_xml('MarketplaceModule', files: []).sub('<projectFile path="project.mpr" />', '')
    no_project_package = create_package(File.join(@dir, 'no-project.mpk'), @source, xml: no_project)
    expect { described_class.new(no_project_package, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /does not declare project/)

    missing_project = File.join(@dir, 'missing-project.mpk')
    Zip::File.open(missing_project, create: true) do |zip|
      zip.get_output_stream('package.xml') { _1.write(package_xml('MarketplaceModule', files: [])) }
    end
    expect { described_class.new(missing_project, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /package project not found/)

    unsupported = {
      'package' => { 'name' => 'MarketplaceModule', 'version' => '1', 'type' => 'Widget' },
      'model-version' => '11.12.1'
    }
    unsupported_package = create_package(
      File.join(@dir, 'unsupported.mpk'), @source, manifest: unsupported
    )
    expect { described_class.new(unsupported_package, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /unsupported marketplace package type/)

    unsafe = package_xml('MarketplaceModule', files: ['../outside'])
    unsafe_package = create_package(File.join(@dir, 'unsafe.mpk'), @source, xml: unsafe)
    expect { described_class.new(unsafe_package, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /unsafe package path/)

    expect { described_class.new(File.join(@dir, 'absent.mpk'), @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /package not found/)
    expect { described_class.new(@package, File.join(@dir, 'absent.mpr')).import! }
      .to raise_error(Mxrb::MarketplaceError, /MPR not found/)
    expect do
      described_class.new(@package, @target, target_root: File.join(@dir, 'absent')).import!
    end.to raise_error(Mxrb::MarketplaceError, /target root not found/)

    invalid_zip = File.join(@dir, 'invalid.mpk')
    File.write(invalid_zip, 'not a zip')
    expect { described_class.new(invalid_zip, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /invalid Mendix module package/)

    invalid_project = File.join(@dir, 'invalid-project.mpk')
    Zip::File.open(invalid_project, create: true) do |zip|
      zip.get_output_stream('project.mpr') { _1.write('not an MPR') }
      zip.get_output_stream('package.xml') { _1.write(package_xml('MarketplaceModule', files: [])) }
    end
    expect { described_class.new(invalid_project, @target).import! }.to raise_error(Mxrb::Error)

    absent_module_xml = package_xml('OtherModule', files: [])
    absent_module = create_package(File.join(@dir, 'absent-module.mpk'), @source, xml: absent_module_xml)
    expect { described_class.new(absent_module, @target).import! }
      .to raise_error(Mxrb::MarketplaceError, /absent from package MPR/)

    legacy = File.join(@dir, 'legacy.mpk')
    Zip::File.open(legacy, create: true) do |zip|
      zip.add('project.mpr', @source)
      zip.get_output_stream('package.xml') { _1.write(package_xml('MarketplaceModule', files: [])) }
    end
    Zip::File.open(legacy) do |archive|
      reader = Mxrb::OfficialMarketplace::ModulePackageReader.new(archive)
      expect(reader.descriptor.version).to eq('unknown')
      expect(reader.send(:elements, REXML::Document.new, 'module')).to eq([])
    end
  end

  it 'restores both overwritten and newly created assets on rollback' do
    target_root = File.dirname(@target)
    temporary = File.join(@dir, 'asset-transaction')
    FileUtils.mkdir_p(temporary)
    existing = File.join(target_root, 'assets', 'existing.txt')
    new_file = File.join(target_root, 'assets', 'new.txt')
    FileUtils.mkdir_p(File.dirname(existing))
    File.write(existing, 'before')
    staged_existing = File.join(temporary, 'existing.txt')
    staged_new = File.join(temporary, 'new.txt')
    File.write(staged_existing, 'after')
    File.write(staged_new, 'new')
    assets = Mxrb::OfficialMarketplace::ModulePackageAssets.new(target_root, temporary)
    assets.install('assets/existing.txt' => staged_existing, 'assets/new.txt' => staged_new)
    assets.rollback
    expect(File.read(existing)).to eq('before')
    expect(File).not_to exist(new_file)
    expect { assets.install('../outside' => staged_new) }
      .to raise_error(Mxrb::MarketplaceError, /unsafe asset destination/)
  end

  it 'integrates Installer cache, lockfile, and verification with an imported MPR' do
    root = File.dirname(@target)
    installation = Mxrb::OfficialMarketplace::Installer.new(target: root, mpr: @target)
                                                       .import(@package)
    expect(installation).to have_attributes(
      module_name: 'MarketplaceModule', units: 4, destination: @target
    )
    expect(File).to exist(installation.archive)
    lock = Mxrb::OfficialMarketplace.lock(root).dig('packages', 'MarketplaceModule')
    expect(lock).to include('kind' => 'module', 'version' => '2.3.0')
    expect(Mxrb::OfficialMarketplace.verify(root).dig('MarketplaceModule', :valid)).to be(true)

    File.write(installation.archive, 'changed')
    result = Mxrb::OfficialMarketplace.verify(root).fetch('MarketplaceModule')
    expect(result[:valid]).to be(false)
    expect(result[:module_present]).to be(true)

    FileUtils.rm_f(installation.archive)
    expect(Mxrb::OfficialMarketplace.verify(root).dig('MarketplaceModule', :actual)).to be_nil
    expect(Mxrb::OfficialMarketplace.module_present?('missing.mpr', 'Missing', nil)).to be(false)
    expect(Mxrb::OfficialMarketplace.module_present?(@target, 'MarketplaceModule', nil)).to be(true)
    invalid_mpr = File.join(root, 'invalid.mpr')
    File.write(invalid_mpr, 'invalid')
    expect(Mxrb::OfficialMarketplace.module_present?(invalid_mpr, 'Missing', nil)).to be(false)
    FileUtils.rm_f(File.join(root, 'widgets', 'marketplace-widget.mpk'))
    expect(Mxrb::OfficialMarketplace.verify(root).dig('MarketplaceModule', :files_present)).to be(false)
  end

  it 'covers cache integrity, target boundaries, ID collisions, and v2 cleanup' do
    installer = Mxrb::OfficialMarketplace::Installer.new(target: File.dirname(@target))
    package = Mxrb::OfficialMarketplace::Package.new(
      'MarketplaceModule', '2.3.0', :mpk, @package, nil
    )
    digest = Digest::SHA256.file(@package).hexdigest
    cached = installer.send(:cache_package, @package, package, digest)
    expect(installer.send(:cache_package, cached, package, digest)).to eq(cached)
    expect { installer.send(:cache_package, cached, package, 'wrong') }
      .to raise_error(Mxrb::MarketplaceError, /checksum mismatch/)
    expect { installer.send(:relative_target_path, File.join(@dir, 'outside.mpr')) }
      .to raise_error(Mxrb::MarketplaceError, /outside marketplace target/)

    importer = described_class.new(@package, @target)
    target = instance_double(Mxrb::IO::MprFile)
    allow(target).to receive_messages(units_by_containment: [], all_units: [{ 'UnitID' => 'collision' }])
    expect { importer.send(:validate_target!, target, 'Other', [{ 'UnitID' => 'collision' }]) }
      .to raise_error(Mxrb::MarketplaceError, /unit ID already exists/)

    mxunit = File.join(@dir, 'orphan.mxunit')
    File.write(mxunit, 'orphan')
    v2 = instance_double(Mxrb::IO::MprFile, format_version: :v2)
    allow(v2).to receive(:content_path).with('UnitID' => 'id').and_return(mxunit)
    importer.send(:cleanup_v2_units, v2, ['id'])
    expect(File).not_to exist(mxunit)
    expect(importer.send(:cleanup_v2_units, nil, [])).to be_nil
  end

  it 'downloads a public release and imports its MPK directly into the MPR' do
    client = instance_double(Mxrb::OfficialMarketplace::HttpClient)
    allow(client).to receive(:json).and_return(
      'tag_name' => 'v2.3.0',
      'assets' => [{
        'name' => 'MarketplaceModule.mpk',
        'browser_download_url' => 'https://example.test/MarketplaceModule.mpk'
      }]
    )
    allow(client).to receive(:download) do |_url, destination|
      FileUtils.cp(@package, destination)
      destination
    end

    result = Mxrb::OfficialMarketplace::Installer.new(
      target: File.dirname(@target), mpr: @target, client: client
    ).pull('github:mendix/MarketplaceModule')
    expect(result.module_name).to eq('MarketplaceModule')
    expect(Mxrb.validate(@target)).to be_valid
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength, Metrics/ParameterLists
