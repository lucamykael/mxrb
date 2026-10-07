# frozen_string_literal: true

require 'mxrb'
require 'fileutils'
output = ENV.fetch('MXRB_OUTPUT_PATH')
source_directory = ENV.fetch('MXRB_FEEDBACK_JAVASCRIPT_DIR')
# rubocop:disable Metrics/BlockLength
Mxrb.define(output) do
  mendix_version '11.12.1'
  self.module :FeedbackModule do
    entity(:Feedback) do
      non_persistent!
      %i[Name ActiveUserRoles PageName EnvironmentURL Browser].each { string _1, length: 0 }
      integer :ScreenWidth
      integer :ScreenHeight
    end
    %w[JS_PopulateFeedbackMetadata JS_SetFeedbackStorageObject JS_isStrictMode].each do |name|
      parameters = case name
                   when 'JS_PopulateFeedbackMetadata'
                     [{ name: 'Feedback',
                        type: { kind: :basic, type: { kind: :concrete_entity, entity: 'FeedbackModule.Feedback' } } }]
                   when 'JS_SetFeedbackStorageObject'
                     [{ name: 'key', type: { kind: :basic, type: { kind: :string } } },
                      { name: 'value',
                        type: { kind: :basic, type: { kind: :concrete_entity, entity: 'FeedbackModule.Feedback' } } }]
                   else []
                   end
      source = File.binread(File.join(source_directory, "#{name}.js")).gsub("\r\n", "\n")
      lines = source.split("/**\n", 2).last.split(' */', 2).first.lines
      documentation = lines.take_while { !_1.include?('@') }.map { _1.sub(/^ \* ?/, '').chomp }.join("\r\n")
      result = if name == 'JS_PopulateFeedbackMetadata'
                 { kind: :concrete_entity, entity: 'FeedbackModule.Feedback' }
               else
                 { kind: name == 'JS_isStrictMode' ? :boolean : :void }
               end
      javascript_action name, parameters:, return_type: result, platform: :Web, documentation:
    end
    microflow :Load do
      create_object 'FeedbackModule.Feedback', as: :item, set: { Name: "'Metadata oracle'" }
      return_type 'FeedbackModule.Feedback'
      return_value '$item'
    end
    nanoflow :Populate do
      parameter :Item, type: 'FeedbackModule.Feedback'
      call_javascript 'FeedbackModule.JS_PopulateFeedbackMetadata', pass: {
        'FeedbackModule.JS_PopulateFeedbackMetadata.Feedback' => '$Item'
      }
      call_javascript 'FeedbackModule.JS_SetFeedbackStorageObject', pass: {
        'FeedbackModule.JS_SetFeedbackStorageObject.key' => "'mxrb-metadata-oracle'",
        'FeedbackModule.JS_SetFeedbackStorageObject.value' => '$Item'
      }
      show_message '{1}', parameters: ['$Item/PageName'], blocking: true
    end
    nanoflow :Strict do
      call_javascript 'FeedbackModule.JS_isStrictMode', as: :result
      show_message '{1}', parameters: ['toString($result)'], blocking: true
    end
    page :Home do
      title 'Feedback metadata oracle'
      data_source microflow: 'FeedbackModule.Load'
      text_box :Name, attribute: 'FeedbackModule.Feedback.Name', caption: 'Name'
      button(:Populate, caption: 'Populate') do
        on_click nanoflow: 'FeedbackModule.Populate', pass: { 'FeedbackModule.Populate.Item' => '$currentObject' }
      end
      button(:Strict, caption: 'Strict') { on_click nanoflow: 'FeedbackModule.Strict' }
    end
  end
  navigation { profile :Responsive, home_page: 'FeedbackModule.Home' }
end
# rubocop:enable Metrics/BlockLength

target = File.join(File.dirname(output), 'javascriptsource', 'feedbackmodule', 'actions')
FileUtils.mkdir_p(target)
%w[JS_PopulateFeedbackMetadata JS_SetFeedbackStorageObject JS_isStrictMode].each do |name|
  source = File.join(source_directory, "#{name}.js")
  digest = Digest::SHA256.hexdigest(File.binread(source).gsub("\r\n", "\n"))
  unless Array(Mxrb::RubyApp::KnownJavaScriptActions::SOURCES.fetch(name)).include?(digest)
    raise "Unrecognized Feedback source: #{name}"
  end

  FileUtils.cp(source, target)
end
