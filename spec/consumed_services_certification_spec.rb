# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative 'fixtures/consumed_services/project'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'consumed services certification' do
  it 'keeps typed REST calls and consumed OData stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-consumed-services-certification-') do |dir|
      current = File.join(dir, 'source.mpr')
      ConsumedServicesFixture.build(current)
      baseline_ids = integration_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        sources = ruby_sources(exported)
        expect(sources).to include(
          'consumed_odata_service :Directory', 'call_rest method: :get',
          'username: "\'certification-user\'"', 'password: "\'certification-password\'"',
          'header "Accept"', 'header "X-Correlation-Id"'
        )
        expect(sources).not_to include(
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

  def ruby_sources(exported)
    patterns = [
      File.join(exported, 'modules', 'ConsumedServices', 'application', 'use_cases', '*.rb'),
      File.join(exported, 'modules', 'ConsumedServices', 'infrastructure', 'integrations', '*.rb')
    ]
    files = patterns.flat_map { Dir[_1] }
    files.sort.map { File.read(_1) }.join("\n")
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
    %w[Rest$ConsumedODataService Microflows$Microflow].include?(type)
  end
end
# rubocop:enable Metrics/BlockLength
