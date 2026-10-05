# frozen_string_literal: true

require 'mxrb'
require 'json'

cases = JSON.parse(File.read(File.join(__dir__, 'cases.json')))
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Compatibility do
    entity(:Item) { string :Name }
    rule :NonEmpty do
      parameter :Value, type: :String
      return_type :Boolean
      return_value '$Value != empty and length(trim($Value)) > 0'
    end
    microflow :VerifyRule do
      return_type :String
      annotation 'Rule calls remain editable with annotations'
      as_node :note
      rule_decision 'Compatibility.NonEmpty' do
        argument 'Compatibility.NonEmpty.Value', "'Ruby'"
        on(true) { return_value "'passed'" }
        on(false) { return_value "'failed'" }
      end
      as_node :decision
      annotation_flow from: :note, to: :decision
    end
    cases.each do |item|
      microflow(item.fetch('name')) do
        return_type :String
        return_value item.fetch('expression')
      end
    end
    microflow :Load do
      return_type 'Compatibility.Item'
      create_object 'Compatibility.Item', as: :item, set: { Name: "'Compatibility oracle'" }
      return_value '$item'
    end
    page :Home do
      title 'Compatibility oracle'
      data_source microflow: 'Compatibility.Load'
      text_box :Name, attribute: 'Compatibility.Item.Name', caption: 'Name'
    end
  end
  navigation { profile :Responsive, home_page: 'Compatibility.Home' }
end
# rubocop:enable Metrics/BlockLength
