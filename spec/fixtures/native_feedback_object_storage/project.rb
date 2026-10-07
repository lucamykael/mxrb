# frozen_string_literal: true

require 'mxrb'
require 'fileutils'

output = ENV.fetch('MXRB_OUTPUT_PATH')
source_directory = ENV.fetch('MXRB_FEEDBACK_JAVASCRIPT_DIR')
actions = { 'WriteLegacy' => %w[JS_SetFeedbackStorageObject key value],
            'WriteCurrent' => %w[SetStorageItemObject Key Value] }
# rubocop:disable Metrics/BlockLength
Mxrb.define(output) do
  mendix_version '11.12.1'
  self.module :FeedbackModule do
    entity(:Related) { string :Name }
    entity(:Probe) do
      string :Name
      boolean :Active
      integer :Count
      decimal :Amount
      datetime :When
      association 'FeedbackModule.Related', name: :Probe_Related
    end
    actions.each_value do |name, key, value|
      description = name == 'SetStorageItemObject' ? 'This field is required.' : ''
      documentation = if name == 'SetStorageItemObject'
                        'Store a Mendix object in device storage, identified by a unique key. ' \
                          'Can be accesed by the GetStargeItemObject action. ' \
                          'Please note that users can clear the device storage.'
                      else
                        ''
                      end
      javascript_action name, parameters: [
        { name: key, description:, type: { kind: :basic, type: { kind: :string } } },
        { name: value, description:,
          type: { kind: :basic, type: { kind: :concrete_entity, entity: 'FeedbackModule.Probe' } } }
      ], return_type: { kind: :void }, platform: :Web, documentation:
    end
    javascript_action 'JS_GetSingleLocalStorageObjectItem', parameters: %w[LocalStorageKey ObjectItemKey].map { |name|
      { name:, type: { kind: :basic, type: { kind: :string } } }
    }, return_type: { kind: :string }, platform: :Web
    microflow :Load do
      return_type 'FeedbackModule.Probe'
      create_object 'FeedbackModule.Probe', as: :item, set: {
        Name: "'Object oracle'", Active: 'true', Count: '12', Amount: '9007199254740993.12345678',
        When: 'dateTimeUTC(2026, 1, 2, 3, 4, 5)'
      }
      return_value '$item'
    end
    actions.each do |flow, (action, key, value)|
      nanoflow flow do
        parameter :Item, type: 'FeedbackModule.Probe'
        call_javascript "FeedbackModule.#{action}", pass: {
          "FeedbackModule.#{action}.#{key}" => "'mxrb-object-oracle'", "FeedbackModule.#{action}.#{value}" => '$Item'
        }
        show_message 'stored', blocking: true
      end
    end
    %w[Name Amount].each do |member|
      nanoflow "Read#{member}" do
        call_javascript 'FeedbackModule.JS_GetSingleLocalStorageObjectItem', as: :result, pass: {
          'FeedbackModule.JS_GetSingleLocalStorageObjectItem.LocalStorageKey' => "'mxrb-object-oracle'",
          'FeedbackModule.JS_GetSingleLocalStorageObjectItem.ObjectItemKey' => "'#{member}'"
        }
        show_message '{1}', parameters: ['$result'], blocking: true
      end
    end
    page :Home do
      title 'Object storage oracle'
      data_source microflow: 'FeedbackModule.Load'
      text_box :Name, attribute: 'FeedbackModule.Probe.Name', caption: 'Name'
      actions.each_key do |flow|
        button(flow, caption: flow) do
          on_click nanoflow: "FeedbackModule.#{flow}", pass: { "FeedbackModule.#{flow}.Item" => '$currentObject' }
        end
      end
      %w[ReadName ReadAmount].each do |flow|
        button(flow, caption: flow) { on_click nanoflow: "FeedbackModule.#{flow}" }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'FeedbackModule.Home' }
end
# rubocop:enable Metrics/BlockLength

target = File.join(File.dirname(output), 'javascriptsource', 'feedbackmodule', 'actions')
FileUtils.mkdir_p(target)
(actions.values.map(&:first) + ['JS_GetSingleLocalStorageObjectItem']).each do |name|
  source = File.join(source_directory, "#{name}.js")
  digest = Digest::SHA256.hexdigest(File.binread(source).gsub("\r\n", "\n"))
  unless Mxrb::RubyApp::KnownJavaScriptActions::SOURCES.fetch(name) == digest
    raise "Unrecognized Feedback source: #{name}"
  end

  FileUtils.cp(source, target)
end
