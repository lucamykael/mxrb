# frozen_string_literal: true

require 'mxrb'

destination = File.expand_path(ARGV.fetch(0))

# rubocop:disable Metrics/BlockLength
Mxrb.define(destination) do
  mendix_version '11.12.1'

  self.module :WidgetLab do
    enumeration :Status do
      value :Draft, caption: 'Draft'
      value :Ready, caption: 'Ready'
    end

    entity :Customer do
      string :Name
    end

    entity :Record do
      string :Title
      integer :Quantity
      string :Notes
      boolean :Active
      datetime :DueOn
      enum :Status, enumeration: 'WidgetLab.Status'
      association :Customer
    end

    microflow :Ping do
      show_message 'Widget action completed'
    end

    microflow :SeedReferences do
      create_object 'WidgetLab.Customer', as: :Customer,
                                          set: { Name: "'Certified customer'" }, commit: true
    end

    page :Dashboard do
      title 'Widget certification laboratory'
      data_source microflow: 'WidgetLab.SeedReferences'

      container :Introduction, class_name: 'widget-lab-introduction' do
        text :Heading, caption: 'Widget certification laboratory'
        button :Ping, caption: 'Run widget action' do
          on_click microflow: 'WidgetLab.Ping'
        end
        button :SeedCustomer, caption: 'Prepare reference data' do
          on_click microflow: 'WidgetLab.SeedReferences'
        end
      end

      data_grid :Records, entity: 'WidgetLab.Record' do
        column :Title, attribute: 'WidgetLab.Record/Title', caption: 'Title'
        column :Quantity, attribute: 'WidgetLab.Record/Quantity', caption: 'Quantity'
        toolbar do
          new_button
          delete_button
        end
      end

      text_box :Title, attribute: 'WidgetLab.Record/Title', caption: 'Title'
      number_input :Quantity, attribute: 'WidgetLab.Record/Quantity', caption: 'Quantity'
      text_area :Notes, attribute: 'WidgetLab.Record/Notes', caption: 'Notes', lines: 3
      check_box :Active, attribute: 'WidgetLab.Record/Active', caption: 'Active'
      date_picker :DueOn, attribute: 'WidgetLab.Record/DueOn', caption: 'Due date'
      drop_down :Status, attribute: 'WidgetLab.Record/Status', caption: 'Status'
      reference_selector :Customer, attribute: 'WidgetLab.Record_Customer',
                                    caption: 'Customer',
                                    display_attribute: 'WidgetLab.Customer.Name'

      tab_control :Details do
        tab_page :Primary, caption: 'Primary details' do
          text :PrimaryText, caption: 'Primary tab content'
        end
        tab_page :Secondary, caption: 'Secondary details' do
          text :SecondaryText, caption: 'Secondary tab content'
        end
      end
    end
  end

  navigation do
    profile :Responsive, home_page: 'WidgetLab.Dashboard', app_title: 'Widget Lab'
  end
end
# rubocop:enable Metrics/BlockLength
