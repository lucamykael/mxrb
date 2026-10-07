# frozen_string_literal: true

require 'mxrb'
require 'fileutils'

output = ENV.fetch('MXRB_OUTPUT_PATH')
source_directory = ENV.fetch('MXRB_FEEDBACK_JAVASCRIPT_DIR')
actions = {
  'WriteImage' => ['JS_SetSingleLocalStorageObjectItem', %w[localStorageKey imageDataB64],
                   ["'mxrb-feedback-oracle'", "'synthetic-image'"], :void],
  'ReadImage' => ['JS_GetSingleStringLocalStorageObjectItem', %w[LocalStorageKey ObjectItemKey],
                  ["'mxrb-feedback-oracle'", "'ImageB64'"], :string],
  'ReadBoolean' => ['JS_GetShowEmailBooleanLocalStorageObjectItem', %w[LocalStorageKey ObjectItemKey],
                    ["'mxrb-feedback-oracle'", "'ShowEmail'"], :boolean]
}
# rubocop:disable Metrics/BlockLength
Mxrb.define(output) do
  mendix_version '11.12.1'
  self.module :FeedbackModule do
    entity(:Probe) { string :Name }
    microflow :Load do
      return_type 'FeedbackModule.Probe'
      create_object 'FeedbackModule.Probe', as: :probe, set: { Name: "'Storage oracle'" }
      return_value '$probe'
    end
    actions.each do |flow, (name, parameters, values, kind)|
      javascript_action name,
                        parameters: parameters.map { |p| { name: p, type: { kind: :basic, type: { kind: :string } } } },
                        return_type: { kind: }, platform: :Web
      nanoflow flow do
        mapping = parameters.zip(values).to_h { |p, v| ["FeedbackModule.#{name}.#{p}", v] }
        call_javascript "FeedbackModule.#{name}", as: (kind == :void ? nil : :result), pass: mapping
        if kind == :void
          show_message 'stored', blocking: true
        else
          show_message '{1}', parameters: ['toString($result)'], blocking: true
        end
      end
    end
    page :Home do
      title 'Storage oracle'
      data_source microflow: 'FeedbackModule.Load'
      text_box :Name, attribute: 'FeedbackModule.Probe.Name', caption: 'Name'
      actions.each_key do |flow|
        button flow, caption: flow do
          on_click nanoflow: "FeedbackModule.#{flow}"
        end
      end
    end
  end
  navigation { profile :Responsive, home_page: 'FeedbackModule.Home' }
end
# rubocop:enable Metrics/BlockLength

target = File.join(File.dirname(output), 'javascriptsource', 'feedbackmodule', 'actions')
FileUtils.mkdir_p(target)
actions.each_value do |action|
  name = action.first
  source = File.join(source_directory, "#{name}.js")
  digest = Digest::SHA256.hexdigest(File.binread(source).gsub("\r\n", "\n"))
  unless Mxrb::RubyApp::KnownJavaScriptActions::SOURCES.fetch(name) == digest
    raise "Unrecognized Feedback source: #{name}"
  end

  FileUtils.cp(source, target)
end
