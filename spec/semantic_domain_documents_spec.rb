# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'semantic domain documents' do # rubocop:disable Metrics/BlockLength
  it 'round-trips enumerations, constants, and OQL sources without opaque BSON' do
    Dir.mktmpdir('mxrb-semantic-domain-') do |dir|
      source = File.join(dir, 'Domain.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      build_source(source)

      Mxrb::Exporter.new(source, exported).export!
      ruby = Dir[File.join(exported, 'modules', 'Catalog', 'domain', '**', '*.rb')]
             .map { File.read(_1) }.join("\n")
      expect(ruby).to include(
        'enumeration :Status', 'value :Open', 'constant :Endpoint',
        'oql_source_document :LocationView'
      )
      expect(ruby).not_to include('native_document', 'deep_structure:', 'bson_binary(')

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(domain_documents(rebuilt)).to eq(domain_documents(source))
    end
  end

  def build_source(path) # rubocop:disable Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Catalog) do
        enumeration :Status, remote_source: nil do
          value :Open, captions: { en_US: 'Open', pt_BR: 'Aberto' }, remote_value: nil
          value :Closed, caption: 'Closed'
        end
        constant :Endpoint, type: :string, value: 'https://example.test',
                            exposed_to_client: true
        entity(:LocationView) do
          string :Name, length: 100
          oql_view source: 'Catalog.LocationView'
        end
        oql_source_document :LocationView,
                            query: "FROM Catalog.Location\r\nSELECT Name as Name"
      end
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end

  def domain_documents(path)
    types = %w[
      Enumerations$Enumeration Constants$Constant DomainModels$ViewEntitySourceDocument
    ]
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [[document['$Type'], document['Name']], document] if types.include?(document['$Type'])
      end.to_h
    end
  end
end
