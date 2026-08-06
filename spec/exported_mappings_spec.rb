# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

EXPORTED_MAPPING_TYPES = {
  exports: 'ExportMappings$ExportMapping',
  imports: 'ImportMappings$ImportMapping',
  json_structures: 'JsonStructures$JsonStructure'
}.freeze

# rubocop:disable Metrics/BlockLength
RSpec.describe 'exported mapping documents' do
  it 'creates and extends layer aggregators idempotently' do
    Dir.mktmpdir('mxrb-aggregator-') do |dir|
      path = File.join(dir, 'application.rb')
      exporter = Mxrb::Exporter.allocate
      exporter.send(:append_to_aggregator, path, ['queries/one.rb'])
      exporter.send(:append_to_aggregator, path, ['queries/one.rb', 'queries/two.rb'])
      expect(File.read(path).lines.grep(/one\.rb/).size).to eq(1)
      expect(File.read(path)).to include('two.rb')
    end
  end

  it 'exports mappings as layered Ruby and updates them without moving or duplicating units' do
    Dir.mktmpdir('mxrb-exported-mappings-') do |dir|
      source = File.join(dir, 'Mappings.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:Integration) {}
      end
      add_mapping_documents(source)

      Mxrb.open(source) do |project|
        expect(project.modules.first.mapping_documents.map { _1[:type] })
          .to contain_exactly(*EXPORTED_MAPPING_TYPES.values)
      end

      exporter = Mxrb::Exporter.new(source, exported)
      used = { File.join('mappings', 'same.rb') => true }
      expect(exporter.send(:unique_relative_path, 'mappings', 'same', used))
        .to eq(File.join('mappings', 'same_2.rb'))
      exporter.export!
      files = EXPORTED_MAPPING_TYPES.keys.to_h do |category|
        [category, Dir[File.join(exported, 'modules', 'Integration', 'infrastructure',
                                 'mappings', category.to_s, '*.rb')].fetch(0)]
      end
      expect(File.read(files.fetch(:exports))).to include('type: "ExportMappings$ExportMapping"')
      expect(File.read(files.fetch(:imports))).to include('unit_id:', 'container_id:')
      expect(File.read(files.fetch(:json_structures))).to include('bson_binary(')
      native_source = File.read(File.join(exported, '.mxrb', 'native_units.rb'))
      EXPORTED_MAPPING_TYPES.each_value { expect(native_source).not_to include(_1) }

      import_path = files.fetch(:imports)
      File.write(import_path, File.read(import_path).sub('"Marker" => "before"',
                                                         '"Marker" => "after"'))
      generate(exported, rebuilt)

      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        documents = project.all_units.filter_map do |unit|
          doc = project.parse_bson(unit)
          [unit, doc] if EXPORTED_MAPPING_TYPES.value?(doc['$Type'])
        end
        expected = EXPORTED_MAPPING_TYPES.values.to_h { [_1, 1] }
        expect(documents.map { _2['$Type'] }.tally).to eq(expected)
        imported = documents.find { _2['$Type'] == EXPORTED_MAPPING_TYPES[:imports] }
        expect(imported.last['Marker']).to eq('after')
        documents.map(&:first).each do |unit|
          parent = project.parse_bson(project.raw_unit(unit.fetch('ContainerID')))
          expect(parent).to include('$Type' => 'Projects$Folder', 'Name' => 'Mappings')
        end
      end
    end
  end

  it 'exports a published REST service and all of its routes under endpoints' do
    Dir.mktmpdir('mxrb-exported-endpoints-') do |dir|
      source = File.join(dir, 'Api.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      Mxrb.define(source) { self.module(:API_Rest) {} }
      add_published_rest_service(source)

      Mxrb::Exporter.new(source, exported).export!
      endpoint = File.join(exported, 'modules', 'API_Rest', 'infrastructure',
                           'endpoints', 'api_service.rb')
      ruby = File.read(endpoint)
      expect(ruby).to include(
        'Rest$PublishedRestService', 'HttpMethod', 'Operations', 'orders/{id}',
        '"Version" => "1.0.0"', '"EnableCors" => true', '"RequiresAuthentication" => true',
        '"AllowedRoles"', '"HttpMethod" => "Post"'
      )
      infrastructure = File.read(File.join(File.dirname(File.dirname(endpoint)), 'infrastructure.rb'))
      expect(infrastructure).to include('endpoints', 'api_service.rb')
      consumed = File.join(exported, 'modules', 'API_Rest', 'infrastructure',
                           'integrations', 'master_entity_domain.rb')
      expect(File.read(consumed)).to include('Rest$ConsumedODataService', 'catalog.example')

      File.write(endpoint, ruby.sub('"Path" => "orders/{id}"', '"Path" => "orders/{orderId}"'))
      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        services = project.all_units.filter_map do |unit|
          doc = project.parse_bson(unit)
          doc if doc['$Type'] == 'Rest$PublishedRestService'
        end
        expect(services.size).to eq(1)
        operation = Mxrb::IO::BsonCodec.parse_array(services.first['Resources'])[:items]
                                       .flat_map { Mxrb::IO::BsonCodec.parse_array(_1['Operations'])[:items] }
                                       .first
        expect(operation['Path']).to eq('orders/{orderId}')
      end
    end
  end

  def add_mapping_documents(path) # rubocop:disable Metrics/MethodLength
    mpr = Mxrb::IO::MprFile.open(path)
    module_id = mpr.units_by_containment('Modules').first.fetch('UnitID')
    folder_id = mpr.insert_unit(
      container_uuid: module_id, containment_name: 'Folders',
      contents_doc: { '$Type' => 'Projects$Folder', 'Name' => 'Mappings' }
    )
    EXPORTED_MAPPING_TYPES.each_value do |type|
      name = type.split('$').last
      mpr.insert_unit(
        container_uuid: folder_id, containment_name: 'Documents',
        contents_doc: {
          '$Type' => type, 'Name' => name, 'Marker' => 'before',
          'Blob' => BSON::Binary.new('mapping-bytes')
        }
      )
    end
  ensure
    mpr&.close
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end

  def add_published_rest_service(path) # rubocop:disable Metrics/MethodLength
    mpr = Mxrb::IO::MprFile.open(path)
    module_id = mpr.units_by_containment('Modules').first.fetch('UnitID')
    operation = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Rest$PublishedRestServiceOperation',
      'HttpMethod' => 'Get', 'Path' => 'orders/{id}', 'Microflow' => 'API_Rest.GetOrder'
    }
    post_operation = operation.merge(
      '$ID' => SecureRandom.uuid, 'HttpMethod' => 'Post',
      'Path' => 'orders', 'Microflow' => 'API_Rest.CreateOrder'
    )
    resource = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Rest$PublishedRestServiceResource',
      'Name' => 'Orders',
      'Operations' => Mxrb::IO::BsonCodec.build_array([operation, post_operation], marker: 2)
    }
    mpr.insert_unit(
      container_uuid: module_id, containment_name: 'Documents',
      contents_doc: {
        '$Type' => 'Rest$PublishedRestService', 'Name' => 'API_Service',
        'Version' => '1.0.0', 'Path' => 'rest/orders/v1', 'EnableCors' => true,
        'RequiresAuthentication' => true,
        'AllowedRoles' => Mxrb::IO::BsonCodec.build_array(%w[API_Rest.Admin API_Rest.User]),
        'Resources' => Mxrb::IO::BsonCodec.build_array([resource], marker: 3)
      }
    )
    mpr.insert_unit(
      container_uuid: module_id, containment_name: 'Documents',
      contents_doc: {
        '$Type' => 'Rest$ConsumedODataService', 'Name' => 'MasterEntityDomain',
        'MetadataUrl' => 'https://catalog.example/$metadata'
      }
    )
  ensure
    mpr&.close
  end
end
# rubocop:enable Metrics/BlockLength
