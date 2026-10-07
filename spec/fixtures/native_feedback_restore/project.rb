# frozen_string_literal: true

require 'mxrb'
require 'fileutils'

output = ENV.fetch('MXRB_OUTPUT_PATH')
source_directory = ENV.fetch('MXRB_FEEDBACK_JAVASCRIPT_DIR')
commons_source = File.join(source_directory, 'SetStorageItemString.js')
commons_text = File.binread(commons_source).gsub("\r\n", "\n")
unless Digest::SHA256.hexdigest(commons_text) == Mxrb::RubyApp::KnownJavaScriptActions::COMMONS_SOURCES.fetch('SetStorageItemString')
  raise 'Unrecognized storage string action'
end

actions = { 'ReadLegacy' => %w[JS_GetFeedbackStorageObject key entity],
            'ReadCurrent' => %w[GetStorageItemObject Key Entity] }
# rubocop:disable Metrics/BlockLength
Mxrb.define(output) do
  mendix_version '11.12.1'
  self.module :NanoflowCommons do
    documentation = 'Store a string value in the device storage, identified by a unique key. ' \
                    'Can be accessed by the GetStorageItemObject action. ' \
                    'Please note that users can clear the device storage.'
    parameters = %w[Key Value].map do |name|
      { name:, description: 'This field is required.', type: { kind: :basic, type: { kind: :string } } }
    end
    javascript_action 'SetStorageItemString', parameters:, return_type: { kind: :void }, platform: :Web,
                                              documentation:
  end
  self.module :FeedbackModule do
    entity(:Probe) do
      string :Name
      boolean :Active
      integer :Count
      decimal :Amount
      datetime :When
    end
    actions.each_value do |name, key, entity|
      description = name == 'GetStorageItemObject' ? 'This field is required.' : ''
      documentation = if name == 'GetStorageItemObject'
                        "What does this JavaScript action do?\r\n\r\n" \
                          'Get locally stored JSON object stored in clients internet browser. ' \
                          'Identified by a unique key. Can be accessed by the GetStorageItemObject action. ' \
                          'Please note that users can clear the device storage.'
                      else
                        ''
                      end
      javascript_action name, parameters: [
        { name: key, description:, type: { kind: :basic, type: { kind: :string } } },
        { name: entity, description:, type: { kind: :entity_type_parameter,
                                              pointer: '00000000-0000-0000-0000-000000000000' } }
      ], return_type: { kind: :concrete_entity, entity: 'FeedbackModule.Probe' }, platform: :Web, documentation:
    end
    microflow :Load do
      return_type 'FeedbackModule.Probe'
      create_object 'FeedbackModule.Probe', as: :item, set: { Name: "'Restore oracle'" }
      return_value '$item'
    end
    microflow :Echo do
      parameter :Item, type: 'FeedbackModule.Probe'
      return_type 'FeedbackModule.Probe'
      return_value '$Item'
    end
    nanoflow :Seed do
      value = JSON.generate(guid: '1970324836974592', Name: 'Current', Amount: '9007199254740993.12345678',
                            Count: '12', Active: false, When: 1_767_323_045_000)
      call_javascript 'NanoflowCommons.SetStorageItemString', pass: {
        'NanoflowCommons.SetStorageItemString.Key' => "'mxrb-restore-oracle'",
        'NanoflowCommons.SetStorageItemString.Value' => "'#{value}'"
      }
      show_message 'Seeded', blocking: true
    end
    actions.each do |flow, (action, key, entity)|
      nanoflow flow do
        call_javascript "FeedbackModule.#{action}", as: :result do
          argument "FeedbackModule.#{action}.#{key}", "'mxrb-restore-oracle'"
          entity_type_argument "FeedbackModule.#{action}.#{entity}", 'FeedbackModule.Probe'
        end
        call_microflow 'FeedbackModule.Echo', as: :echo, pass: { 'FeedbackModule.Echo.Item' => '$result' }
        show_message '{1}|{2}|{3}|{4}|{5}', parameters: [
          '$result/Name', 'toString($result/Amount)', 'toString($result/Count)',
          'toString($result/Active)', 'toString(dateTimeToEpoch($result/When))'
        ], blocking: true
      end
    end
    page :Home do
      title 'Object restore oracle'
      data_source microflow: 'FeedbackModule.Load'
      text_box :Name, attribute: 'FeedbackModule.Probe.Name', caption: 'Name'
      (['Seed'] + actions.keys).each do |flow|
        button(flow, caption: flow) { on_click nanoflow: "FeedbackModule.#{flow}" }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'FeedbackModule.Home' }
end
# rubocop:enable Metrics/BlockLength

commons_target = File.join(File.dirname(output), 'javascriptsource', 'nanoflowcommons', 'actions')
FileUtils.mkdir_p(commons_target)
FileUtils.cp(commons_source, commons_target)

target = File.join(File.dirname(output), 'javascriptsource', 'feedbackmodule', 'actions')
FileUtils.mkdir_p(target)
actions.each_value do |name, _key, _entity|
  source = File.join(source_directory, "#{name}.js")
  digest = Digest::SHA256.hexdigest(File.binread(source).gsub("\r\n", "\n"))
  unless Mxrb::RubyApp::KnownJavaScriptActions::SOURCES.fetch(name) == digest
    raise "Unrecognized Feedback source: #{name}"
  end

  FileUtils.cp(source, target)
end
