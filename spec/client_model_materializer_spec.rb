# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::ClientModelMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      define_project
      prepare_model
      example.run
    end
  end

  def define_project
    Mxrb.define(@mpr) do
      mendix_version '11.12.1'
      security { user_role :User, module_roles: ['App.User'] }
      navigation { profile :Responsive, home_page: 'App.Home', app_title: 'Sample' }
      self.module(:App) do
        module_role :User
        entity(:Base) { string :Name }
        entity(:Item) { generalizes 'App.Base' }
        entity(:Account) { generalizes 'System.User' }
        layout :Shell
        page(:Home) do
          layout 'App.Shell'
          allowed_roles 'App.User'
        end
      end
    end
  end

  def prepare_model
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    project = source.units_of('Projects$Project').first.document
    navigation = source.units_of('Navigation$NavigationDocument').first.document
    profile = Mxrb::IO::BsonCodec.parse_array(navigation['Profiles'])[:items].first
    runtime_navigation = {
      '$ID' => navigation['$ID'], '$Type' => navigation['$Type'],
      'Profiles' => [{
        '$ID' => profile['$ID'], '$Type' => profile['$Type'],
        'OfflineEntityConfigsRuntime' => [], 'AppIcon' => 'existing.svg'
      }],
      'Grids' => ['grid'], 'CustomWidgetModules' => ['module'], 'PluginWidgets' => ['widget']
    }
    path = File.join(@deployment, 'model', 'model.mdp')
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, [
      { '$ID' => project['$ID'], '$Type' => project['$Type'] }, runtime_navigation
    ].map { Mxrb::IO::BsonCodec.serialize(_1) }.join)
  end

  it 'materializes page authorization and navigation while preserving widget inventories' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    package = Mxrb::Compiler::ModelPackage.read(result.model_path)
    page = package.documents.find { _1['$Type'] == 'Forms$Page' }
    navigation = package.documents.find { _1['$Type'] == 'Navigation$NavigationDocument' }

    expect(result).to have_attributes(pages: 1, navigation_documents: 1)
    expect(page).to include('QualifiedName' => 'App.Home', 'ModelerAllowedUserRoles' => ['User'])
    expect(page.keys).to eq(
      %w[$ID $Type Parameters Title UrlSegments Name QualifiedName ModelerAllowedUserRoles
         PopupWidth PopupHeight PopupResizable Url]
    )
    expect(navigation).to include('Grids' => ['grid'], 'CustomWidgetModules' => [], 'PluginWidgets' => [])
    expect(navigation.dig('Profiles', 0)).to include(
      'Name' => 'Responsive', 'IsOffline' => false, 'AppIcon' => 'existing.svg'
    )
    expect(navigation.dig('Profiles', 0, 'HomePage')).to include('Page' => 'App.Home')
  end

  it 'compiles page parameters and splits the URL into segments as MxBuild does' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    parameter = lambda do |name, type, entity = nil|
      { '$ID' => "11111111-1111-4111-8111-#{name.ljust(12, '1')}", '$Type' => 'Forms$PageParameter', 'Name' => name,
        'ParameterType' => { '$ID' => "22222222-2222-4222-8222-#{name.ljust(12, '2')}", '$Type' => "DataTypes$#{type}",
                             'Entity' => entity }.compact }
    end
    item = parameter.call('Item', 'ObjectType', 'App.Item')
    account = parameter.call('Account', 'ObjectType', 'App.Account')
    mode = parameter.call('Mode', 'StringType')
    compiler = Mxrb::Compiler::PageDocumentCompiler.new(source)
    compile = lambda do |url, *parameters|
      compiler.compile(unit.with(document: unit.document.merge('Parameters' => parameters, 'Url' => url)))
    end
    expect(compiler.send(:text_reference, nil)).to be_nil
    page = compile.call('items/{Item}/edit/{Mode}', item, mode)
    expect(page['UrlSegments'].map { _1.except('$ID') }).to eq(
      [{ '$Type' => 'Url$StaticUrlSegment', 'Segment' => 'items/' },
       { '$Type' => 'Forms$ParameterIdUrlSegment', 'PageParameter' => 'Item' },
       { '$Type' => 'Url$StaticUrlSegment', 'Segment' => '/edit/' },
       { '$Type' => 'Forms$PagePrimitiveParameterUrlSegment', 'PageParameter' => 'Mode' }]
    )
    expect(page['UrlSegments'].map { _1['$ID'] }).to all(match(/\A\h{8}-\h{4}-4\h{3}-8\h{3}-\h{12}\z/))
    expect(page['Parameters'].first).to include('ParameterTypeRuntime' => 'App.Item', 'IsRequired' => false)
    by_attribute = compile.call('items/{Item/Name}/{Account/Name}/{Account/Phone}', item, account)
    expect(by_attribute['UrlSegments'].select { _1['Attribute'] }.map { _1['Attribute'] })
      .to eq(%w[App.Base.Name System.User.Name App.Account.Phone])
    expect(compile.call('', item)['UrlSegments']).to eq([])
    untyped = { '$ID' => '99999999-9999-4999-8999-999999999999', '$Type' => 'Forms$PageParameter', 'Name' => 'Raw' }
    expect(compile.call('{Raw}', untyped)['UrlSegments'].first)
      .to include('$Type' => 'Forms$PagePrimitiveParameterUrlSegment', 'PageParameter' => 'Raw')
    stranger = parameter.call('Zed', 'ObjectType', 'Zed.Unknown')
    expect(compile.call('{Zed/Attr}', stranger)['UrlSegments'].first).to include('Attribute' => 'Zed.Unknown.Attr')
    segments = compiler.instance_variable_get(:@url_segments)
    segments.instance_variable_set(:@entities, { 'A.A' => { attributes: [], generalization: 'A.B' },
                                                 'A.B' => { attributes: [], generalization: 'A.A' } })
    expect(segments.send(:declaring_entity, 'A.A', 'Missing')).to eq('A.A')
    expect { compile.call('items/{Missing}', item) }
      .to raise_error(Mxrb::CompilationError, /URL of page Home names no parameter Missing/)
    expect { compiler.compile(unit.with(document: unit.document.merge('$Type' => 'Forms$Snippet'))) }
      .to raise_error(Mxrb::CompilationError, /unsupported page root/)
    no_security = Struct.new(:unused) { def documents(_type) = [] }.new
    expect(Mxrb::Compiler::PageDocumentCompiler.new(no_security))
      .to be_a(Mxrb::Compiler::PageDocumentCompiler)
  end

  it 'writes only the name of a page parameter before Mendix 11, as MxBuild does' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    parameter = { '$ID' => '11111111-1111-4111-8111-111111111111', '$Type' => 'Forms$PageParameter', 'Name' => 'Item',
                  'ParameterType' => { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'App.Item' },
                  'IsRequired' => true }
    page = unit.with(document: unit.document.merge('Parameters' => [parameter]))

    modern = Mxrb::Compiler::PageDocumentCompiler.new(source).compile(page)
    expect(modern['Parameters'].first.keys).to eq(%w[$ID $Type Name ParameterTypeRuntime IsRequired])

    allow(source).to receive(:version).and_return('10.24.0.73019')
    legacy = Mxrb::Compiler::PageDocumentCompiler.new(source).compile(page)
    expect(legacy['Parameters']).to eq([parameter.slice('$ID', '$Type', 'Name')])
  end

  it 'handles missing optional navigation data and rejects a missing Runtime root' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Navigation$NavigationDocument').first
    schema = Struct.new(:root) do
      def counterpart(document)
        Mxrb::IO::BsonCodec.extract_id(document['$ID']) == Mxrb::IO::BsonCodec.extract_id(root['$ID']) ? root : nil
      end

      def fields_for(document)
        case document['$Type']
        when 'Navigation$NavigationDocument'
          return %w[$ID $Type Profiles Grids CustomWidgetModules
                    PluginWidgets]
        when 'Texts$Text'
          return %w[$ID $Type]
        when 'Microflows$TextTemplate'
          return %w[$ID $Type Parameters Text]
        when 'Microflows$TemplateParameter'
          return %w[$ID $Type Expression]
        when 'Navigation$HomePage'
          return %w[$ID $Type Page Microflow]
        when 'Forms$FormSettings'
          return %w[$ID $Type TitleOverride ParameterMappings Form Location]
        end

        %w[$ID $Type HomePage HomeItems AppTitle LoginPageSettings ProgressiveWebAppSettings
           OfflineEntityConfigsRuntime NotFoundHomepage Name IsOffline ThrowPartialSyncError Kind AppIcon]
      end
    end
    existing = { '$ID' => unit.document['$ID'], '$Type' => unit.document['$Type'] }
    compiler = Mxrb::Compiler::NavigationDocumentCompiler.new(schema.new(existing))
    expect(compiler.send(:compile_value, 'Plain' => [2, 1])).to eq('Plain' => [1])
    document = unit.document.merge('Profiles' => [{
                                     '$ID' => '33333333-3333-4333-8333-333333333333',
                                     '$Type' => 'Navigation$NavigationProfile', 'Name' => 'Offline',
                                     'Kind' => 'Offline', 'OfflineEntityConfigs' => [], 'HomePage' => nil,
                                     'HomeItems' => [], 'AppTitle' => nil, 'LoginPageSettings' => nil,
                                     'ProgressiveWebAppSettings' => nil, 'NotFoundHomepage' => nil,
                                     'ThrowPartialSyncError' => false, 'AppIcon' => 'offline.svg'
                                   }])
    navigation = compiler.compile(unit.with(document:))
    expect(navigation.dig('Profiles', 0)).to include(
      'IsOffline' => true, 'HomePage' => nil, 'LoginPageSettings' => nil,
      'OfflineEntityConfigsRuntime' => [], 'AppIcon' => 'offline.svg'
    )

    profile = Mxrb::IO::BsonCodec.parse_array(unit.document['Profiles'])[:items].first
    translation = { '$ID' => '77777777-7777-4777-8777-777777777777', '$Type' => 'Texts$Translation',
                    'LanguageCode' => 'en_US', 'Text' => 'Sign in' }
    title = lambda do |items|
      text = { '$ID' => '55555555-5555-4555-8555-555555555555', '$Type' => 'Texts$Text', 'Items' => items }
      { '$ID' => '44444444-4444-4444-8444-444444444444', '$Type' => 'Microflows$TextTemplate',
        'Parameters' => [], 'Text' => text }
    end
    settings = lambda do |override|
      { '$ID' => '66666666-6666-4666-8666-666666666666', '$Type' => 'Forms$FormSettings',
        'Form' => 'App.Home', 'ParameterMappings' => [], 'TitleOverride' => override }
    end
    compile_login = lambda do |override|
      document = unit.document.merge('Profiles' => [profile.merge('LoginPageSettings' => settings.call(override))])
      compiler.compile(unit.with(document:)).fetch('Profiles').first
    end
    compiled_profile = compile_login.call(title.call([translation]))
    expect(compiled_profile.fetch('AppTitle').keys).to eq(%w[$ID $Type])
    expect(compiled_profile.dig('LoginPageSettings', 'TitleOverride')).to include(
      'Parameters' => [], 'Text' => include('$Type' => 'Texts$Text')
    )
    expect(compiled_profile.fetch('LoginPageSettings')).to include('Location' => 'Content')
    expect(compile_login.call(title.call([])).dig('LoginPageSettings', 'TitleOverride')).to be_nil
    parameter = { '$ID' => '88888888-8888-4888-8888-888888888888', '$Type' => 'Microflows$TemplateParameter',
                  'Expression' => '$currentUser/Name' }
    with_parameter = compile_login.call(title.call([]).merge('Parameters' => [parameter]))
    expect(with_parameter.dig('LoginPageSettings', 'TitleOverride', 'Parameters').length).to eq(1)
    expect(compile_login.call(nil).dig('LoginPageSettings', 'TitleOverride')).to be_nil

    missing = Mxrb::Compiler::NavigationDocumentCompiler.new(schema.new({ '$ID' => 'missing' }))
    expect(missing.compile(unit)).to include(
      'Grids' => [], 'CustomWidgetModules' => [], 'PluginWidgets' => []
    )
  end

  it 'compiles native profiles with the entities Mendix 11 synchronizes and the widgets web pages use' do
    mpr = File.join(File.dirname(@mpr), 'Native.mpr')
    Mxrb.define(mpr) do
      mendix_version '11.12.1'
      security { user_role :User, module_roles: ['App.User'] }
      navigation do
        profile :Responsive, home_page: 'App.Home'
        profile :Phone, kind: 'Native', home_page: 'App.Home', home_nanoflow: 'App.Start',
                        role_homes: { 'User' => 'App.Home' }, settings: { ota_enabled: true }
      end
      self.module(:App) do
        module_role :User
        entity(:Order) { string :Number }
        entity(:Line) { generalizes 'App.Order' }
        entity(:Draft) do
          non_persistent!
          string :Note
        end
        entity(:Account) { generalizes 'System.User' }
        layout :Shell
        page(:Home) do
          layout 'App.Shell'
          pluggable_widget :Grid, widget_id: 'com.mendix.widget.web.datagrid.Datagrid'
          pluggable_widget :Again, widget_id: 'com.mendix.widget.web.datagrid.Datagrid'
          pluggable_widget :Badge, widget_id: 'com.mendix.widget.web.badge.Badge'
        end
      end
    end
    source = Mxrb::Compiler::SourceModel.read(mpr)
    schema = Mxrb::Compiler::RuntimeModelSchema.new(Mxrb::Compiler::ModelPackage.empty, version: '11.12.1')
    document = source.units_of('Navigation$NavigationDocument').first
    navigation = Mxrb::Compiler::NavigationDocumentCompiler.new(schema, source:).compile(document)

    expect(navigation).to include(
      'Grids' => [], 'CustomWidgetModules' => [],
      'PluginWidgets' => %w[com.mendix.widget.web.datagrid.Datagrid com.mendix.widget.web.badge.Badge]
    )
    web, native = navigation['Profiles']
    expect(web).to include('Name' => 'Responsive', 'IsOffline' => false, 'OfflineEntityConfigsRuntime' => [])
    expect(native.keys).to eq(
      %w[$ID $Type OfflineEntityConfigsRuntime NativeHomePage RoleBasedNativeHomePages Name IsOffline
         ThrowPartialSyncError OtaEnabled LoggingEnabled NetworkTimeoutMs NativeNavigationEnabled]
    )
    expect(native).to include('Name' => 'Phone', 'IsOffline' => true, 'OtaEnabled' => true)
    expect(native['NativeHomePage'].except('$ID'))
      .to eq('$Type' => 'Navigation$NativeHomePage', 'HomePagePage' => 'App.Home')
    expect(native['RoleBasedNativeHomePages'].first.keys).to eq(%w[$ID $Type HomePagePage UserRole])
    entities = native['OfflineEntityConfigsRuntime'].map { _1['Entity'] }
    expect(entities.first(3)).to eq(%w[App.Account App.Line App.Order])
    expect(entities).to include('System.User', 'System.FileDocument', 'System.XASInstance')
    expect(entities).not_to include('App.Draft', 'System.ChangeHash', 'System.WorkflowVersion')
    expect(entities).to eq(entities.sort_by(&:downcase)).and have_attributes(length: 30)
    expect(native['OfflineEntityConfigsRuntime'].first.except('$ID')).to eq(
      '$Type' => 'Navigation$OfflineEntityConfig', 'Entity' => 'App.Account', 'SyncMode' => 'Online',
      'Constraint' => '', 'CompatibilityMode' => false
    )
  end

  it 'keeps configured offline entities, follows the Mendix 10 schema and derives what web profiles lack' do
    unit_type = Mxrb::Compiler::SourceModel::Unit
    widget = lambda do |id, plugin|
      { '$ID' => id, '$Type' => 'CustomWidgets$CustomWidget',
        'Type' => { 'WidgetId' => id, 'WidgetPluginWidget' => plugin } }
    end
    entity = lambda do |name, persistable: nil, generalization: nil|
      base = if generalization then { '$Type' => 'DomainModels$Generalization', 'Generalization' => generalization }
             else { '$Type' => 'DomainModels$NoGeneralization', 'Persistable' => persistable }
             end
      { '$ID' => name, '$Type' => 'DomainModels$Entity', 'Name' => name, 'MaybeGeneralization' => base }
    end
    unit = lambda do |type, name, document|
      unit_type.new(id: name, container_id: 'module', containment: 'Documents', module_name: 'App',
                    document: { '$ID' => name, '$Type' => type, 'Name' => name }.merge(document))
    end
    configured = { '$ID' => 'cfg', '$Type' => 'Navigation$OfflineEntityConfig', 'Entity' => 'App.Order',
                   'SyncMode' => 'All', 'Constraint' => '', 'CompatibilityMode' => false }
    profiles = [
      { '$ID' => 'web', '$Type' => 'Navigation$NavigationProfile', 'Name' => 'Responsive', 'Kind' => 'Responsive',
        'HomePage' => { '$ID' => 'home', '$Type' => 'Navigation$HomePage', 'Page' => 'App.Web', 'Microflow' => '' } },
      { '$ID' => 'native', '$Type' => 'Navigation$NativeNavigationProfile', 'Name' => 'Phone',
        'NativeHomePage' => { '$ID' => 'nh', '$Type' => 'Navigation$NativeHomePage', 'HomePageNanoflow' => 'App.Start',
                              'HomePagePage' => '' },
        'RoleBasedNativeHomePages' => [2], 'OfflineEntityConfigs' => [3, configured], 'OtaEnabled' => true,
        'LoggingEnabled' => false, 'NetworkTimeoutMs' => 60_000, 'NativeNavigationEnabled' => false,
        'ThrowPartialSyncError' => true }
    ]
    units = [
      unit.call('Forms$Page', 'Web', 'Widgets' => [2, widget.call('web.Grid', true), widget.call('legacy.Old', false)]),
      unit.call('Forms$Page', 'Native', 'Native' => true, 'Widgets' => [2, widget.call('native.Widget', true)]),
      unit.call('Forms$Layout', 'Shell',
                'Widgets' => [2, widget.call('web.Grid', true), widget.call('web.Menu', true)]),
      unit.call('Forms$Layout', 'Phone', 'Native' => true, 'Widgets' => [2, widget.call('native.Layout', true)]),
      unit.call('Forms$Snippet', 'Card', 'Type' => 'Web', 'Widgets' => [2, widget.call('web.Card', true)]),
      unit.call('Forms$Snippet', 'Tile', 'Type' => 'Native', 'Widgets' => [2, widget.call('native.Tile', true)]),
      unit.call('DomainModels$DomainModel', 'Domain', 'Entities' => [
                  2, entity.call('Order', persistable: true), entity.call('Line', generalization: 'App.Order'),
                  entity.call('Draft', persistable: false), entity.call('Loop', generalization: 'App.Loop2'),
                  entity.call('Loop2', generalization: 'App.Loop'),
                  entity.call('Stranger', generalization: 'Other.Thing')
                ]),
      unit.call('Navigation$NavigationDocument', 'Navigation', 'Profiles' => [2, *profiles])
    ]
    source_type = Struct.new(:units, :version) do
      def units_of(type) = units.select { _1.document['$Type'] == type }
      def web_page?(unit) = unit.document['Native'] != true
      def web_layout?(unit) = unit.document['Native'] != true
    end
    compile = lambda do |version|
      schema = Mxrb::Compiler::RuntimeModelSchema.new(Mxrb::Compiler::ModelPackage.empty, version:)
      source = source_type.new(units, version)
      Mxrb::Compiler::NavigationDocumentCompiler.new(schema, source:).compile(units.last)
    end

    eleven = compile.call('11.12.1')
    expect(eleven)
      .to include('PluginWidgets' => %w[web.Grid web.Menu web.Card], 'CustomWidgetModules' => ['legacy.Old'])
    web, native = eleven['Profiles']
    expect(web).to include(
      'IsOffline' => false, 'HomeItems' => [], 'AppIcon' => '', 'ThrowPartialSyncError' => true,
      'ProgressiveWebAppSettings' => nil, 'NotFoundHomepage' => nil, 'OfflineEntityConfigsRuntime' => []
    )
    expect(web['AppTitle']).to include('$Type' => 'Texts$Text')
    expect(web['LoginPageSettings'].except('$ID')).to eq(
      '$Type' => 'Forms$FormSettings', 'TitleOverride' => nil, 'ParameterMappings' => [], 'Form' => '',
      'Location' => 'Content'
    )
    expect(native['NativeHomePage']).to eq('$ID' => 'nh', '$Type' => 'Navigation$NativeHomePage', 'HomePagePage' => '')
    entities = native['OfflineEntityConfigsRuntime'].map { _1['Entity'] }
    expect(entities.first(2)).to eq(%w[App.Line App.Order])
    expect(entities).not_to include('App.Draft', 'App.Loop', 'App.Loop2', 'App.Stranger')
    expect(native['OfflineEntityConfigsRuntime'][1]).to include('$ID' => 'cfg', 'SyncMode' => 'All')

    ten = compile.call('10.24.0.73019')
    native10 = ten['Profiles'].last
    expect(native10.keys).to eq(
      %w[$ID $Type OfflineEntityConfigsRuntime NativeHomePage RoleBasedNativeHomePages Name IsOffline OtaEnabled
         LoggingEnabled]
    )
    expect(native10['OfflineEntityConfigsRuntime']).to eq(
      [{ '$ID' => 'cfg', '$Type' => 'Navigation$OfflineEntityConfig', 'Entity' => 'App.Order', 'SyncMode' => 'All',
         'Constraint' => '' }]
    )

    bogus = Struct.new(:inner, :type) do
      def counterpart(_document) = nil

      def fields_for(document)
        document['$Type'] == type ? %w[$ID $Type Bogus] : inner.fields_for(document)
      end
    end
    inner = Mxrb::Compiler::RuntimeModelSchema.new(Mxrb::Compiler::ModelPackage.empty, version: '11.12.1')
    %w[Navigation$NavigationDocument Navigation$NavigationProfile].each do |type|
      source = source_type.new(units, '11.12.1')
      compiler = Mxrb::Compiler::NavigationDocumentCompiler.new(bogus.new(inner, type), source:)
      expect { compiler.compile(units.last) }
        .to raise_error(Mxrb::CompilationError, /cannot derive Runtime field #{Regexp.escape(type)}.Bogus/)
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
