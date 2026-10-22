# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative 'fixtures/message_xml/project'

# The mappings MxBuild 10.24.0 and 11.12.1 write into model.mdp for the import
# mapping and message XML fixtures.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::MappingMaterializer do
  def materialize(mpr)
    deployment = File.join(File.dirname(mpr), 'deployment')
    FileUtils.mkdir_p(File.join(deployment, 'model'))
    Mxrb::Compiler::ModelPackage.empty.write(File.join(deployment, 'model', 'model.mdp'))
    result = described_class.new(mpr, deployment:).materialize
    [result, Mxrb::Compiler::ModelPackage.read(result.model_path).documents]
  end

  def nodes(value, found = [])
    case value
    when Hash
      found << value if value['$Type']
      value.each_value { nodes(_1, found) }
    when Array then value.each { nodes(_1, found) }
    end
    found
  end

  it 'writes JSON structures and import mappings with the fields MxBuild derives' do
    Dir.mktmpdir do |work|
      mpr = File.join(work, 'Oracle.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = mpr
      load 'spec/fixtures/native_import_mapping/project.rb'
      ENV['MXRB_OUTPUT_PATH'] = previous
      result, documents = materialize(mpr)
      expect(result.documents).to eq(2)
      expect(documents.find { _1['$Type'] == 'JsonStructures$JsonStructure' })
        .to include('Name' => 'OrderJson', 'QualifiedName' => 'Views.OrderJson')
      mapping = documents.find { _1['$Type'] == 'ImportMappings$ImportMapping' }
      expect(mapping).to include('QualifiedName' => 'Views.ImportOrder', 'SupportedContentTypesRuntime' => ['Json'],
                                 'ParameterDataTypeRuntime' => 'Unknown', 'JsonStructure' => 'Views.OrderJson')
      elements = nodes(mapping['Elements'])
      lines = elements.find { _1['JsonPath'] == '(Object)|lines|(Object)' }
      expect(lines).to include('OccursMoreThanOnce' => true, 'ObjectHandlingBackupOverride' => false)
      compiler = Mxrb::Compiler::MappingDocumentCompiler.new(nil)
      override = { 'ObjectHandlingBackupAllowOverride' => true }
      expect(compiler.send(:derived, override, 'ObjectHandlingBackupOverride', 'Views')).to be(true)
      expect(elements.find { _1['JsonPath'] == '(Object)|total' }).to include('XmlType' => 'Decimal',
                                                                              'OccursMoreThanOnce' => false)
    end
  end

  it 'writes message definitions and mappings that read JSON and XML' do
    Dir.mktmpdir do |work|
      mpr = File.join(work, 'Oracle.mpr')
      MessageXmlFixture.build(mpr)
      _result, documents = materialize(mpr)
      expect(documents.find { _1['$Type'] == 'MessageDefinitions$MessageDefinitionCollection' })
        .to include('QualifiedName' => 'MessageXml.Contacts')
      expect(documents.select { _1['$Type'].to_s.end_with?('Mapping') }.map { _1['SupportedContentTypesRuntime'] })
        .to all(eq(%w[Json Xml]))
    end
  end

  it 'refuses what MxBuild would derive in a way it has not audited' do
    compiler = Mxrb::Compiler::MappingDocumentCompiler.new(nil)
    expect(compiler.send(:content_types, { 'XmlSchema' => 'App.Orders' })).to eq(['Xml'])
    expect { compiler.send(:content_types, { 'Name' => 'Bare' }) }
      .to raise_error(Mxrb::CompilationError, /Bare has no JSON structure/)
    parameter = { 'Name' => 'WithInput', 'ParameterType' => { '$Type' => 'DataTypes$ObjectType' } }
    expect { compiler.send(:parameter_type, parameter) }
      .to raise_error(Mxrb::CompilationError, /WithInput takes a parameter/)
    expect(compiler.send(:parameter_type, { 'Name' => 'Old' })).to eq('Unknown')
    expect(compiler.send(:value, { 'Plain' => [1, 'x'] }, 'App')).to eq('Plain' => ['x'])
    expect { compiler.send(:derived, { '$Type' => 'ImportMappings$ImportMapping' }, 'Unknown', 'App') }
      .to raise_error(Mxrb::CompilationError, /ImportMappings\$ImportMapping.Unknown/)
  end
end
# rubocop:enable Metrics/BlockLength
