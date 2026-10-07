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
    entity(:Folder) do
      string :Name
      association 'Compatibility.Folder', name: :Folder_Parent, storage_format: :Table
      association 'Compatibility.Folder', name: :Folder_DirectParent, storage_format: :Column
      association 'Compatibility.Folder', name: :Folder_Links, type: :ReferenceSet
    end
    entity(:NumericProbe) do
      string :Name
      integer :Rank
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
        if item['xpath_numeric']
          numeric = item.fetch('xpath_numeric')
          constraint = "[Name = '#{item.fetch('name')}'][#{numeric.fetch('constraint')}]"
          create_object 'Compatibility.NumericProbe', as: :probe, commit: true,
                                                      set: { Name: "'#{item.fetch('name')}'",
                                                             Rank: numeric.fetch('rank').to_s,
                                                             Amount: numeric.fetch('amount') }
          retrieve_objects 'Compatibility.NumericProbe', as: :matches,
                                                         xpath: constraint
          aggregate :matches, function: :count, as: :match_count
        end
        if item['xpath']
          create_object 'Compatibility.Folder', as: :root, commit: true, set: { Name: "'root'" }
          create_object 'Compatibility.Folder', as: :child, commit: true do
            set :Name, to: "'child'"
            set_association :Folder_Parent, to: :root
            set_association :Folder_DirectParent, to: :root
          end
          create_object 'Compatibility.Folder', as: :leaf, commit: true do
            set :Name, to: "'leaf'"
            set_association :Folder_Parent, to: :child
            set_association :Folder_DirectParent, to: :child
          end
          create_list 'Compatibility.Folder', as: :links
          change_list :links, action: :add, value: '$root'
          change_list :links, action: :add, value: '$leaf'
          change_object(:child, commit: true) { set_association :Folder_Links, to: :links }
          retrieve_objects 'Compatibility.Folder', as: :matches, xpath: item['xpath']
          aggregate :matches, function: :count, as: :match_count
          list_operation :head, :matches, as: :match
        end
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
