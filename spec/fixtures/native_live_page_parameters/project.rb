# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Live do
    entity(:Item) do
      boolean :Enabled
      string :Name
    end
    microflow :Open do
      create_object 'Live.Item', as: :item, commit: true, set: { Name: "'Initial'", Enabled: 'false' }
      show_page 'Live.Editor', pass: { 'Live.Editor.Item' => '$item' }
    end
    nanoflow :Toggle do
      parameter :Item, type: 'Live.Item'
      change_object :Item, set: { 'Live.Item.Enabled' => 'not($Item/Enabled)' }, refresh: true
    end
    microflow :Rename do
      parameter :Item, type: 'Live.Item'
      change_object :Item, set: { 'Live.Item.Name' => "'Updated'" }, commit: true, refresh: true
    end
    page :Home do
      title 'Live page arguments'
      button(:Open, caption: 'Open editor') { on_click microflow: 'Live.Open' }
    end
    page :Editor do
      title 'Live editor'
      parameter :Item, entity: 'Live.Item'
      data_view :ItemView, from: context(:Item, entity: 'Live.Item') do
        text :Name, caption: '{1}', parameters: ['$currentObject/Name'], class_name: 'live-name'
        text :Enabled, caption: 'Enabled', visible: '$currentObject/Enabled', class_name: 'live-enabled'
        button :Toggle, caption: 'Toggle', dynamic_class: "if $currentObject/Enabled then 'live-on' else 'live-off'" do
          on_click nanoflow: 'Live.Toggle', pass: { 'Live.Toggle.Item' => '$Item' }
        end
        button(:Rename, caption: 'Rename') do
          on_click microflow: 'Live.Rename', pass: { 'Live.Rename.Item' => '$Item' }
        end
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Live.Home' }
end
# rubocop:enable Metrics/BlockLength
