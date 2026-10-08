# frozen_string_literal: true

require 'mxrb'
require 'fileutils'
require 'base64'

output = ENV.fetch('MXRB_OUTPUT_PATH')
source_directory = ENV.fetch('MXRB_FEEDBACK_JAVASCRIPT_DIR')
widgets = File.join(File.dirname(output), 'widgets')
FileUtils.mkdir_p(widgets)
FileUtils.cp(ENV.fetch('MXRB_FEEDBACK_WIDGET_PACKAGE'), File.join(widgets, 'SprintrFeedbackWidget.mpk'))
widget_xml = Zip::File.open(ENV.fetch('MXRB_FEEDBACK_WIDGET_PACKAGE')) { _1.read('SprintrFeedback.xml') }
action_property = if widget_xml.include?('key="showFeedbackModalAction"')
                    :showFeedbackModalAction
                  else
                    :feedbackButtonAction
                  end
action_properties = action_property == :showFeedbackModalAction ? { showFeedbackModalMethod: 'custom' } : {}
target_properties = widget_xml.include?('key="targetContainerSelector"') ? { targetContainerSelector: 'body' } : {}
scroll_properties = widget_xml.include?('key="scrollableAreaSelector"') ? { scrollableAreaSelector: 'body' } : {}
theme_directory = ENV.fetch('MXRB_FEEDBACK_THEME_DIR')
%w[theme themesource theme-cache].each do |directory|
  FileUtils.cp_r(File.join(theme_directory, directory), File.dirname(output))
end
svg = '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="100">' \
      '<rect width="160" height="100" fill="#356ac3"/></svg>'
image = "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
actions = %w[JS_ToggleFeedbackScreenshotWidget JS_ToggleFeedbackAnnotateWidget JS_SetSingleLocalStorageObjectItem]

# rubocop:disable Metrics/BlockLength
Mxrb.define(output) do
  mendix_version '11.12.1'
  self.module :FeedbackModule do
    entity(:Probe) do
      non_persistent!
      string :Name
    end
    actions.each do |name|
      arguments = case name
                  when 'JS_ToggleFeedbackScreenshotWidget' then []
                  when 'JS_ToggleFeedbackAnnotateWidget' then ['fileBlobURL']
                  else %w[localStorageKey imageDataB64]
                  end
      parameters = arguments.map { { name: _1, type: { kind: :basic, type: { kind: :string } } } }
      source = File.binread(File.join(source_directory, "#{name}.js")).gsub("\r\n", "\n")
      lines = source.split("/**\n", 2).last.split(' */', 2).first.lines
      documentation = lines.take_while { !_1.include?('@') }.map { _1.sub(/^ \* ?/, '').chomp }.join("\r\n")
      result = { kind: name == 'JS_SetSingleLocalStorageObjectItem' ? :void : :string }
      javascript_action name, parameters:, return_type: result, platform: :Web, documentation:
    end
    microflow :Load do
      create_object 'FeedbackModule.Probe', as: :item, set: { Name: "'Capture oracle'" }
      return_type 'FeedbackModule.Probe'
      return_value '$item'
    end
    nanoflow(:Open) { show_message 'Feedback opened', blocking: true }
    capture_actions = { 'Screenshot' => 'JS_ToggleFeedbackScreenshotWidget',
                        'Annotate' => 'JS_ToggleFeedbackAnnotateWidget' }
    capture_actions.each do |flow, action|
      nanoflow flow do
        parameters = if flow == 'Annotate'
                       { 'FeedbackModule.JS_ToggleFeedbackAnnotateWidget.fileBlobURL' => "'#{image}'" }
                     else
                       {}
                     end
        call_javascript "FeedbackModule.#{action}", pass: parameters, as: :result
        call_javascript 'FeedbackModule.JS_SetSingleLocalStorageObjectItem', pass: {
          'FeedbackModule.JS_SetSingleLocalStorageObjectItem.localStorageKey' => "'mxrb-capture-#{flow.downcase}'",
          'FeedbackModule.JS_SetSingleLocalStorageObjectItem.imageDataB64' => '$result'
        }
        show_message 'Finished {1}', parameters: ["'#{flow}'"], blocking: true
      end
    end
    page :Home do
      title 'Feedback capture oracle'
      data_source microflow: 'FeedbackModule.Load'
      text_box :Name, attribute: 'FeedbackModule.Probe.Name', caption: 'Name'
      button(:Screenshot, caption: 'Capture page') { on_click nanoflow: 'FeedbackModule.Screenshot' }
      button(:Annotate, caption: 'Annotate image') { on_click nanoflow: 'FeedbackModule.Annotate' }
      pluggable_widget :Feedback, widget_id: 'SprintrFeedbackWidget.SprintrFeedback', properties: {
        sprintrapp: 'test-only', showAdvancedSettings: true, foreignObjectRendering: false,
        **target_properties, **scroll_properties, **action_properties,
        userDefinedButtonStyle: 'side',
        action_property => { action: { kind: :nanoflow, handler: 'FeedbackModule.Open' } },
        title_label: { text: 'Feedback' }, cancel_label: { text: 'Cancel' }, clear_label: { text: 'Clear' },
        annotate_label: { text: 'Annotate' }, take_screenshot_label: { text: 'Take screenshot' },
        done_label: { text: 'Done' }
      }
    end
  end
  navigation { profile :Responsive, home_page: 'FeedbackModule.Home' }
end
# rubocop:enable Metrics/BlockLength

target = File.join(File.dirname(output), 'javascriptsource', 'feedbackmodule', 'actions')
FileUtils.mkdir_p(target)
actions.each do |name|
  source = File.join(source_directory, "#{name}.js")
  digest = Digest::SHA256.hexdigest(File.binread(source).gsub("\r\n", "\n"))
  unless Mxrb::RubyApp::KnownJavaScriptActions::SOURCES.fetch(name) == digest
    raise "Unrecognized Feedback source: #{name}"
  end

  FileUtils.cp(source, target)
end
