# frozen_string_literal: true

require 'mxrb'
require 'json'

cases = JSON.parse(File.read(File.join(__dir__, 'cases.json')))
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Compatibility do
    entity(:Item) do
      string :Name
      decimal :Amount
    end
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
        if item['persist_decimal']
          create_object 'Compatibility.Item', as: :stored, commit: true,
                                              set: { Name: "'Decimal oracle'", Amount: item['persist_decimal'] }
        end
        if item['read_decimal']
          retrieve_objects 'Compatibility.Item', as: :stored, single: true, xpath: "[Name = 'Decimal oracle']"
        end
        return_value item.fetch('expression')
      end
    end
    nanoflow :DecimalClient do
      return_type :Decimal
      return_value '0.1 + 0.2'
    end
    microflow :Load do
      return_type 'Compatibility.Item'
      create_object 'Compatibility.Item', as: :item,
                                          set: { Name: "'Compatibility oracle'", Amount: '9007199254740993.12345678' }
      return_value '$item'
    end
    microflow :AdvanceDecimal do
      parameter :Item, type: 'Compatibility.Item'
      change_object(:Item, commit: true, refresh: true) do
        set 'Compatibility.Item/Amount', to: '$Item/Amount + 0.00000001'
      end
    end
    page :Home do
      title 'Compatibility oracle'
      data_source microflow: 'Compatibility.Load'
      text_box :Name, attribute: 'Compatibility.Item.Name', caption: 'Name'
      number_input :Amount, attribute: 'Compatibility.Item.Amount', caption: 'Amount'
      button :Advance, caption: 'Advance decimal' do
        on_click microflow: 'Compatibility.AdvanceDecimal',
                 pass: { 'Compatibility.AdvanceDecimal.Item' => '$currentObject' }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Compatibility.Home' }
end
# rubocop:enable Metrics/BlockLength
