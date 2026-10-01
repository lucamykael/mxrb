# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Editing do
    entity :Item do
      string :Name
      boolean :Unlocked
    end
    microflow :Load do
      return_type 'Editing.Item'
      retrieve_objects 'Editing.Item', as: :items
      list_operation :head, :items, as: :existing
      decision '$existing != empty' do
        on(true) { return_value '$existing' }
        on(false) do
          create_object 'Editing.Item', as: :item, commit: true,
                                        set: { Name: "'Original'", Unlocked: 'false' }
          return_value '$item'
        end
      end
    end
    page :Home do
      title 'Ruby editable application'
      data_source microflow: 'Editing.Load'
      text :Heading, caption: 'Ruby editable application'
      check_box :Unlock, attribute: 'Editing.Item.Unlocked', caption: 'Enable editing'
      data_view :Editable, from: context(entity: 'Editing.Item'), editable: :conditional do
        editable_when '$currentObject/Unlocked'
        body { text_box :Name, attribute: 'Editing.Item.Name', caption: 'Name' }
      end
      data_view :Locked, from: context(entity: 'Editing.Item'), editable: :never do
        body { text_box :ReadOnly, attribute: 'Editing.Item.Name', caption: 'Always read-only' }
      end
      data_grid :Items, entity: 'Editing.Item' do
        column :Name, attribute: 'Editing.Item.Name', caption: 'Item'
      end
      data_view :Selection, from: listen_to('Items'), editable: :never do
        body { text_box :SelectedName, attribute: 'Editing.Item.Name', caption: 'Selected item' }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Editing.Home' }
end
# rubocop:enable Metrics/BlockLength
