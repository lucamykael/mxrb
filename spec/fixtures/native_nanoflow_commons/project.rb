# frozen_string_literal: true

require 'mxrb'
require 'fileutils'

output = ENV.fetch('MXRB_OUTPUT_PATH')
source_directory = ENV.fetch('MXRB_COMMONS_JAVASCRIPT_DIR')
text = 'Olá 世界 🌍'
encoded = 'T2zDoSDkuJbnlYwg8J+MjQ=='
object_type = { kind: :concrete_entity, entity: 'NanoflowCommons.Probe' }
actions = {
  'Base64Encode' => [{ 'stringToEncode' => { kind: :string } }, { kind: :string }],
  'Base64Decode' => [{ 'base64' => { kind: :string } }, { kind: :string }],
  'GetPlatform' => [{}, { kind: :enumeration, enumeration: 'NanoflowCommons.Platform' }],
  'GetGuid' => [{ 'EntityObject' => object_type }, { kind: :string }],
  'FindObjectWithGUID' => [{ 'list' => { kind: :list, parameter: object_type },
                             'objectGUID' => { kind: :string } }, object_type]
}
# rubocop:disable Metrics/BlockLength
Mxrb.define(output) do
  mendix_version '11.12.1'
  self.module :NanoflowCommons do
    entity(:Probe) { string :Name }
    enumeration(:Platform) do
      value :Web, caption: 'Web'
      value :Native_mobile, caption: 'Native mobile'
      value :Hybrid_mobile, caption: 'Hybrid mobile'
    end
    microflow :Load do
      create_object 'NanoflowCommons.Probe', as: :probe, set: { Name: "'Commons oracle'" }
      return_type 'NanoflowCommons.Probe'
      return_value '$probe'
    end
    actions.each do |name, (parameters, result)|
      documentation = case name
                      when 'GetGuid' then 'Get the Mendix Object GUID.'
                      when 'GetPlatform'
                        'Get the client platform (NanoflowCommons.Platform) where the action is running.'
                      else ''
                      end
      entries = parameters.map do |key, type|
        { name: key, type: { kind: :basic, type: },
          description: name == 'GetGuid' ? 'This field is required.' : '' }
      end
      javascript_action name, parameters: entries, return_type: result, platform: :Web, documentation: documentation
    end
    { 'Encode' => ['Base64Encode', 'stringToEncode', "'#{text}'"],
      'Decode' => ['Base64Decode', 'base64', "'#{encoded}'"],
      'PlatformName' => ['GetPlatform', nil, nil] }.each do |flow, (action, parameter, value)|
      nanoflow flow do
        pass = parameter ? { "NanoflowCommons.#{action}.#{parameter}" => value } : {}
        call_javascript "NanoflowCommons.#{action}", as: :result, pass: pass
        show_message '{1}', parameters: ['toString($result)'], blocking: true
      end
    end
    nanoflow :ObjectLookup do
      create_object 'NanoflowCommons.Probe', as: :probe, set: { Name: "'Found synthetic object'" }
      call_javascript 'NanoflowCommons.GetGuid', as: :guid,
                                                 pass: { 'NanoflowCommons.GetGuid.EntityObject' => '$probe' }
      create_list 'NanoflowCommons.Probe', as: :items
      change_list :items, action: :add, value: '$probe'
      change_list :items, action: :remove, value: '$probe'
      change_list :items, action: :add, value: '$probe'
      change_list :items, action: :clear, value: '$probe'
      change_list :items, action: :add, value: '$probe'
      lookup = { 'NanoflowCommons.FindObjectWithGUID.list' => '$items',
                 'NanoflowCommons.FindObjectWithGUID.objectGUID' => '$guid' }
      call_javascript 'NanoflowCommons.FindObjectWithGUID', as: :found, pass: lookup
      show_message '{1}', parameters: ['$found/Name'], blocking: true
    end
    page :Home do
      title 'Commons oracle'
      data_source microflow: 'NanoflowCommons.Load'
      text_box :Name, attribute: 'NanoflowCommons.Probe.Name', caption: 'Name'
      %w[Encode Decode PlatformName ObjectLookup].each do |flow|
        button(flow, caption: flow) { on_click nanoflow: "NanoflowCommons.#{flow}" }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'NanoflowCommons.Home' }
end
# rubocop:enable Metrics/BlockLength

target = File.join(File.dirname(output), 'javascriptsource', 'nanoflowcommons', 'actions')
FileUtils.mkdir_p(target)
actions.each_key do |name|
  source = File.join(source_directory, "#{name}.js")
  digest = Digest::SHA256.hexdigest(File.binread(source).gsub("\r\n", "\n"))
  unless Mxrb::RubyApp::KnownJavaScriptActions::COMMONS_SOURCES.fetch(name) == digest
    raise "Unrecognized Commons source: #{name}"
  end

  FileUtils.cp(source, target)
end
FileUtils.mkdir_p(File.join(target, 'node_modules'))
FileUtils.cp_r(File.join(source_directory, 'node_modules', 'js-base64'), File.join(target, 'node_modules'))
