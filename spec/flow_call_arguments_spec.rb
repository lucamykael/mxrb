# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'typed flow call arguments' do
  it 'exports ordered call mappings as idiomatic Ruby blocks and round-trips them exactly' do
    Dir.mktmpdir('mxrb-flow-call-arguments-') do |dir|
      source = File.join(dir, 'Calls.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      define_project(source)

      Mxrb::Exporter.new(source, exported).export!
      ruby = exported_flow_source(exported, 'Caller')

      expect(ruby).to include(
        "call_microflow \"Calls.Target\", as: :Result do\n" \
        "    argument \"Calls.Target.Value\", \"$Input\"\n" \
        '  end',
        "call_java \"Calls.Normalize\", as: :Normalized do\n" \
        "    argument \"Text\", \"$Input\"\n" \
        "    entity_argument \"Entity\", \"Calls.Item\"\n" \
        "    microflow_argument \"Callback\", \"Calls.Target\"\n" \
        '  end',
        "call_nanoflow \"Calls.ClientTarget\" do\n" \
        "    argument \"Value\", \"$Input\"\n" \
        '  end'
      )
      expect(ruby).not_to include('pass:', '=>', 'unit_id:')

      generate(exported, rebuilt)
      expect(flow_document(rebuilt, 'Caller')).to eq(flow_document(source, 'Caller'))
    end
  end

  it 'keeps duplicate mappings and rejects mixed block/hash notation' do
    builder = Mxrb::Dsl::FlowBuilder.new(
      :Caller, runtime: :server, kind: :microflow, public: false
    )
    builder.call_microflow('Calls.Target') do
      argument 'Value', '$First'
      argument 'Value', '$Second'
    end

    expect(builder.to_h.dig(:body, 0, :mappings)).to eq(
      [
        { param: 'Value', value: '$First' },
        { param: 'Value', value: '$Second' }
      ]
    )
    expect do
      builder.call_microflow('Calls.Target', pass: { Value: '$Input' }) do
        argument 'Value', '$Other'
      end
    end.to raise_error(ArgumentError, /either pass: or a block/)
  end

  def define_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Calls) do
        entity(:Item) { string :Name }
        microflow(:Target) do
          parameter :Value, type: :string
          return_type :string
          return_value :Value
        end
        nanoflow(:ClientTarget) do
          parameter :Value, type: :string
          end_flow
        end
        microflow(:Caller) do
          parameter :Input, type: :string
          call_microflow 'Calls.Target', as: :Result, pass: {
            'Calls.Target.Value' => '$Input'
          }
          call_java 'Calls.Normalize', as: :Normalized, pass: {
            Text: '$Input',
            Entity: { kind: :entity, value: 'Calls.Item' },
            Callback: { kind: :microflow, value: 'Calls.Target' }
          }
          call_nanoflow 'Calls.ClientTarget', pass: { Value: '$Input' }
          return_value :Result
        end
      end
    end
  end

  def exported_flow_source(root, name)
    Dir[File.join(root, 'modules', 'Calls', 'application', '**', '*.rb')]
      .map { File.read(_1) }
      .find { _1.include?("microflow :#{name}") }
  end

  def flow_document(path, name)
    Mxrb.open(path) do |project|
      unit = project.all_units.find do |candidate|
        document = project.parse_bson(candidate)
        document['$Type'] == 'Microflows$Microflow' && document['Name'] == name
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
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
