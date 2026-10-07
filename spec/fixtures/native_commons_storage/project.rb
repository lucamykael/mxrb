# frozen_string_literal: true

require 'mxrb'
require 'fileutils'

output = ENV.fetch('MXRB_OUTPUT_PATH')
source_directory = ENV.fetch('MXRB_COMMONS_JAVASCRIPT_DIR')
actions = {
  'GetStorageItemString' => [%w[Key], :string],
  'SetStorageItemString' => [%w[Key Value], :void],
  'RemoveStorageItem' => [%w[Key], :boolean],
  'StorageItemExists' => [%w[Key], :boolean],
  'ClearLocalStorage' => [[], :boolean]
}
sources = actions.to_h do |name, _|
  source = File.binread(File.join(source_directory, "#{name}.js")).gsub("\r\n", "\n")
  unless Mxrb::RubyApp::KnownJavaScriptActions::COMMONS_SOURCES.fetch(name) == Digest::SHA256.hexdigest(source)
    raise "Unrecognized Commons source: #{name}"
  end

  [name, source]
end

# rubocop:disable Metrics/BlockLength
Mxrb.define(output) do
  mendix_version '11.12.1'
  self.module :NanoflowCommons do
    entity(:Probe) { string :Name }
    microflow :Load do
      create_object 'NanoflowCommons.Probe', as: :probe, set: { Name: "'Storage oracle'" }
      return_type 'NanoflowCommons.Probe'
      return_value '$probe'
    end
    actions.each do |name, (parameters, result)|
      lines = sources.fetch(name).split("/**\n", 2).last.split(' */', 2).first.lines
      documentation = lines.take_while { !_1.include?('@') }.map { _1.sub(/^ \* ?/, '').chomp }.join("\r\n")
      entries = parameters.map do |key|
        { name: key, type: { kind: :basic, type: { kind: :string } }, description: 'This field is required.' }
      end
      javascript_action name, parameters: entries, return_type: { kind: result }, platform: :Web,
                              documentation: documentation
    end
    { 'Write' => ['SetStorageItemString', { Key: "'mxrb-storage-oracle'", Value: "'Olá 世界 🌍'" }],
      'Read' => ['GetStorageItemString', { Key: "'mxrb-storage-oracle'" }],
      'Exists' => ['StorageItemExists', { Key: "'mxrb-storage-oracle'" }],
      'Remove' => ['RemoveStorageItem', { Key: "'mxrb-storage-oracle'" }],
      'Clear' => ['ClearLocalStorage', {}] }.each do |flow, (action, values)|
      nanoflow flow do
        pass = values.to_h { |key, value| ["NanoflowCommons.#{action}.#{key}", value] }
        call_javascript "NanoflowCommons.#{action}", as: (flow == 'Write' ? nil : :result), pass: pass
        show_message '{1}', parameters: [flow == 'Write' ? "'Written'" : 'toString($result)'], blocking: true
      end
    end
    page :Home do
      title 'Storage oracle'
      data_source microflow: 'NanoflowCommons.Load'
      text_box :Name, attribute: 'NanoflowCommons.Probe.Name', caption: 'Name'
      %w[Write Read Exists Remove Clear].each do |flow|
        button(flow, caption: flow) { on_click nanoflow: "NanoflowCommons.#{flow}" }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'NanoflowCommons.Home' }
end
# rubocop:enable Metrics/BlockLength

target = File.join(File.dirname(output), 'javascriptsource', 'nanoflowcommons', 'actions')
FileUtils.mkdir_p(target)
actions.each_key { FileUtils.cp(File.join(source_directory, "#{_1}.js"), target) }
