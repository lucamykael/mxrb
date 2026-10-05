# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Core do
    enumeration :Status do
      value :Open, caption: 'In progress'
      value :Done, caption: 'Completed'
    end
    entity :Item do
      string :Name
      boolean :Active
      enum :Status, enumeration: 'Core.Status', default: 'Open'
    end
    microflow :Load do
      return_type 'Core.Item'
      retrieve_objects 'Core.Item', as: :items
      list_operation :head, :items, as: :existing
      decision '$existing != empty' do
        on(true) { return_value '$existing' }
        on(false) do
          create_object 'Core.Item', as: :item, commit: true,
                                     set: { Name: "'Original'", Active: 'false', Status: 'Core.Status.Open' }
          return_value '$item'
        end
      end
    end
    page :Home do
      title 'Ruby core widgets'
      data_source microflow: 'Core.Load'
      page_title :Title
      tab_control :Details do
        tab_page :General, caption: 'General' do
          text_box :Name, attribute: 'Core.Item.Name', caption: 'Name'
          radio_button_group :Active, attribute: 'Core.Item.Active', caption: 'Active', horizontal: true
        end
        tab_page :Progress, caption: 'Progress' do
          radio_button_group :Status, attribute: 'Core.Item.Status', caption: 'Status'
          data_view :Completed, from: context(entity: 'Core.Item'), editable: :conditional do
            editable_when '$currentObject/Status = Core.Status.Done'
            body { text_box :CompletedName, attribute: 'Core.Item.Name', caption: 'Editable when completed' }
          end
          data_view :Locked, from: context(entity: 'Core.Item'), editable: :never do
            body { radio_button_group :LockedStatus, attribute: 'Core.Item.Status', caption: 'Read-only status' }
          end
        end
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Core.Home' }
end
# rubocop:enable Metrics/BlockLength
