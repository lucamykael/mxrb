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

  it 'writes a valid default log node for the Mendix 11 Runtime' do
    activity = {
      type: :log_message, message: 'ready', level: :info, node: nil,
      include_stack: false, parameters: []
    }
    modern = Mxrb::Writer.new('/tmp/log-modern.mpr', version: '11.12.1', modules: [])
    legacy = Mxrb::Writer.new('/tmp/log-legacy.mpr', version: '10.24.0', modules: [])

    modern_action = modern.send(:activity_action_doc, activity)
    legacy_action = legacy.send(:activity_action_doc, activity)

    expect(modern_action).to include('Node' => "'MXRB'")
    expect(modern_action).not_to have_key('NodeModel')
    expect(legacy_action.dig('NodeModel', '$Type')).to eq('Expressions$NoExpression')
  end

  # rubocop:disable Metrics/BlockLength
  it 'uses Abort instead of Rollback throughout generated nanoflow graphs' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'nanoflow-errors.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :Ui do
          microflow(:ServerNotice) { show_message 'Server notice' }
          nanoflow :ClientNotice do
            decision 'true' do
              on(true) { show_message 'Accepted' }
              on(false) { show_message 'Rejected' }
            end
            show_message 'May fail'
            rescue_all { show_message 'Recovered' }
          end
        end
      end

      flows = Mxrb.open(path) do |project|
        project.mpr.units_by_containment('Documents').to_h do |unit|
          document = project.parse_bson(unit)
          [document['Name'], document]
        end
      end
      error_types = lambda do |value|
        case value
        when Hash
          [value['ErrorHandlingType'], *value.values.flat_map { error_types.call(_1) }].compact
        when Array
          value.flat_map { error_types.call(_1) }
        else
          []
        end
      end

      expect(error_types.call(flows.fetch('ClientNotice'))).to contain_exactly(
        'Abort', 'Abort', 'Abort', 'Abort', 'CustomWithoutRollBack'
      )
      expect(error_types.call(flows.fetch('ServerNotice'))).to eq(['Rollback'])
    end
  end
  # rubocop:enable Metrics/BlockLength
end
