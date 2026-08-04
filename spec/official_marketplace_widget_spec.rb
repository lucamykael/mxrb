# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength, Metrics/ParameterLists
RSpec.describe Mxrb::OfficialMarketplace::WidgetPackageInstaller do
  def widget_package(path, version: '2.9.0', declared: 'com/mendix/widget/web/combobox/',
                     widget_id: 'com.mendix.widget.web.combobox.Combobox', name: 'Combobox',
                     runtime: true)
    package = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <package xmlns="http://www.mendix.com/package/1.0/">
        <clientModule name="#{name}" version="#{version}" xmlns="http://www.mendix.com/clientModule/1.0/">
          <widgetFiles><widgetFile path="Combobox.xml" /></widgetFiles>
          <files><file path="#{declared}" /></files>
        </clientModule>
      </package>
    XML
    widget = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <widget id="#{widget_id}" pluginWidget="true" xmlns="http://www.mendix.com/widget/1.0/">
        <name>Combo box</name>
      </widget>
    XML
    Zip::File.open(path, create: true) do |zip|
      zip.get_output_stream('package.xml') { _1.write(package) }
      zip.get_output_stream('Combobox.xml') { _1.write(widget) }
      runtime_path = File.join(declared.delete_suffix('/'), "#{name}.mjs")
      zip.get_output_stream(runtime_path) { _1.write('export {};') } if runtime
    end
    path
  end

  def data_widgets_package(path, source, nested_widget)
    package = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <package xmlns="http://www.mendix.com/package/1.0/">
        <modelerProject xmlns="http://www.mendix.com/modelerProject/1.0/">
          <module name="DataWidgets" />
          <projectFile path="project.mpr" />
          <files><file path="widgets/com.mendix.widget.web.Datagrid.mpk" /></files>
        </modelerProject>
      </package>
    XML
    manifest = {
      'package' => { 'name' => 'DataWidgets', 'version' => '3.11.3', 'type' => 'Module' },
      'model-version' => '11.12.1'
    }
    Zip::File.open(path, create: true) do |zip|
      zip.add('project.mpr', source)
      zip.add('widgets/com.mendix.widget.web.Datagrid.mpk', nested_widget)
      zip.get_output_stream('package.xml') { _1.write(package) }
      zip.get_output_stream('manifest.json') { _1.write(JSON.generate(manifest)) }
    end
    path
  end

  def module_widget_package(path, source, nested_widget)
    package = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <package xmlns="http://www.mendix.com/package/1.0/">
        <modelerProject xmlns="http://www.mendix.com/modelerProject/1.0/">
          <module name="Atlas_Core" />
          <projectFile path="project.mpr" />
          <files><file path="widgets/com.mendix.widget.web.Combobox.mpk" /></files>
        </modelerProject>
      </package>
    XML
    manifest = {
      'package' => { 'name' => 'Atlas_Core', 'version' => '4.3.7', 'type' => 'Module' },
      'model-version' => '11.12.1'
    }
    Zip::File.open(path, create: true) do |zip|
      zip.add('project.mpr', source)
      zip.add('widgets/com.mendix.widget.web.Combobox.mpk', nested_widget)
      zip.get_output_stream('package.xml') { _1.write(package) }
      zip.get_output_stream('manifest.json') { _1.write(JSON.generate(manifest)) }
    end
    path
  end

  def official_package(type: 'Widget', version: '2.9.0')
    Mxrb::OfficialMarketplace::OfficialPackage.new(
      'Combo box', version, :mendix, 'https://marketplace-api.test/download',
      'content:219304', 219_304, '123e4567-e89b-12d3-a456-426614174000',
      type, 'Regular', [], false, true
    )
  end

  def archive_with_entries(name, entries)
    path = File.join(@root, name)
    Zip::File.open(path, create: true) do |zip|
      entries.each { |entry, contents| zip.get_output_stream(entry) { _1.write(contents) } }
    end
    path
  end

  def write_marketplace_lock(packages)
    path = File.join(@root, '.mxrb', 'marketplace.lock.json')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate('packages' => packages))
  end

  def client_package_xml(name:, version:, widgets:)
    declarations = widgets.map { %(<widgetFile path="#{_1}"/>) }.join
    "<package><clientModule name=\"#{name}\" version=\"#{version}\">#{declarations}</clientModule></package>"
  end

  before do
    @root = Dir.mktmpdir('mxrb-widget-install-')
    @archive = widget_package(File.join(@root, 'source.mpk'))
  end

  after { FileUtils.remove_entry(@root) }

  it 'installs an authenticated official widget as an opaque project MPK and verifies both copies' do
    result = described_class.new(target: @root).install(@archive, official_package)
    expect(result).to have_attributes(
      widget_name: 'Combobox',
      widget_ids: ['com.mendix.widget.web.combobox.Combobox'],
      destination: File.join(@root, 'widgets', 'com.mendix.widget.web.Combobox.mpk')
    )
    expect(Digest::SHA256.file(result.destination).hexdigest).to eq(result.sha256)
    expect(Digest::SHA256.file(result.archive).hexdigest).to eq(result.sha256)

    entry = Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'Combo box')
    expect(entry).to include(
      'kind' => 'widget', 'content_id' => 219_304, 'version' => '2.9.0',
      'widget_name' => 'Combobox',
      'widget_ids' => ['com.mendix.widget.web.combobox.Combobox']
    )
    verification = Mxrb::OfficialMarketplace.verify(@root).fetch('Combo box')
    expect(verification[:valid]).to be(true)

    File.binwrite(result.destination, 'changed')
    expect(Mxrb::OfficialMarketplace.verify(@root).dig('Combo box', :valid)).to be(false)
  end

  it 'downloads Widget content with the authenticated API and routes it by package structure' do
    api = instance_double(Mxrb::OfficialMarketplace::ContentApi, resolve: official_package)
    allow(api).to receive(:download) do |_version_id, destination, **|
      FileUtils.cp(@archive, destination)
      destination
    end
    mpr = File.join(@root, 'App.mpr')
    File.write(mpr, 'mpr boundary is detected separately')
    installer = Mxrb::OfficialMarketplace::Installer.new(target: @root, mpr:)
    allow(installer).to receive(:detect_mendix_version).and_return('11.12.1')

    result = installer.pull_official('219304', api:)
    expect(result).to be_a(Mxrb::OfficialMarketplace::WidgetInstallation)
    expect(api).to have_received(:download).with(
      official_package.version_id, end_with('package.mpk'), download_url: official_package.download_url
    )
  end

  it 'fails closed on metadata/structure and version identity mismatches' do
    installer = Mxrb::OfficialMarketplace::Installer.new(target: @root)
    expect do
      installer.send(:install_official_archive, @archive, official_package(type: 'Module'), __FILE__)
    end.to raise_error(Mxrb::MarketplaceError, /Module archive declares a clientModule/)
    expect do
      described_class.new(target: @root).install(@archive, official_package(version: '3.0.0'))
    end.to raise_error(Mxrb::MarketplaceError, /does not match Marketplace/)
    unsupported = official_package(type: 'Template')
    expect { installer.validate_official_package!(unsupported) }
      .to raise_error(Mxrb::MarketplaceError, /not a Module, Service, or Widget/)
    allow(Mxrb::OfficialMarketplace::PackageEnvelope).to receive(:kind).and_return(:unknown)
    expect { installer.send(:install_official_archive, @archive, official_package, __FILE__) }
      .to raise_error(Mxrb::MarketplaceError, /unsupported official/)
    expect(Mxrb::OfficialMarketplace.lock(@root).fetch('packages')).to be_empty
    expect(Dir.glob(File.join(@root, 'widgets', '*.mpk'))).to be_empty
  end

  it 'rejects incomplete, divergent, and unsafe widget envelopes without residue' do
    missing = widget_package(
      File.join(@root, 'missing.mpk'), declared: 'missing/runtime/', runtime: false
    )
    expect { described_class.new(target: @root).install(missing, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /declared widget file is missing/)

    divergent = widget_package(File.join(@root, 'divergent.mpk'), widget_id: 'invalid')
    expect { described_class.new(target: @root).install(divergent, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /invalid widget ID/)

    unsafe = File.join(@root, 'unsafe.mpk')
    Zip::File.open(unsafe, create: true) do |zip|
      zip.get_output_stream('../package.xml') { _1.write('<package/>') }
    end
    expect { Mxrb::OfficialMarketplace::WidgetPackageInventory.read(unsafe) }
      .to raise_error(Mxrb::MarketplaceError, /unsafe widget package path/)
    expect(Mxrb::OfficialMarketplace.lock(@root).fetch('packages')).to be_empty
  end

  it 'rejects malformed package envelopes and every unproven widget identity boundary' do
    envelope = Mxrb::OfficialMarketplace::PackageEnvelope
    inventory = Mxrb::OfficialMarketplace::WidgetPackageInventory
    missing = archive_with_entries('no-package.mpk', 'readme.txt' => 'x')
    unknown = archive_with_entries('unknown.mpk', 'package.xml' => '<package/>')
    rootless = archive_with_entries('rootless.mpk', 'package.xml' => '')
    broken = File.join(@root, 'broken.mpk')
    File.write(broken, 'not zip')
    expect { envelope.kind(missing) }.to raise_error(Mxrb::MarketplaceError, /package.xml is missing/)
    expect { envelope.kind(unknown) }.to raise_error(Mxrb::MarketplaceError, /does not declare/)
    expect { envelope.kind(rootless) }.to raise_error(Mxrb::MarketplaceError, /does not declare/)
    expect { envelope.kind(broken) }.to raise_error(Mxrb::MarketplaceError, /invalid Mendix package/)
    expect { inventory.read(missing) }.to raise_error(Mxrb::MarketplaceError, /package.xml is missing/)
    expect { inventory.read(unknown) }.to raise_error(Mxrb::MarketplaceError, /exactly one clientModule/)

    no_widgets = archive_with_entries('no-widgets.mpk', {
      'package.xml' => '<package><clientModule name="Widget" version="1.0.0"/></package>'
    })
    expect { inventory.read(no_widgets) }.to raise_error(Mxrb::MarketplaceError, /does not declare widgetFiles/)

    invalid_name = archive_with_entries('invalid-name.mpk', {
      'package.xml' => client_package_xml(name: '123', version: '1', widgets: ['A.xml']),
      'A.xml' => '<widget id="org.example.a.A"/>'
    })
    expect { inventory.read(invalid_name) }.to raise_error(Mxrb::MarketplaceError, /clientModule name/)
    invalid_version = archive_with_entries('invalid-version.mpk', {
      'package.xml' => client_package_xml(name: 'A', version: '', widgets: ['A.xml']),
      'A.xml' => '<widget id="org.example.a.A"/>'
    })
    expect { inventory.read(invalid_version) }.to raise_error(Mxrb::MarketplaceError, /clientModule version/)
    missing_definition = archive_with_entries('missing-definition.mpk', {
      'package.xml' => client_package_xml(name: 'A', version: '1', widgets: ['Missing.xml'])
    })
    expect { inventory.read(missing_definition) }.to raise_error(Mxrb::MarketplaceError, /definition is missing/)
    non_xml = archive_with_entries('non-xml.mpk', {
      'package.xml' => client_package_xml(name: 'A', version: '1', widgets: ['A.js']),
      'A.js' => 'x'
    })
    expect { inventory.read(non_xml) }.to raise_error(Mxrb::MarketplaceError, /is not XML/)
    malformed = archive_with_entries('malformed.mpk', 'package.xml' => '<package')
    expect { inventory.read(malformed) }.to raise_error(Mxrb::MarketplaceError, /invalid Mendix widget package/)
  end

  it 'rejects duplicate, linked, non-widget, and divergent widget definitions' do
    inventory = Mxrb::OfficialMarketplace::WidgetPackageInventory
    duplicate = archive_with_entries('duplicate.mpk', {
      'package.xml' => client_package_xml(name: 'A', version: '1', widgets: ['A.xml']),
      'A.xml' => '<widget id="org.example.a.A"/>',
      'a.XML' => '<widget id="org.example.a.A"/>'
    })
    expect { inventory.read(duplicate) }.to raise_error(Mxrb::MarketplaceError, /duplicate widget package path/)

    linked = double(name: 'linked.xml', directory?: false, symlink?: true)
    fake_archive = double
    allow(fake_archive).to receive(:each).and_yield(linked)
    expect { inventory.send(:validate_entries!, fake_archive) }
      .to raise_error(Mxrb::MarketplaceError, /symbolic link/)

    wrong_root = archive_with_entries('wrong-root.mpk', {
      'package.xml' => client_package_xml(name: 'A', version: '1', widgets: ['A.xml']),
      'A.xml' => '<notWidget id="org.example.a.A"/>'
    })
    expect { inventory.read(wrong_root) }.to raise_error(Mxrb::MarketplaceError, /invalid widget ID/)
    rootless_widget = archive_with_entries('rootless-widget.mpk', {
      'package.xml' => client_package_xml(name: 'A', version: '1', widgets: ['A.xml']),
      'A.xml' => ''
    })
    expect { inventory.read(rootless_widget) }.to raise_error(Mxrb::MarketplaceError, /invalid widget ID/)

    divergent = archive_with_entries('namespaces.mpk', {
      'package.xml' => client_package_xml(name: 'A', version: '1', widgets: %w[A.xml B.xml]),
      'A.xml' => '<widget id="org.example.a.A"/>',
      'B.xml' => '<widget id="org.other.b.B"/>'
    })
    expect { inventory.read(divergent) }.to raise_error(Mxrb::MarketplaceError, /do not share/)
    expect(inventory.send(:elements, nil, 'widget')).to eq([])
    expect { inventory.send(:safe_relative_path, "bad\0.xml") }
      .to raise_error(Mxrb::MarketplaceError, /unsafe/)
  end

  it 'rolls back widget, cache, and lock when the transaction cannot complete' do
    installer = described_class.new(target: @root)
    allow(installer).to receive(:write_lock).and_raise(Mxrb::MarketplaceError, 'lock failed')
    expect { installer.install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /lock failed/)
    expect(Dir.glob(File.join(@root, 'widgets', '*.mpk'))).to be_empty
    expect(Dir.glob(File.join(@root, '.mxrb', 'marketplace', '*.mpk'))).to be_empty
    expect(File).not_to exist(File.join(@root, '.mxrb', 'marketplace.lock.json'))
  end

  it 'rejects existing and symlinked destinations before writing a lock or cache' do
    widgets = File.join(@root, 'widgets')
    external = Dir.mktmpdir('mxrb-widget-external-')
    File.symlink(external, widgets)
    expect { described_class.new(target: @root).install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /symbolic link/)
    expect(Dir.children(external)).to be_empty
  ensure
    FileUtils.remove_entry(external) if external && File.directory?(external)
  end

  it 'fails closed on unsafe target, cache, lock, checksum, and installed-widget states' do
    missing = File.join(@root, 'missing')
    expect { described_class.new(target: missing).install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /target not found/)

    external = Dir.mktmpdir('mxrb-target-')
    linked_target = File.join(@root, 'linked-target')
    File.symlink(external, linked_target)
    expect { described_class.new(target: linked_target).install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /target is a symbolic link/)

    destination = File.join(@root, 'widgets', 'com.mendix.widget.web.Combobox.mpk')
    FileUtils.mkdir_p(destination)
    expect { described_class.new(target: @root).install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /destination is a directory/)
    FileUtils.rm_rf(destination)

    FileUtils.mkdir_p(File.dirname(destination))
    linked_file = File.join(external, 'widget.mpk')
    File.write(linked_file, 'widget')
    File.symlink(linked_file, destination)
    expect { described_class.new(target: @root).install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /destination is a symbolic link/)
    FileUtils.rm_f(destination)

    cache = File.join(@root, '.mxrb', 'marketplace', 'com.mendix.widget.web.Combobox-2.9.0.mpk')
    FileUtils.mkdir_p(File.dirname(cache))
    File.write(cache, 'occupied')
    expect { described_class.new(target: @root).install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /cache destination already exists/)
    FileUtils.rm_f(cache)

    installer = described_class.new(target: @root)
    expect { installer.send(:verify_copy!, @archive, 'wrong') }
      .to raise_error(Mxrb::MarketplaceError, /checksum mismatch/)
    expect { installer.send(:safe_path, '../outside') }
      .to raise_error(Mxrb::MarketplaceError, /outside marketplace target/)
    expect(installer.send(:locked_asset_digest, { 'kind' => 'legacy' }, 'widgets/x.mpk')).to be_nil
    expect(installer.send(:locked_asset_digest, {
      'kind' => 'widget', 'destination' => 'widgets/x.mpk', 'sha256' => 'digest'
    }, 'widgets/x.mpk')).to eq('digest')
  ensure
    FileUtils.remove_entry(external) if external && File.directory?(external)
  end

  it 'rejects corrupt or conflicting current widget locks and verifies corrupt archives safely' do
    installer = described_class.new(target: @root)
    destination = File.join(@root, 'widgets', 'com.mendix.widget.web.Combobox.mpk')
    relative = 'widgets/com.mendix.widget.web.Combobox.mpk'
    expect { installer.send(:validate_current!, ['Combo box', { 'kind' => 'module' }], official_package, destination) }
      .to raise_error(Mxrb::MarketplaceError, /is not a widget/)
    expect do
      installer.send(
        :validate_current!, ['Combo box', { 'kind' => 'widget', 'destination' => 'widgets/other.mpk' }],
        official_package, destination
      )
    end.to raise_error(Mxrb::MarketplaceError, /changed its destination/)
    invalid = {
      'kind' => 'widget', 'destination' => relative, 'archive' => 'missing.mpk',
      'sha256' => 'x', 'widget_name' => 'Combobox', 'widget_ids' => []
    }
    expect { installer.send(:validate_current!, ['Combo box', invalid], official_package, destination) }
      .to raise_error(Mxrb::MarketplaceError, /failed verification/)

    installed = installer.install(@archive, official_package)
    entry = Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'Combo box')
    expect { installer.send(:validate_current!, ['Combo box', entry], official_package, destination) }
      .to raise_error(Mxrb::MarketplaceError, /already installed/)
    newer = official_package(version: '3.0.0')
    lock_path = File.join(@root, '.mxrb', 'marketplace.lock.json')
    expect(installer.send(
             :validate_boundaries!, newer, destination, installed.archive, lock_path
           )).to be_a(Array)

    entry['widget_name'] = 'Other'
    expect(Mxrb::OfficialMarketplace.verify_widget(@root, entry)[:valid]).to be(false)
    entry['widget_name'] = 'Combobox'
    entry['widget_ids'] = []
    expect(Mxrb::OfficialMarketplace.verify_widget(@root, entry)[:valid]).to be(false)
    entry['widget_ids'] = ['com.mendix.widget.web.combobox.Combobox']

    missing_destination = entry.merge(
      'destination' => 'widgets/missing.mpk', 'widget_name' => nil, 'widget_ids' => []
    )
    expect(Mxrb::OfficialMarketplace.verify_widget(@root, missing_destination)[:valid]).to be(false)

    File.binwrite(installed.destination, 'not zip')
    File.binwrite(installed.archive, 'not zip')
    digest = Digest::SHA256.file(installed.destination).hexdigest
    lock = Mxrb::OfficialMarketplace.lock(@root)
    lock['packages']['Combo box']['sha256'] = digest
    write_marketplace_lock(lock.fetch('packages'))
    expect(Mxrb::OfficialMarketplace.verify(@root).dig('Combo box', :valid)).to be(false)
  end

  it 'discovers a missing WidgetId through a verified official mapping and installs its bundle' do
    datagrid_id = 'com.mendix.widget.web.datagrid.Datagrid'
    source = File.join(@root, 'data-widgets.mpr')
    target = File.join(@root, 'App.mpr')
    Mxrb.define(source) do
      mendix_version '11.12.1'
      self.module(:DataWidgets)
    end
    Mxrb.define(target) do
      mendix_version '11.12.1'
      self.module(:App)
    end
    nested = widget_package(
      File.join(@root, 'datagrid.mpk'), version: '3.11.3',
                                        declared: 'com/mendix/widget/web/datagrid/',
                                        widget_id: datagrid_id, name: 'Datagrid'
    )
    bundle = data_widgets_package(File.join(@root, 'data-widgets.mpk'), source, nested)
    package = Mxrb::OfficialMarketplace::OfficialPackage.new(
      'Data Widgets', '3.11.3', :mendix, 'https://marketplace-api.test/data-widgets',
      'content:116540', 116_540, '123e4567-e89b-12d3-a456-426614174001',
      'Module', 'Regular', [], false, true
    )
    api = instance_double(Mxrb::OfficialMarketplace::ContentApi)
    allow(api).to receive(:resolve).with(116_540, mendix_version: '11.12.1').and_return(package)
    allow(api).to receive(:download) do |_version_id, destination, **|
      FileUtils.cp(bundle, destination)
      destination
    end
    installer = Mxrb::OfficialMarketplace::Installer.new(target: @root, mpr: target)
    resolver = Mxrb::OfficialMarketplace::DependencyResolver.new(
      target: @root, mpr: target, installer:, api:, mendix_version: '11.12.1'
    )

    Dir.mktmpdir do |temporary|
      resolver.instance_variable_set(:@temporary, temporary)
      resolver.instance_variable_set(:@required_widget_ids, [datagrid_id])
      dependencies = resolver.send(:resolve_widget_dependencies)
      expect(dependencies.map(&:required_ids)).to eq([[datagrid_id]])
      expect(dependencies.first.widget_ids).to include(datagrid_id)
      resolver.send(:apply_dependencies, [], dependencies)
    end

    expect(Mxrb::WidgetPackage.find(@root, datagrid_id)).not_to be_nil
    expect(Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'DataWidgets', 'content_id'))
      .to eq(116_540)
    expect(Mxrb::OfficialMarketplace.verify(@root).dig('DataWidgets', :valid)).to be(true)
  end

  it 'reports unknown, unavailable, locked, and identity-mismatched WidgetId dependencies' do
    target = File.join(@root, 'App.mpr')
    Mxrb.define(target) do
      mendix_version '11.12.1'
      self.module(:App)
    end
    api = instance_double(Mxrb::OfficialMarketplace::ContentApi)
    allow(api).to receive(:resolve)
    installer = Mxrb::OfficialMarketplace::Installer.new(target: @root, mpr: target)
    resolver = Mxrb::OfficialMarketplace::DependencyResolver.new(
      target: @root, mpr: target, installer:, api:, mendix_version: '11.12.1'
    )
    resolver.instance_variable_set(:@required_widget_ids, ['org.example.unknown.Widget'])
    expect(resolver.send(:resolve_widget_dependencies)).to eq([])
    expect(resolver.instance_variable_get(:@blockers).join).to include('no verified official')

    datagrid_id = 'com.mendix.widget.web.datagrid.Datagrid'
    resolver.instance_variable_set(:@required_widget_ids, [datagrid_id])
    allow(api).to receive(:resolve).and_raise(Mxrb::MarketplaceError, 'API unavailable')
    expect(resolver.send(:resolve_widget_dependencies)).to eq([])
    expect(resolver.instance_variable_get(:@blockers).join).to include('API unavailable')

    write_marketplace_lock('Existing' => { 'content_id' => 116_540 })
    expect { resolver.send(:resolve_widget_dependency, 116_540, [datagrid_id]) }
      .to raise_error(Mxrb::MarketplaceError, /locked official package/)

    write_marketplace_lock({})
    wrong = official_package
    allow(api).to receive(:resolve).and_return(wrong)
    Dir.mktmpdir do |temporary|
      resolver.instance_variable_set(:@temporary, temporary)
      allow(api).to receive(:download) do |_version_id, destination, **|
        FileUtils.cp(@archive, destination)
        destination
      end
      expect { resolver.send(:resolve_widget_dependency, 116_540, [datagrid_id]) }
        .to raise_error(Mxrb::MarketplaceError, /does not provide/)
    end
    expect(resolver.send(:collect_widget_ids, {
      'WidgetId' => 'one.Widget', 'Nested' => [{ 'WidgetId' => 'two.Widget' }]
    })).to contain_exactly('one.Widget', 'two.Widget')
    expect(resolver.send(:collect_widget_ids, 'plain')).to eq([])
  end

  it 'reuses verified widget downloads, reports plan changes, and skips already installed content' do
    target = File.join(@root, 'App.mpr')
    Mxrb.define(target) do
      mendix_version '11.12.1'
      self.module(:App)
    end
    api = instance_double(Mxrb::OfficialMarketplace::ContentApi)
    allow(api).to receive(:resolve)
    installer = Mxrb::OfficialMarketplace::Installer.new(target: @root, mpr: target)
    resolver = Mxrb::OfficialMarketplace::DependencyResolver.new(
      target: @root, mpr: target, installer:, api:, mendix_version: '11.12.1'
    )
    dependency = Mxrb::OfficialMarketplace::Dependency.new(
      'Unused', official_package, @archive, []
    )
    installed_dependency = Mxrb::OfficialMarketplace::Dependency.new(
      'Installed', nil, @archive, []
    )
    resolver.instance_variable_set(
      :@resolved, 'Installed' => installed_dependency, 'Unused' => dependency
    )
    combo_id = 'com.mendix.widget.web.combobox.Combobox'
    resolved = resolver.send(:resolve_widget_dependency, 219_304, [combo_id])
    expect(resolved.widget_ids).to eq([combo_id])
    expect(api).not_to have_received(:resolve)
    expect(resolver.send(:package_asset_paths, @archive))
      .to eq(['widgets/com.mendix.widget.web.Combobox.mpk'])

    plan = Mxrb::OfficialMarketplace::DependencyPlan.new(
      root: 'App', dependencies: [], widget_dependencies: [resolved], blockers: []
    )
    expect(plan.changes).to eq(['install widget bundle Combo box 2.9.0'])

    write_marketplace_lock('Existing' => { 'content_id' => 219_304 })
    expect(installer).not_to receive(:install_official_archive)
    resolver.send(:apply_dependencies, [], [resolved])
  end

  it 'fails closed when bundle enumeration cannot read a structurally selected module' do
    allow(Mxrb::OfficialMarketplace::PackageEnvelope).to receive(:kind).and_return(:module)
    allow(Mxrb::OfficialMarketplace::ModulePackageInventory).to receive(:read).and_return(double)
    allow(Zip::File).to receive(:open).and_raise(Zip::Error, 'broken nested package')
    expect { Mxrb::OfficialMarketplace::WidgetBundleInventory.read(@archive) }
      .to raise_error(Mxrb::MarketplaceError, /invalid Mendix widget bundle/)
  end

  it 'renames a content-ID matched widget lock during an official upgrade' do
    installer = described_class.new(target: @root)
    installer.install(@archive, official_package)
    lock = Mxrb::OfficialMarketplace.lock(@root)
    lock['packages']['Alias'] = lock['packages'].delete('Combo box')
    write_marketplace_lock(lock.fetch('packages'))
    newer_archive = widget_package(File.join(@root, 'combo-3.0.0.mpk'), version: '3.0.0')
    installer.install(newer_archive, official_package(version: '3.0.0'))
    expect(Mxrb::OfficialMarketplace.lock(@root).fetch('packages').keys).to eq(['Combo box'])
  end

  it 'upgrades a module-owned widget transactionally and protects shared ownership' do
    target = File.join(@root, 'App.mpr')
    atlas_source = File.join(@root, 'Atlas.mpr')
    Mxrb.define(target) do
      mendix_version '11.12.1'
      self.module(:App)
    end
    Mxrb.define(atlas_source) do
      mendix_version '11.12.1'
      self.module(:Atlas_Core)
    end
    old_widget = widget_package(File.join(@root, 'combo-2.6.2.mpk'), version: '2.6.2')
    atlas_archive = module_widget_package(
      File.join(@root, 'atlas.mpk'), atlas_source, old_widget
    )
    atlas = Mxrb::OfficialMarketplace::OfficialPackage.new(
      'Atlas Core', '4.3.7', :mendix, nil, 'content:117187', 117_187,
      '123e4567-e89b-12d3-a456-426614174002', 'Module', 'Regular', [], false, true
    )
    module_installer = Mxrb::OfficialMarketplace::Installer.new(target: @root, mpr: target)
    module_installer.send(:import_module, atlas_archive, atlas, target)
    destination = File.join(@root, 'widgets', 'com.mendix.widget.web.Combobox.mpk')
    old_digest = Digest::SHA256.file(destination).hexdigest

    widget_installer = described_class.new(target: @root)
    File.binwrite(destination, 'locally changed')
    expect { widget_installer.install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /owned widget asset changed/)
    FileUtils.cp(old_widget, destination)

    atlas_entry = Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'Atlas_Core')
    cached_atlas = File.join(@root, atlas_entry.fetch('archive'))
    FileUtils.mv(cached_atlas, "#{cached_atlas}.held")
    expect { widget_installer.install(@archive, official_package) }
      .to raise_error(Mxrb::MarketplaceError, /cached Marketplace package is missing/)
    FileUtils.mv("#{cached_atlas}.held", cached_atlas)

    current = widget_installer.install(@archive, official_package)
    entry = Mxrb::OfficialMarketplace.lock(@root).dig('packages', 'Combo box')
    backup = File.join(@root, entry.fetch('asset_original'))
    expect(Digest::SHA256.file(backup).hexdigest).to eq(old_digest)
    expect(entry.fetch('files')).to eq(['widgets/com.mendix.widget.web.Combobox.mpk'])

    newer_archive = widget_package(File.join(@root, 'combo-3.0.0.mpk'), version: '3.0.0')
    newer = official_package(version: '3.0.0')
    upgraded = widget_installer.install(newer_archive, newer)
    expect(upgraded.sha256).not_to eq(current.sha256)
    expect(Digest::SHA256.file(backup).hexdigest).to eq(old_digest)
    expect(File).not_to exist(current.archive)

    failing_archive = widget_package(File.join(@root, 'combo-3.1.0.mpk'), version: '3.1.0')
    failing = described_class.new(target: @root)
    allow(failing).to receive(:write_lock).and_raise(Mxrb::MarketplaceError, 'lock failed')
    expect { failing.install(failing_archive, official_package(version: '3.1.0')) }
      .to raise_error(Mxrb::MarketplaceError, /lock failed/)
    expect(Digest::SHA256.file(destination).hexdigest).to eq(upgraded.sha256)
    expect(Mxrb::OfficialMarketplace.verify(@root).dig('Combo box', :valid)).to be(true)

    assets = Mxrb::OfficialMarketplace::ModulePackageAssets.new(@root, @root)
    assets.install({ 'widgets/com.mendix.widget.web.Combobox.mpk' => old_widget }, [
                     'widgets/com.mendix.widget.web.Combobox.mpk'
                   ])
    expect(Digest::SHA256.file(destination).hexdigest).to eq(upgraded.sha256)

    removal = module_installer.remove('Atlas_Core', apply: true)
    expect(removal).to be_safe
    expect(Digest::SHA256.file(destination).hexdigest).to eq(upgraded.sha256)
    expect(Mxrb::OfficialMarketplace.verify(@root).dig('Combo box', :valid)).to be(true)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength, Metrics/ParameterLists
