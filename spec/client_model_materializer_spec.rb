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
    expect(navigation).to include(
      'Grids' => ['grid'], 'CustomWidgetModules' => ['module'], 'PluginWidgets' => ['widget']
    )
    expect(navigation.dig('Profiles', 0)).to include(
      'Name' => 'Responsive', 'IsOffline' => false, 'AppIcon' => 'existing.svg'
    )
    expect(navigation.dig('Profiles', 0, 'HomePage')).to include('Page' => 'App.Home')
  end

  it 'compiles page parameters and URL segments and rejects non-pages' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    parameter = {
      '$ID' => '11111111-1111-4111-8111-111111111111', '$Type' => 'Forms$PageParameter',
      'Name' => 'Item', 'ParameterType' => {
        '$ID' => '22222222-2222-4222-8222-222222222222', '$Type' => 'DataTypes$ObjectType',
        'Entity' => 'App.Item'
      }
    }
    document = unit.document.merge('Parameters' => [parameter], 'Url' => 'items/{Item}/edit/{Mode}')
    compiler = Mxrb::Compiler::PageDocumentCompiler.new(source)
    expect(compiler.send(:text_reference, nil)).to be_nil
    page = compiler.compile(unit.with(document:))

    expect(page['UrlSegments']).to eq(%w[Item Mode])
    expect(page['Parameters'].first).to include(
      'ParameterTypeRuntime' => 'App.Item', 'IsRequired' => false
    )
    expect { compiler.compile(unit.with(document: document.merge('$Type' => 'Forms$Snippet'))) }
      .to raise_error(Mxrb::CompilationError, /unsupported page root/)
    no_security = Struct.new(:unused) { def documents(_type) = [] }.new
    expect(Mxrb::Compiler::PageDocumentCompiler.new(no_security))
      .to be_a(Mxrb::Compiler::PageDocumentCompiler)
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
        end

        %w[$ID $Type HomePage HomeItems AppTitle LoginPageSettings ProgressiveWebAppSettings
           OfflineEntityConfigsRuntime NotFoundHomepage Name IsOffline ThrowPartialSyncError Kind AppIcon]
      end
    end
    existing = { '$ID' => unit.document['$ID'], '$Type' => unit.document['$Type'] }
    compiler = Mxrb::Compiler::NavigationDocumentCompiler.new(schema.new(existing))
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
    title = {
      '$ID' => '44444444-4444-4444-8444-444444444444', '$Type' => 'Microflows$TextTemplate',
      'Parameters' => [], 'Text' => {
        '$ID' => '55555555-5555-4555-8555-555555555555', '$Type' => 'Texts$Text', 'Items' => []
      }
    }
    settings = {
      '$ID' => '66666666-6666-4666-8666-666666666666', '$Type' => 'Forms$FormSettings',
      'Form' => '', 'ParameterMappings' => [], 'TitleOverride' => title
    }
    rich_document = unit.document.merge('Profiles' => [profile.merge('LoginPageSettings' => settings)])
    compiled_profile = compiler.compile(unit.with(document: rich_document)).fetch('Profiles').first
    expect(compiled_profile.fetch('AppTitle').keys).to eq(%w[$ID $Type])
    expect(compiled_profile.dig('LoginPageSettings', 'TitleOverride')).to include(
      'Parameters' => [], 'Text' => include('$Type' => 'Texts$Text')
    )

    missing = Mxrb::Compiler::NavigationDocumentCompiler.new(schema.new({ '$ID' => 'missing' }))
    expect(missing.compile(unit)).to include(
      'Grids' => [], 'CustomWidgetModules' => [], 'PluginWidgets' => []
    )
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
