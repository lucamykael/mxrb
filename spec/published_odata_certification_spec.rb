# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative 'fixtures/published_odata/project'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'published OData certification' do
  it 'keeps a read-only OData service stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-published-odata-certification-') do |dir|
      current = File.join(dir, 'source.mpr')
      PublishedODataFixture.build(current)
      baseline_ids = integration_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = certified_source(exported)
        expect(source).to include(
          'published_odata_service :ContactsApi', 'entity_types:',
          ':kind => :id', ':kind => :attribute', 'entity_sets:',
          ':read =>', ':not_supported', 'PublishedOData.Contact.Email'
        )
        expect(source).not_to include(
          'native_document', 'deep_structure:', 'bson_binary(', 'native_fragment('
        )

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(integration_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  it 'rejects published OData variants outside the certified slice' do
    builder = Mxrb::Dsl::ModuleBuilder.new(:OData)
    base = { path: 'odata/', namespace: 'OData', version: '1' }
    builder.published_odata_service(
      :ExplicitPointer, **base, entity_types: [],
                                entity_sets: [{ name: 'Items', entity_type_id: SecureRandom.uuid }]
    )
    expect do
      builder.published_odata_service(
        :Api, **base, entity_sets: [],
                      entity_types: [{ name: 'Item', entity: 'OData.Item',
                                       members: [{ kind: :association, name: 'Other' }] }]
      )
    end.to raise_error(ArgumentError, /unsupported published OData member kind/)
    expect do
      builder.published_odata_service(
        :Api, **base, entity_types: [{ name: 'Item', entity: 'OData.Item' }],
                      entity_sets: [{ name: 'Items', entity_type: 'Item', read: :microflow }]
      )
    end.to raise_error(ArgumentError, /read mode must be :source/)
    expect do
      builder.published_odata_service(
        :Api, **base, entity_types: [{ name: 'Item', entity: 'OData.Item' }],
                      entity_sets: [{ name: 'Items', entity_type: 'Item', insert: :source }]
      )
    end.to raise_error(ArgumentError, /change mode must be :not_supported/)
  end

  it 'keeps unrepresented published OData shapes in the native fallback' do
    exporter = Mxrb::Exporter.allocate
    valid = valid_odata_document
    invalid = [
      valid.merge('Unknown' => true),
      valid.merge('Enumerations' => [3, { '$Type' => 'ODataPublish$PublishedEnumeration' }]),
      replace_entity(valid) { _1.merge('$Type' => 'ODataPublish$UnknownEntity') },
      replace_entity(valid) { _1.merge('Unknown' => true) },
      replace_set(valid) { _1.merge('$Type' => 'ODataPublish$UnknownSet') },
      replace_set(valid) { _1.merge('Unknown' => true) },
      replace_set(valid) { _1.merge('EntityTypePointer' => SecureRandom.uuid) },
      replace_set(valid) do |set|
        set.merge('ReadMode' => set.fetch('ReadMode').merge('$Type' => 'ODataPublish$CallMicroflowToRead'))
      end
    ]
    invalid.each do |document|
      expect(exporter.send(:semantic_published_odata_service?, document)).to be(false)
    end

    declaration = exporter.send(
      :integration_document_declaration,
      {
        type: 'ODataPublish$PublishedODataService2', name: 'Api', id: SecureRandom.uuid,
        container_id: SecureRandom.uuid, containment: 'Documents', doc: invalid.first
      }
    )
    expect(declaration).to include('native_document :Api', 'deep_structure:')
  end

  def certified_source(exported)
    path = File.join(
      exported, 'modules', 'PublishedOData', 'infrastructure', 'endpoints', 'contacts_api.rb'
    )
    File.read(path)
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end

  def integration_ids(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        next unless document['$Type'] == 'ODataPublish$PublishedODataService2'

        [document['$Type'], document['Name'], unit['UnitID'].to_s]
      end.sort
    end
  end

  def valid_odata_document
    builder = Mxrb::Dsl::ModuleBuilder.new(:OData)
    builder.published_odata_service(
      :Api, path: 'odata/', namespace: 'OData', version: '1',
            entity_types: [{ name: 'Item', entity: 'OData.Item',
                             members: [{ kind: :id, name: 'id' }] }],
            entity_sets: [{ name: 'Items', entity_type: 'Item' }]
    )
    builder.native_documents.fetch(0).fetch(:doc)
  end

  def replace_entity(document)
    copy = Mxrb::IO::BsonCodec.parse(Mxrb::IO::BsonCodec.serialize(document))
    copy.fetch('EntityTypes')[1] = yield(copy.fetch('EntityTypes')[1])
    copy
  end

  def replace_set(document)
    copy = Mxrb::IO::BsonCodec.parse(Mxrb::IO::BsonCodec.serialize(document))
    copy.fetch('EntitySets')[1] = yield(copy.fetch('EntitySets')[1])
    copy
  end
end
# rubocop:enable Metrics/BlockLength
