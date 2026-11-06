# frozen_string_literal: true

require 'spec_helper'

# Fields that a project.rb rebuild dropped or rewrote in documents Mxrb.compare did not
# read as stored: dataset documentation and query text, REST authentication types, and
# the module export level of Mendix 9.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'stored units through a project.rb round trip' do
  let(:exporter) { Mxrb::Exporter.new('/tmp/source.mpr', '/tmp/exported') }

  # Evaluates an exported dataset declaration the way project.rb does.
  def rebuilt_dataset(doc)
    source = exporter.send(:dataset_declaration, name: 'Report', doc:)
    declared = {}
    context = Object.new
    context.define_singleton_method(:dataset) do |name, **options, &block|
      builder = Mxrb::Dsl::IntegrationDocuments::DataSetBuilder.new
      builder.instance_eval(&block)
      declared.merge!(name:, options:, query: builder.query, ieiq: builder.ieiq)
    end
    context.instance_eval(source)
    declared
  end

  def dataset_doc(query, **fields)
    { 'Source' => { '$Type' => 'DataSets$OqlDataSetSource', 'Query' => query } }.merge(fields)
  end

  it 'keeps the documentation, exclusion and export level of a dataset' do
    declared = rebuilt_dataset(dataset_doc('SELECT 1', 'Documentation' => "Totals\nper day",
                                                       'Excluded' => true, 'ExportLevel' => 'API'))

    expect(declared.fetch(:options)).to eq(documentation: "Totals\nper day", excluded: true, export_level: 'API')
    expect(rebuilt_dataset(dataset_doc('SELECT 1', 'ExportLevel' => 'Hidden')).fetch(:options)).to eq({})
  end

  it 'reproduces every query exactly' do
    queries = [
      "SELECT Name\nFROM App.Product", "SELECT Name\nFROM App.Product\n", "SELECT 1\n\n",
      "SELECT 1\n   ", "  SELECT Name\n  FROM App.Product", "SELECT 'a\\nb'", "SELECT '\#{x}'",
      "SELECT 1\r\nFROM App.Product", "SELECT\nOQL\nFROM App.Product", "\tSELECT 1", ''
    ]

    queries.each do |query|
      expect(rebuilt_dataset(dataset_doc(query, 'Source' => {
                                           '$Type' => 'DataSets$OqlDataSetSource', 'Query' => query, 'IEIQ' => true
                                         }))).to include(query:, ieiq: true)
    end
    expect(exporter.send(:dataset_declaration, name: 'Report', doc: dataset_doc("SELECT 1\nFROM X")))
      .to include("oql <<~OQL.chomp\n    SELECT 1\n    FROM X\n  OQL")
  end

  it 'writes REST authentication types back with their stored names' do
    expect(%w[Basic Microflow Custom Session SAML].map { exporter.send(:rest_enum_source, _1) })
      .to eq([:basic, :microflow, :custom, :session, 'SAML'])
    builder = Object.new.extend(Mxrb::Dsl::IntegrationDocuments)
    expect(%i[microflow basic].map { builder.send(:integration_enum, _1) }).to eq(%w[Microflow Basic])
  end

  it 'keeps a Mendix 7 mapping as stored instead of declaring it' do
    element = { '$Type' => 'ImportMappings$ValueMappingElement', 'Path' => '(Object)|Name', 'XmlType' => 'String' }
    object = { '$Type' => 'ImportMappings$ObjectMappingElement', 'Children' => [2, element] }
    modern = { '$Type' => 'ImportMappings$ObjectMappingElement', 'JsonPath' => '(Object)', 'Children' => [2] }

    expect(exporter.send(:semantic_mapping?, 'JsonStructure' => '', 'Elements' => [2, object])).to be(false)
    expect(exporter.send(:semantic_mapping?, 'JsonStructure' => '', 'Parameter' => '', 'Elements' => [2])).to be(false)
    expect(exporter.send(:semantic_mapping?, 'JsonStructure' => '', 'Elements' => [2, modern])).to be(true)
    expect(exporter.send(:semantic_mapping?, 'Elements' => [2, modern])).to be(false)
  end

  describe 'domain model elements' do
    let(:writer) { Mxrb::Writer.allocate }

    it 'keeps where an association connects to its entities' do
      association = { name: 'A_B', type: :Reference }
      stored = { 'ParentConnection' => '82;0', 'ChildConnection' => '21;100' }

      expect(writer.send(:association_doc, association, from_id: 'a', to_id: 'b', previous: stored))
        .to include('ParentConnection' => '82;0', 'ChildConnection' => '21;100')
      expect(writer.send(:association_doc, association, from_id: 'a', to_id: 'b', previous: nil))
        .to include('ParentConnection' => '0;50', 'ChildConnection' => '100;50')
    end

    it 'keeps the identity and field name of a stored event handler' do
      stored = { '$ID' => 'kept', 'Event' => 'Commit', 'Moment' => 'Before', 'Extra' => 1 }
      handler = writer.send(:lifecycle_doc, { event: :before_commit, handler: 'App.Check' }, previous: stored)

      expect(handler).to include('$ID' => 'kept', 'Event' => 'Commit', 'Moment' => 'Before', 'Extra' => 1)
      expect(handler).not_to have_key('Type')
      expect(writer.send(:lifecycle_doc, { event: :after_create, handler: 'App.Run' })).to include('Type' => 'Create')
    end

    it 'keeps the stored order of validation rules' do
      rule = lambda do |kind|
        { 'Attribute' => 'App.Item.Code', 'RuleInfo' => { '$Type' => "DomainModels$#{kind}RuleInfo" } }
      end
      stored = Mxrb::IO::BsonCodec.build_array([rule.call('Unique'), rule.call('Other'), rule.call('Required')])
      entity = { name: 'Item', attributes: [{ name: 'Code', required: true, unique: true }] }
      rules = writer.send(:validation_rules_doc, entity, 'App', stored).drop(1)

      expect(rules.map { _1.dig('RuleInfo', '$Type').delete_prefix('DomainModels$') })
        .to eq(%w[UniqueRuleInfo OtherRuleInfo RequiredRuleInfo])
    end
  end

  it 'returns a variable by name only when the flow names its return variable after it' do
    named = Struct.new(:return_variable_name)
    answers = lambda do |flow|
      exporter.send(:with_flow_return_variable, flow) do
        %w[Item Other].map { exporter.send(:returned_as_variable?, _1) }
      end
    end

    expect(answers.call(named.new('Item'))).to eq([true, false])
    expect(answers.call(named.new('ReturnValue'))).to eq([false, false])
    expect(answers.call(Object.new)).to eq([true, true])
    expect(exporter.send(:returned_as_variable?, 'Anything')).to be(true)
  end

  it 'carries the export level an enumeration value stores through Ruby' do
    caption = { '$ID' => 'caption', 'Items' => [3, { '$ID' => 'text', 'LanguageCode' => 'en_US', 'Text' => 'Open' }] }
    value = { '$ID' => 'value', 'Name' => 'Open', 'Caption' => caption, 'ExportLevel' => 'Hidden' }
    source = exporter.send(:enumeration_declaration, name: 'State', id: 'unit', doc: { 'Values' => [3, value] })
    builder = Mxrb::Dsl::EnumerationBuilder.new('State')
    builder.value(:Open, export_level: 'Hidden')
    document = Mxrb::Writer.allocate.send(:enumeration_doc, builder.to_h)

    expect(source).to include('export_level: "Hidden"')
    expect(document.dig('Values', 1)).to include('ExportLevel' => 'Hidden')
  end

  it 'keeps the export level a module stores' do
    writer = Mxrb::Writer.allocate
    stored = { '$ID' => 'id', '$Type' => 'Projects$ModuleImpl', 'ExportLevel' => 'Source', 'SortIndex' => 1 }

    expect(writer.send(:module_doc, 'App', 0, previous: stored)).to include('ExportLevel' => 'Source')
    expect(writer.send(:module_doc, 'App', 0, previous: stored)).not_to have_key('SortIndex')
    expect(writer.send(:module_doc, 'App', 0)).not_to have_key('ExportLevel')
  end
end
# rubocop:enable Metrics/BlockLength
