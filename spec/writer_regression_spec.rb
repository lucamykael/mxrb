# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'writer regressions from the VetClinic acceptance project' do # rubocop:disable Metrics/BlockLength
  it 'updates a return-only microflow when its return expression changes' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'return-value.mpr')
      define_flow = lambda do |expression|
        Mxrb.define(path) do
          mendix_version '11.12.1'
          self.module :Clinic do
            microflow(:VAL_Animal) do
              return_type :Boolean
              return_value expression
            end
          end
        end
      end
      define_flow.call('false')
      define_flow.call('true')

      ending = Mxrb.open(path) do |project|
        project.microflows.first.objects.find { _1['$Type'] == 'Microflows$EndEvent' }
      end
      expect(ending['ReturnValue']).to eq('true')
    end
  end

  it 'stores navigation glyph names as valid Mendix integer codes' do
    writer = Mxrb::Writer.new('/tmp/navigation.mpr', version: '11.12.1', modules: [])
    expect(writer.send(:glyph_icon_doc, 'home')['Code']).to eq(57_377)
    expect(writer.send(:glyph_icon_doc, 'calendar_today')['Code']).to eq(57_609)
    expect(writer.send(:glyph_icon_doc, 57_349)['Code']).to eq(57_349)
    expect(writer.send(:glyph_icon_doc, nil)).to be_nil
    expect { writer.send(:glyph_icon_doc, 'not-a-mendix-glyph') }
      .to raise_error(ArgumentError, /unsupported navigation icon/)
  end

  it 'qualifies microflow call parameter identifiers for the Mendix loader' do
    writer = Mxrb::Writer.new('/tmp/call.mpr', version: '11.12.1', modules: [])
    action = writer.send(
      :activity_action_doc,
      type: :call_microflow, name: 'Clinic.Create', result_name: nil,
      variable: nil, use_return: false,
      mappings: [{ param: :Name, value: "'Buddy'" },
                 { param: 'Clinic.Create.Age', value: 3 }]
    )
    mappings = Mxrb::IO::BsonCodec.parse_array(action.dig('MicroflowCall', 'ParameterMappings'))[:items]
    expect(mappings.map { _1['Parameter'] }).to eq(%w[Clinic.Create.Name Clinic.Create.Age])
  end
end
