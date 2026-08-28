# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'exported domain artifacts' do
  it 'separates persistent entities, DTOs, OQL views, and datasets without losing OQL' do
    Dir.mktmpdir('mxrb-domain-artifacts-') do |dir|
      source = File.join(dir, 'Domain.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      define_domain_project(source)

      Mxrb::Exporter.new(source, exported).export!
      root = File.join(exported, 'modules', 'API_Rest')
      expect(File).to exist(File.join(root, 'domain', 'entities', 'product.rb'))
      expect(File).to exist(File.join(root, 'domain', 'dtos', 'product_dto.rb'))
      view_path = File.join(root, 'domain', 'oql_views', 'product_view.rb')
      expect(File.read(view_path)).to include(
        'oql_view source: "API_Rest.ProductViewSource"',
        'oql_source_document :ProductViewSource',
        'SELECT Name FROM API_Rest.Product'
      )
      expect(File.read(view_path)).not_to include('native_document', 'deep_structure:', 'bson_binary(')
      legacy_view_path = File.join(root, 'domain', 'oql_views', 'legacy_view.rb')
      expect(File.read(legacy_view_path)).to include(
        'oql_view query: "SELECT Name FROM API_Rest.Product"'
      )
      dataset_path = File.join(root, 'application', 'queries', 'datasets', 'product_data.rb')
      expect(File.read(dataset_path)).to include('DataSets$DataSet', 'OqlDataSetSource')
      enumeration_path = File.join(root, 'domain', 'enumerations', 'location_type.rb')
      expect(File.read(enumeration_path)).to include('enumeration :LocationType', 'value :Warehouse')
      expect(File.read(enumeration_path)).not_to include('native_document', 'bson_binary(')
      constant_path = File.join(root, 'domain', 'constants', 'api_address.rb')
      expect(File.read(constant_path)).to include('constant :ApiAddress', 'https://old.example')
      expect(File.read(constant_path)).not_to include('native_document', 'bson_binary(')
      expect(File.read(File.join(root, 'domain', 'model.rb'))).to include('dtos', 'oql_views')
      expect(File.read(File.join(root, 'application', 'application.rb'))).to include('datasets')

      File.write(view_path, File.read(view_path).sub('SELECT Name', 'SELECT Name, Code'))
      File.write(constant_path, File.read(constant_path).sub('https://old.example', 'https://new.example'))
      generate(exported, rebuilt)

      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        expect(project.modules.first.entities.map(&:name)).to contain_exactly(
          'LegacyView', 'Product', 'ProductDTO', 'ProductView'
        )
        query = project.oql_queries.find { _1.name == 'ProductViewSource' }
        expect(query.oql).to include('SELECT Name, Code')
        expect(project.oql_queries.find { _1.name == 'ProductData' }.kind).to eq(:dataset)
        expect(project.oql_queries.find { _1.name == 'LegacyView' }.kind).to eq(:view_entity)
        expect(project.modules.first.enumerations.map { _1['Name'] }).to include('LocationType')
        expect(project.modules.first.constants.find { _1['Name'] == 'ApiAddress' })
          .to include('DefaultValue' => 'https://new.example')
      end
    end
  end

  def define_domain_project(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:API_Rest) do
        entity(:Product) { string :Name }
        entity(:ProductDTO) do
          non_persistent!
          string :Name
        end
        entity(:ProductView) do
          oql_view source: 'API_Rest.ProductViewSource'
          string :Name
        end
        entity(:LegacyView) do
          oql_view query: 'SELECT Name FROM API_Rest.Product'
          string :Name
        end
        enumeration(:LocationType) { value :Warehouse, caption: 'Warehouse' }
        constant :ApiAddress, type: :string, value: 'https://old.example'
        native_document :ProductViewSource,
                        type: 'DomainModels$ViewEntitySourceDocument',
                        deep_structure: {
                          'Oql' => 'SELECT Name FROM API_Rest.Product'
                        }
        native_document :ProductData, type: 'DataSets$DataSet', deep_structure: {
          'Source' => {
            '$Type' => 'DataSets$OqlDataSetSource',
            'Query' => 'SELECT Name FROM API_Rest.Product'
          }
        }
      end
    end
  end

  it 'requires an OQL source or inline query' do
    builder = Mxrb::Dsl::EntityBuilder.new(:BrokenView)
    expect { builder.oql_view }.to raise_error(ArgumentError, /requires source or query/)
  end

  it 'keeps a native view entity recognizable when it has no editable query field' do
    entity = Mxrb::Model::Entity.new
    entity.id = SecureRandom.uuid
    entity.name = 'OpaqueView'
    entity.persistable = false
    entity.documentation = ''
    entity.native_type = 'DomainModels$ViewEntity'
    entity.access_rules = []
    entity.indexes = []
    entity.system_members = {}
    mod = Struct.new(:name, :entities).new('API_Rest', [entity])

    source = Mxrb::Exporter.allocate.send(:entity_source, entity, mod, [])
    expect(source).to include('entity :OpaqueView', 'non_persistent!')
    expect(source).not_to include('oql_view ')
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
# rubocop:enable Metrics/BlockLength
