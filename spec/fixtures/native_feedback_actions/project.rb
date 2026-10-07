# frozen_string_literal: true

require 'mxrb'
require 'fileutils'
require 'json'
cases = JSON.parse(File.read(File.expand_path('../feedback_action_cases.json', __dir__)))
            .reject { _1['input'].nil? }
source_directory = ENV.fetch('MXRB_FEEDBACK_ACTIONS_DIR')
output_path = ENV.fetch('MXRB_OUTPUT_PATH')
# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :FeedbackModule do
    entity(:Probe) { string :Name }
    microflow :Load do
      return_type 'FeedbackModule.Probe'
      create_object 'FeedbackModule.Probe', as: :probe, set: { Name: "'Feedback oracle'" }
      return_value '$probe'
    end
    java_action :ValidateEmail,
                parameters: [{ name: 'EmailAddress', type: { kind: :basic, type: { kind: :string } } }],
                return_type: { kind: :boolean }
    java_action :XSS_Sanitizer,
                parameters: [{ name: 'stringToSanitize', type: { kind: :basic, type: { kind: :string } } }],
                return_type: { kind: :string }
    cases.each_with_index do |item, index|
      action, parameter = if item['kind'] == 'email'
                            %w[ValidateEmail EmailAddress]
                          else
                            %w[XSS_Sanitizer stringToSanitize]
                          end
      arguments = { "FeedbackModule.#{action}.#{parameter}" => "'#{item['input'].gsub("'", "''")}'" }
      microflow "Case#{index}" do
        return_type :String
        call_java "FeedbackModule.#{action}", as: :result, pass: arguments
        return_value 'toString($result)'
      end
    end
    page :Home do
      title 'Feedback compatibility'
      data_source microflow: 'FeedbackModule.Load'
      text_box :Name, attribute: 'FeedbackModule.Probe.Name', caption: 'Name'
    end
  end
  navigation { profile :Responsive, home_page: 'FeedbackModule.Home' }
end
# rubocop:enable Metrics/BlockLength

java_directory = File.join(File.dirname(output_path), 'javasource', 'feedbackmodule', 'actions')
FileUtils.mkdir_p(java_directory)
%w[ValidateEmail XSS_Sanitizer].each do |name|
  source = File.join(source_directory, "#{name}.java")
  digest = Digest::SHA256.hexdigest(File.binread(source).gsub("\r\n", "\n"))
  unless Mxrb::RubyApp::KnownJavaActions::SOURCES.fetch(name).include?(digest)
    raise "Unrecognized Feedback source: #{name}"
  end

  FileUtils.cp(source, java_directory)
end
