# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Regression coverage for format detection, archived legacy templates, and schema fallbacks.
RSpec.describe 'Native compiler edge contracts' do # rubocop:disable Metrics/BlockLength
  it 'detects every supported embedded image signature and rejects unknown bytes' do
    compiler = Mxrb::Compiler::ArtifactDocumentCompiler.new
    signatures = {
      'gif' => 'GIF89a...', 'jpg' => "\xFF\xD8\xFFdata".b, 'bmp' => 'BMdata',
      'ico' => "\x00\x00\x01\x00data".b, 'webp' => 'RIFFxxxxWEBPdata',
      'svg' => "<?xml version='1.0'?><svg></svg>"
    }

    signatures.each do |format, bytes|
      expect(compiler.send(:image_format, 'Name' => format, 'Image' => BSON::Binary.new(bytes)))
        .to eq(format)
    end
    expect do
      compiler.send(:image_format, 'Name' => 'unknown', 'Image' => BSON::Binary.new('unknown'))
    end.to raise_error(Mxrb::CompilationError, /cannot determine format/)
  end

  it 'extracts safe legacy archives, preserves files, and blocks invalid or escaping entries' do
    Dir.mktmpdir do |root|
      subject = Mxrb::Compiler::DeploymentBootstrapper.allocate
      subject.instance_variable_set(:@deployment, File.join(root, 'deployment'))
      subject.instance_variable_set(:@version_root, root)
      archive = File.join(root, 'modeler', 'deployment.mxz')
      FileUtils.mkdir_p(File.dirname(archive))
      Zip::File.open(archive, create: true) do |zip|
        zip.mkdir('web')
        zip.get_output_stream('web/index.html') { _1.write('first') }
      end
      subject.send(:extract_deployment_archive)
      path = File.join(root, 'deployment', 'web', 'index.html')
      expect(File.read(path)).to eq('first')
      File.write(path, 'preserved')
      subject.send(:extract_deployment_archive)
      expect(File.read(path)).to eq('preserved')

      Zip::File.open(archive, create: true) { _1.get_output_stream('../escape') { |io| io.write('bad') } }
      expect { subject.send(:extract_deployment_archive) }
        .to raise_error(Mxrb::CompilationError, /unsafe deployment template/)
      File.write(archive, 'not a zip')
      expect { subject.send(:extract_deployment_archive) }
        .to raise_error(Mxrb::CompilationError, /invalid deployment template/)
    end
  end

  it 'normalizes attribute references and rejects unresolved associations' do
    fields = {
      'Microflows$RetrieveSorting' => %w[$ID $Type AttributePath],
      'Microflows$AssociationRetrieveSource' => %w[$ID $Type Type]
    }
    schema = Struct.new(:fields) do
      def fields_for(source) = fields.fetch(source['$Type'])
      def counterpart(_source) = nil
      def named(_name) = nil
    end.new(fields)
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema)
    hash = compiler.compile(
      '$Type' => 'Microflows$RetrieveSorting',
      'AttributeRef' => { 'Attribute' => 'App.Item.Name' }
    )
    plain = compiler.compile(
      '$Type' => 'Microflows$RetrieveSorting', 'AttributeRef' => 'Name'
    )
    expect(hash['AttributePath']).to eq('App.Item/App.Item.Name')
    expect(plain['AttributePath']).to eq('Name')
    expect do
      compiler.compile('$Type' => 'Microflows$AssociationRetrieveSource', 'AssociationId' => 'App.Missing')
    end.to raise_error(Mxrb::CompilationError, /unknown association/)
  end

  it 'derives legacy node defaults and resolves project-owned association endpoints' do # rubocop:disable Metrics/BlockLength
    fields = {
      'Test$Defaults' => %w[$ID $Type Argument Location ParameterMappings],
      'Microflows$AssociationRetrieveSource' => %w[$ID $Type Type]
    }
    schema = Struct.new(:fields) do
      def fields_for(source) = fields.fetch(source['$Type'])
      def counterpart(_source) = nil
    end.new(fields)
    entity_a = { '$ID' => '11111111-1111-4111-8111-111111111111', 'Name' => 'Parent' }
    entity_b = { '$ID' => '22222222-2222-4222-8222-222222222222', 'Name' => 'Child' }
    association = {
      'Name' => 'Parent_Child', 'ParentPointer' => entity_a['$ID'],
      'ChildPointer' => entity_b['$ID'], 'Type' => 'Reference'
    }
    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: 'domain', container_id: 'domain', containment: 'DomainModel', module_name: 'App',
      document: { 'Entities' => [3, entity_a, entity_b], 'Associations' => [3, association] }
    )
    source = Struct.new(:unit) { def units_of(_type) = [unit] }.new(unit)
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema, source:)
    compiler.prepare(
      '$Type' => 'Microflows$Microflow', 'Objects' => [{
        '$Type' => 'Microflows$MicroflowParameter', 'Name' => 'Child',
        'VariableType' => { 'Entity' => 'App.Child' }
      }]
    )
    defaults = compiler.compile(
      '$Type' => 'Test$Defaults', 'Value' => { 'Argument' => '42' }
    )
    reverse = compiler.compile(
      '$Type' => 'Microflows$AssociationRetrieveSource',
      'AssociationId' => 'App.Parent_Child', 'StartVariableName' => 'Child'
    )
    expect(defaults).to include('Argument' => '42', 'Location' => 'Content', 'ParameterMappings' => [])
    expect(reverse['Type']).to eq('[App.Parent]')
  end

  it 'derives audited aggregate result types and rejects ambiguous aggregates' do
    fields = { 'Microflows$AggregateAction' => %w[$ID $Type Type] }
    schema = Struct.new(:fields) do
      def fields_for(source) = fields.fetch(source['$Type'])
      def counterpart(_source) = nil
    end.new(fields)
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema)
    count = compiler.compile('$Type' => 'Microflows$AggregateAction', 'AggregateFunction' => 'Count')
    expect(count['Type']).to eq('Integer')
    expect do
      compiler.compile('$Type' => 'Microflows$AggregateAction', 'AggregateFunction' => 'Sum')
    end.to raise_error(Mxrb::CompilationError, /without an audited attribute type/)
  end

  it 'covers legacy Java flags, visual roots, unsafe image names, and version error wrapping' do
    builder = Mxrb::Compiler::ProjectJarBuilder.allocate
    builder.instance_variable_set(:@java_major, '8')
    expect(builder.send(:language_level_arguments)).to eq(%w[-source 1.8 -target 1.8])

    bootstrap = Mxrb::Compiler::DeploymentBootstrapper.allocate
    bootstrap.instance_variable_set(:@source, Struct.new(:version).new('9.6.1'))
    expect(bootstrap.send(:web_template_roots)).to eq('web' => 'web', 'modern-web' => 'modern-web')
    bootstrap.instance_variable_set(:@source, Struct.new(:version).new('7.17.0'))
    expect(bootstrap.send(:web_template_roots)).to eq('web' => 'web')

    classic_ten = Struct.new(:version, :optimized_web_client?).new('10.24.0', false)
    bootstrap.instance_variable_set(:@source, classic_ten)
    expect(bootstrap.send(:web_template_roots)).to eq('dojo-web' => 'web')
    bootstrap.instance_variable_set(:@source, Struct.new(:version, :optimized_web_client?).new('10.24.0', true))
    expect(bootstrap.send(:web_template_roots)).to eq('react-web' => 'web')

    source = Struct.new(:units) { def units_of(_type) = units }.new(
      [Mxrb::Compiler::SourceModel::Unit.new(
        id: 'images', container_id: 'images', containment: 'Images', module_name: '../bad',
        document: { 'Name' => 'Assets', 'Images' => [3, { 'Name' => 'Logo' }] }
      )]
    )
    copier = Mxrb::Compiler::DeploymentAssetCopier.new('.', Dir.mktmpdir, ->(*) {}, source:)
    expect { copier.send(:export_images) }.to raise_error(Mxrb::CompilationError, /unsafe image identifier/)

    allow(Gem::Version).to receive(:new).and_raise(ArgumentError)
    expect { Mxrb::Compiler::SystemModelSeed.seed_version_for('7.2.3') }
      .to raise_error(Mxrb::CompilationError, /invalid Mendix version/)
  end

  it 'selects the Mendix 10 Rollup command' do
    web = Mxrb::Compiler::WebBundleBuilder.allocate
    web.instance_variable_set(:@source, Struct.new(:version).new('10.24.0'))
    web.instance_variable_set(:@version_root, '/mendix/10.24.0')
    arguments = [
      '/mendix/10.24.0/modeler/tools/node/node_modules/rollup/dist/bin/rollup', '--config'
    ]

    expect(web.send(:bundler_name)).to eq('Rollup')
    expect(web.send(:bundler_arguments)).to eq(arguments)
  end

  it 'covers the source-less Mendix 10 adapter and every React DOM shim decision' do
    expect(Mxrb::Compiler::Adapter.for('10.24.0').web_profiles).to eq([:dojo])

    Dir.mktmpdir do |root|
      web = File.join(root, 'web')
      FileUtils.mkdir_p(web)
      builder = Mxrb::Compiler::WebBundleBuilder.allocate
      builder.instance_variable_set(:@version_root, '/mendix/11.12.1')

      builder.send(:materialize_react_dom_compatibility, web)
      shim = File.join(web, 'react-dom-compat.mjs')
      expect(File).to exist(shim)

      config = File.join(web, 'rspack.config.mjs')
      File.write(config, 'export default { resolve: { alias: { } } };')
      builder.send(:materialize_react_dom_compatibility, web)
      expect(File.read(config)).to include(JSON.generate(shim))
      builder.send(:materialize_react_dom_compatibility, web)

      File.write(config, 'export default {};')
      expect { builder.send(:materialize_react_dom_compatibility, web) }
        .to raise_error(Mxrb::CompilationError, /no resolve alias block/)
    end
  end

  it 'builds React layout bundles through the page bundle builder' do
    Dir.mktmpdir do |root|
      layout = Struct.new(:module_name, :document).new('Demo', { 'Name' => 'Shell' })
      source = instance_double(Mxrb::Compiler::SourceModel, units_of: [layout])
      allow(source).to receive(:web_layout?).with(layout).and_return(true)
      bundle = Mxrb::Compiler::PageBundle.new('Demo.Shell', 'layout source', [], [])
      compiler = instance_double(Mxrb::Compiler::PageBundleCompiler, compile_layout: bundle)
      allow(Mxrb::Compiler::PageBundleCompiler).to receive(:new).with(source).and_return(compiler)
      builder = Mxrb::Compiler::PageBundleBuilder.allocate
      builder.instance_variable_set(:@source, source)
      builder.instance_variable_set(:@web_root, root)

      expect(builder.send(:build_layouts)).to eq([bundle])
      expect(File.read(File.join(root, 'layouts', 'Demo.Shell.js'))).to eq('layout source')
    end
  end

  it 'exercises all compatibility fallbacks that protect legacy build inputs' do
    values = Class.new { include Mxrb::Compiler::ModelValues }.new
    expect(values.send(:image_bytes, 'bytes')).to eq('bytes'.b)

    constants = Mxrb::Compiler::ConstantsMaterializer.allocate
    expect(constants.send(:constant_type, { 'DataType' => 'String' }, 'App.Value')).to eq('String')

    queues = Mxrb::Compiler::SystemQueueMaterializer.allocate
    queues.instance_variable_set(:@version, '7.23.0')
    expect(queues.send(:queue_config, 'id', '5')).to include('Parallelism' => 5)

    types = Class.new { include Mxrb::Compiler::RuntimeDataTypes }.new
    expect(types.send(:data_type, '$Type' => 'DataTypes$ListType', 'Entity' => 'App.Item')).to eq('[App.Item]')
    expect(types.send(:data_type, '$Type' => 'DataTypes$UnknownType')).to eq('Unknown')

    package = Struct.new(:documents).new([{ '$ID' => SecureRandom.uuid, '$Type' => 'Test$Node' }])
    expect(Mxrb::Compiler::RuntimeModelSchema.builtin_fields(nil))
      .to equal(Mxrb::Compiler::RuntimeModelSchema::DEFAULT_FIELDS)
    expect { Mxrb::Compiler::RuntimeModelSchema.new(package) }.not_to raise_error
    allow(Mxrb::Compiler::RuntimeModelSchema).to receive(:schema_path).and_return(nil)
    expect(Mxrb::Compiler::RuntimeModelSchema.builtin_fields('7.17.0'))
      .to equal(Mxrb::Compiler::RuntimeModelSchema::DEFAULT_FIELDS)
    expect { Mxrb::Compiler::RuntimeModelSchema.new(package, version: '7.17.0') }.not_to raise_error

    allow(Mxrb::Compiler::SystemModelSeed).to receive(:seed_version_for).with('6.1.0').and_return('missing')
    expect { Mxrb::Compiler::SystemModelSeed.for('6.1.0') }
      .to raise_error(Mxrb::CompilationError, /no native System model seed/)

    copied = []
    Mxrb::Compiler::DeploymentAssetCopier.new('/project', '/deployment', ->(*args) { copied << args }).copy
    expect(copied.length).to eq(5)
  end

  it 'covers conservative microflow defaults when optional metadata is absent' do
    schema = Struct.new(:fields) do
      def fields_for(source) = fields.fetch(source['$Type'])
      def counterpart(_source) = nil
      def named(_name) = { 'ParentPointer' => 'parent', 'ChildPointer' => 'child', 'Type' => 'Reference' }
      def counterpart_id(_id) = nil
    end.new({
      'Microflows$ActionActivity' => %w[$ID $Type Caption],
      'Microflows$AssociationRetrieveSource' => %w[$ID $Type Type]
    })
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema)
    compiler.prepare('$Type' => 'Microflows$Microflow', 'Objects' => [
                       2, { '$Type' => 'Microflows$MicroflowParameter', 'Name' => 'Empty',
                            'VariableType' => { 'Entity' => '' } }
                     ])
    expect(compiler.compile('$Type' => 'Microflows$AnnotationFlow')).to be_nil
    expect(compiler.compile('$Type' => 'Microflows$ActionActivity')).to include('Caption' => '')
    expect(compiler.compile('$Type' => 'Microflows$AssociationRetrieveSource',
                            'AssociationId' => 'System.Missing', 'StartVariableName' => 'x')['Type']).to be_nil
  end

  it 'covers deployment reuse and both legacy web dispatch paths' do
    bootstrap = Mxrb::Compiler::DeploymentBootstrapper.allocate
    bootstrap.instance_variable_set(:@source, Struct.new(:version).new('7.17.0'))
    bootstrap.instance_variable_set(:@template_root, '/templates')
    bootstrap.instance_variable_set(:@deployment, '/deployment')
    allow(bootstrap).to receive_messages(
      legacy_archive?: true, extract_deployment_archive: nil, copy_tree: nil
    )
    bootstrap.send(:copy_version_templates)
    expect(bootstrap).to have_received(:extract_deployment_archive)

    allow(bootstrap).to receive_messages(
      ready?: true, ensure_required_directories: nil, copy_project_assets: nil
    )
    expect(bootstrap.prepare.created).to be(false)

    source = Struct.new(:version).new('7.17.0')
    builder = Mxrb::Compiler::WebBundleBuilder.allocate
    builder.instance_variable_set(:@deployment, '/deployment')
    builder.instance_variable_set(:@source, source)
    legacy = instance_double(Mxrb::Compiler::LegacyPageBuilder, build: :legacy)
    allow(Mxrb::Compiler::LegacyPageBuilder).to receive(:new).and_return(legacy)
    expect(builder.build).to eq(:legacy)
  end

  it 'uses deterministic empty-language and default-style fallbacks for Dojo pages' do
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [])
    page_builder = Mxrb::Compiler::LegacyPageBuilder.new(source, '/deployment')
    expect(page_builder.send(:languages)).to eq(['en_US'])
    expect(page_builder.send(:translated, nil, 'de_DE')).to eq('')
    english = { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'English' }] }
    expect(page_builder.send(:translated, english, 'de_DE')).to eq('English')

    grid = Mxrb::Compiler::LegacyDataGridCompiler.allocate
    expect(grid.send(:button_class, {})).to eq('btn-default')
  end
end
