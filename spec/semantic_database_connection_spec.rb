# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'semantic database connections' do # rubocop:disable Metrics/BlockLength
  it 'round-trips connections, queries, parameters, and mappings without opaque BSON' do
    Dir.mktmpdir('mxrb-semantic-database-') do |dir|
      source = File.join(dir, 'Database.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      build_source(source)

      Mxrb::Exporter.new(source, exported).export!
      path = File.join(exported, 'modules', 'Catalog', 'infrastructure',
                       'persistence', 'external', 'database.rb')
      ruby = File.read(path)
      expect(ruby).to include(
        'database_connection :Database', ':kind => :select',
        ':parameters => [', ':columns => ['
      )
      expect(ruby).not_to include('native_document', 'deep_structure:', 'bson_binary(')

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(database_document(rebuilt)).to eq(database_document(source))
    end
  end

  def build_source(path) # rubocop:disable Metrics/MethodLength
    query = query_spec
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Catalog) do
        database_connection :Database,
                            database_type: 'PostgreSQL', connection_string: 'Catalog.Source',
                            username: 'Catalog.User', password: 'Catalog.Password',
                            connection: {
                              id: SecureRandom.uuid, host: 'localhost', port: 5432, database: 'catalog'
                            },
                            properties: [{
                              id: SecureRandom.uuid, key: 'AuthenticationMethod',
                              value_id: SecureRandom.uuid, value: 'BASIC_AUTHENTICATION'
                            }],
                            queries: [query]
      end
    end
  end

  def query_spec # rubocop:disable Metrics/MethodLength
    {
      id: SecureRandom.uuid, name: 'SelectProducts', kind: :select,
      query: 'SELECT name FROM products WHERE name = {Name}',
      parameters: [{
        id: SecureRandom.uuid, name: 'Name', type: :string, type_id: SecureRandom.uuid,
        default: '', empty_as_null: false, mode: :input,
        sql_type: { id: SecureRandom.uuid, kind: :simple, name: 'varchar' }
      }],
      tables: [{
        id: SecureRandom.uuid, entity: 'Catalog.Product', table: 'products', columns: [{
          id: SecureRandom.uuid, attribute: 'Catalog.Product.Name', column: 'name',
          sql_type: { id: SecureRandom.uuid, kind: :limited, name: 'varchar', length: 100 }
        }]
      }]
    }
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end

  def database_document(path)
    Mxrb.open(path) do |project|
      unit = project.all_units.find do |raw|
        project.parse_bson(raw)['$Type'] == 'DatabaseConnector$DatabaseConnection'
      end
      project.parse_bson(unit)
    end
  end
end
