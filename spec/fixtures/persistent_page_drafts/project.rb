# frozen_string_literal: true

require 'mxrb'

destination = ENV.fetch('MXRB_OUTPUT_PATH')
widgets = File.join(File.dirname(destination), 'widgets')
FileUtils.mkdir_p(widgets)
FileUtils.cp(ENV.fetch('MXRB_DATAGRID_PACKAGE'), File.join(widgets, 'com.mendix.widget.web.Datagrid.mpk'))

# rubocop:disable Metrics/BlockLength
Mxrb.define(destination) do
  mendix_version '11.12.1'
  self.module :Drafts do
    entity(:Item) { string :Name }
    microflow :Load do
      return_type 'Drafts.Item'
      create_object 'Drafts.Item', as: :item, set: { Name: "'Unsaved item'" }
      return_value '$item'
    end
    microflow :Rename do
      parameter :Item, type: 'Drafts.Item'
      change_object(:Item, refresh: true) { set 'Drafts.Item/Name', to: "'Changed before Save'" }
    end
    page :Home do
      title 'Persistent page drafts'
      data_source microflow: 'Drafts.Load'
      text :Heading, caption: 'Persistent page drafts'
      text_box :Name, attribute: 'Drafts.Item.Name', caption: 'Draft name'
      button :Rename, caption: 'Change draft' do
        on_click microflow: 'Drafts.Rename', pass: { 'Drafts.Rename.Item' => '$currentObject' }
      end
      button(:Save, caption: 'Save draft') { on_click action: :save_changes, close_page: false }
      data_grid :Saved, entity: 'Drafts.Item' do
        column :Name, attribute: 'Drafts.Item.Name', caption: 'Saved item'
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Drafts.Home' }
end
# rubocop:enable Metrics/BlockLength
