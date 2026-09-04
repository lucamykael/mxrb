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
        'parameter :Item, type: object_of("Flows.Item"',
        'return_type(list_of("Flows.Item"'
      )
      expect(ruby).not_to include('flow_type(', 'bson_binary(', '"$Type" => "DataTypes$')
      expect(ruby).not_to include('unit_id:', 'relative_middle_point:', 'body_fingerprint')
      metadata = JSON.parse(File.read(File.join(exported, '.mxrb', 'semantic_metadata.json')))
      expect(metadata.dig('modules', 'Flows', 'flows', 'Typed', 'unit_id')).not_to be_empty

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(flow_document(rebuilt)).to eq(flow_document(source))
    end
  end

  it 'serializes Ruby long aliases as the Mendix Integer data type' do
    Dir.mktmpdir('mxrb-long-type-') do |dir|
      path = File.join(dir, 'LongAlias.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Flows) do
          microflow(:LongAlias) do
            parameter :identifier, type: :Long
            return_type :Long
            return_value '$identifier'
          end
        end
      end

      document = Mxrb::IO::MprFile.open(path, readonly: true).then do |mpr|
        mpr.all_units.map { mpr.parse_contents(_1) }
           .find { _1['$Type'] == 'Microflows$Microflow' && _1['Name'] == 'LongAlias' }
      ensure
        mpr&.close
      end
      parameters = Mxrb::IO::BsonCodec.parse_array(
        document.fetch('ObjectCollection').fetch('Objects')
      )[:items]
      parameter = parameters.find do |candidate|
        candidate.is_a?(Hash) && candidate['$Type'] == 'Microflows$MicroflowParameter'
      end
      expect(parameter.dig('VariableType', '$Type')).to eq('DataTypes$IntegerType')
      expect(document.dig('MicroflowReturnType', '$Type')).to eq('DataTypes$IntegerType')
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
