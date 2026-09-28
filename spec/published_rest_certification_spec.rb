# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative 'fixtures/published_rest/project'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'published REST certification' do
  it 'keeps typed services and generated mappings stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-published-rest-certification-') do |dir|
      current = File.join(dir, 'source.mpr')
      PublishedRestFixture.build(current)
      baseline_ids = integration_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        endpoint = Dir[File.join(exported, 'modules', 'PublishedApi', 'infrastructure',
                                 'endpoints', '*.rb')].fetch(0)
        source = File.read(endpoint)
        expect(source).to include(
          'published_rest_service :ItemsApi', 'resource :items',
          'get :list_items', 'get :show_item', 'post :create_item'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(integration_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
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
        next unless integration_type?(document['$Type'])

        [document['$Type'], document['Name'], unit['UnitID'].to_s]
      end.sort
    end
  end

  def integration_type?(type)
    %w[
      Rest$PublishedRestService JsonStructures$JsonStructure ExportMappings$ExportMapping
    ].include?(type)
  end
end
# rubocop:enable Metrics/BlockLength
