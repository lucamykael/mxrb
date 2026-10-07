# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'OQL view certification' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'round-trips source documents, values, and associations with stable identities' do
    Dir.mktmpdir('mxrb-oql-view-') do |dir|
      current = File.join(dir, 'OqlView.mpr')
      build_source(current)
      baseline = oql_snapshot(current)
      Mxrb.open(current) do |project|
        view = project.modules.find { _1.name == 'App' }.entities.find { _1.name == 'LocationsView' }
        expect(view.persistable).to be(true)
        expect(view).to be_oql_view
        # The Mendix flag permits database retrieval; the OQL source still
        # excludes the view from physical SQLite table creation.
        expect(Mxrb::Runtime::SchemaMigrator.derive(project).entities.map(&:name))
          .not_to include('App.LocationsView')
      end

      ruby_app = File.join(dir, 'ruby-app')
      ruby_rebuilt = File.join(dir, 'ruby-rebuilt.mpr')
      Mxrb::Exporter.new(current, ruby_app, mode: :ruby).export!
      ruby_source = File.read(File.join(ruby_app, 'app/models/app/locations_view.rb'))
      expect(ruby_source).to include(
        'oql_view source: "App.LocationsView", query:',
        'association "App.Location", name: "LocationId"'
      )
      expect(ruby_source).not_to include('native_document', 'deep_structure:', 'bson_binary(')
      Mxrb::RubyApp.compile(ruby_app, ruby_rebuilt)
      expect(Mxrb.compare(current, ruby_rebuilt)).to be_identical
      expect(oql_snapshot(ruby_rebuilt)).to eq(baseline)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = File.read(File.join(exported, 'modules/App/domain/oql_views/locations_view.rb'))
        expect(source).to include(
          'oql_view source: "App.LocationsView"',
          'oql_source_document :LocationsView', 'documentation: "Certified OQL source"',
          'association "App.Location"', 'name: "LocationId"'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(oql_snapshot(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    query = oql_query
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        entity(:Location) do
          string :Name, length: 100
          string :Address, length: 120
        end
        entity(:LocationsView) do
          string :Name, length: 100
          string :Address, length: 120
          association 'App.Location', name: :LocationId, cardinality: :many_to_one
          oql_view source: 'App.LocationsView'
        end
        oql_source_document(
          :LocationsView, query: query, documentation: 'Certified OQL source'
        )
        page(:Home) { title 'OQL view certification' }
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'OQL view certification'
      end
    end
  end

  def oql_query = "FROM App.Location\r\nSELECT ID as LocationId, Name as Name, Address as Address"

  def oql_snapshot(path)
    Mxrb.open(path) do |project|
      mod = project.modules.find { _1.name == 'App' }
      domain = project.mpr.parse_contents(project.mpr.unit(mod.domain_model.id))
      entity = native_items(domain['Entities'] || domain['entities']).find do |item|
        (item['Name'] || item['name']) == 'LocationsView'
      end
      entity_id = native_id(entity.fetch('$ID'))
      association = native_items(domain['Associations'] || domain['associations']).find do |item|
        native_id(item['ParentPointer']) == entity_id
      end
      source_document = mod.oql_view_documents.find { _1.fetch(:name) == 'LocationsView' }
      {
        entity_id:, entity_source: identity_document(entity.fetch('Source')),
        values: native_items(entity.fetch('Attributes')).to_h do |attribute|
          [attribute.fetch('Name'), identity_document(attribute.fetch('Value'))]
        end,
        association: {
          id: native_id(association.fetch('$ID')), name: association.fetch('Name'),
          source: identity_document(association.fetch('Source'))
        },
        source_document: {
          unit_id: source_document.fetch(:id),
          document_id: native_id(source_document.dig(:doc, '$ID')),
          documentation: source_document.dig(:doc, 'Documentation'),
          excluded: source_document.dig(:doc, 'Excluded'),
          export_level: source_document.dig(:doc, 'ExportLevel'),
          query: source_document.dig(:doc, 'Oql')
        }
      }
    end
  end

  def identity_document(document)
    document.reject { |key, _value| key == '$ID' }.merge('$ID' => native_id(document.fetch('$ID')))
  end

  def native_items(value) = Mxrb::IO::BsonCodec.parse_array(value)[:items]
  def native_id(value) = Mxrb::IO::BsonCodec.extract_id(value)

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
