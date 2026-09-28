# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Constant certification' do
  it 'keeps every Mendix constant type editable and identity-stable for two cycles' do
    Dir.mktmpdir('mxrb-constants-') do |dir|
      current = File.join(dir, 'Constants.mpr')
      build_source(current)
      baseline_ids = constant_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = Dir[File.join(exported, 'modules/App/domain/constants/*.rb')]
                 .map { File.read(_1) }.join("\n")
        %w[string integer boolean decimal].each do |type|
          expect(source).to include("type: :#{type}")
        end
        expect(source).to include('type: :date_time')
        expect(source).to include('exposed_to_client: true', 'type_id:', 'unit_id:')
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(constant_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        page(:Home) { title 'Constants' }
        constant :Text, type: :string, value: 'hello', exposed_to_client: true
        constant :Count, type: :integer, value: '42'
        constant :Enabled, type: :boolean, value: 'true'
        constant :Amount, type: :decimal, value: '12.50'
        constant :Moment, type: :datetime, value: '2026-01-01T00:00:00'
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Constants'
      end
    end
  end

  def constant_ids(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        next unless document['$Type'] == 'Constants$Constant'

        [
          document.fetch('Name'), unit.fetch('UnitID').to_s,
          Mxrb::IO::BsonCodec.extract_id(document.fetch('Type').fetch('$ID'))
        ]
      end.sort
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
