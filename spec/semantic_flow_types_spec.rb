# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'semantic flow data types' do
  it 'round-trips parameter and result types without BSON literals' do
    Dir.mktmpdir('mxrb-flow-types-') do |dir|
      source = File.join(dir, 'Flows.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      define_project(source)

      Mxrb::Exporter.new(source, exported).export!
      ruby = File.read(Dir[File.join(exported, 'modules', 'Flows', 'application', '**', '*.rb')]
                       .find { File.read(_1).include?('microflow :Typed') })
      expect(ruby).to include(
        'parameter :Item, type: flow_type(', ':kind => :object',
        'return_type(flow_type(', ':kind => :list', ':entity => "Flows.Item"'
      )
      expect(ruby).not_to include('bson_binary(', '"$Type" => "DataTypes$')

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(flow_document(rebuilt)).to eq(flow_document(source))
    end
  end

  def define_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Flows) do
        entity(:Item) { string :Name }
        microflow(:Typed) do
          parameter :Item, type: {
            '$ID' => SecureRandom.uuid, '$Type' => 'DataTypes$ObjectType',
            'Entity' => 'Flows.Item'
          }
          return_type(
            '$ID' => SecureRandom.uuid, '$Type' => 'DataTypes$ListType',
            'Entity' => 'Flows.Item'
          )
          return_value '[]'
        end
      end
    end
  end

  def flow_document(path)
    Mxrb.open(path) do |project|
      unit = project.all_units.find do |candidate|
        document = project.parse_bson(candidate)
        document['$Type'] == 'Microflows$Microflow' && document['Name'] == 'Typed'
      end
      project.parse_bson(unit)
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
