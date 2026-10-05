# frozen_string_literal: true

require 'mxrb'

# Native React-client fixture: layout-only widgets belong to the layout.
# Legacy image/reference selector combinations remain in the standalone fixture.
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Presentation do
    layout :Shell, title: 'Native presentation'
    entity :Document do
      generalizes 'System.Image'
      boolean :Approved
    end
    microflow :Load do
      return_type 'Presentation.Document'
      retrieve_objects 'Presentation.Document', as: :documents
      list_operation :head, :documents, as: :existing
      decision '$existing != empty' do
        on(true) { return_value '$existing' }
        on(false) do
          create_object 'Presentation.Document', as: :document, commit: true,
                                                 set: { 'System.FileDocument.Name' => "'Native document'" }
          return_value '$document'
        end
      end
    end
    microflow(:Ping) { show_message 'Native action executed' }
    menu :Main do
      item 'Alternate page', page: 'Presentation.Alternate'
      item 'Run action', microflow: 'Presentation.Ping'
    end
    snippet_document :Details do
      parameters do
        name 'Document'
        parameter_type Mxrb::Forms::DataType.object('Presentation.Document')
      end
      widgets :data_view do
        name 'SnippetDocument'
        editability :always
        data_source :data_view_source do
          entity_ref 'Presentation.Document'
          source_variable { snippet_parameter 'Document' }
        end
        widgets :text_box do
          name 'SnippetName'
          attribute_ref 'System.FileDocument.Name'
          editable :always
        end
      end
    end
    page :Home do
      layout 'Presentation.Shell'
      title 'Native presentation'
      data_source microflow: 'Presentation.Load'
      page_title :Title
      menu_bar :MainMenu, menu: 'Presentation.Main'
      navigation_tree :Tree, menu: 'Presentation.Main'
      snippet :Details, from: 'Presentation.Details',
                        arguments: { Document: page_variable('dataView', kind: :widget) }
      file_manager :File, mode: :both
      image_uploader :UploadImage, caption: 'Image upload'
      check_box :Approved, attribute: 'Presentation.Document.Approved', caption: 'Approved'
      button(:Save, caption: 'Save') { on_click action: :save_changes, close_page: false }
      button(:Cancel, caption: 'Cancel') { on_click action: :cancel_changes, close_page: false }
      button(:Run, caption: 'Run action') { on_click microflow: 'Presentation.Ping' }
      layout_grid :ResponsiveGrid do
        row horizontal_alignment: :center do
          column(desktop: 6, tablet: 8, phone: 12) { text :First, caption: 'First responsive column' }
          column(desktop: 6, tablet: 4, phone: 12) { text :Second, caption: 'Second responsive column' }
        end
      end
    end
    page(:Alternate) do
      layout 'Presentation.Shell'
      text :Content, caption: 'Alternate page content'
    end
  end
  navigation do
    profile :Responsive, home_page: 'Presentation.Home' do
      item 'Home', page: 'Presentation.Home'
      item 'Alternate', page: 'Presentation.Alternate'
    end
  end
end
# rubocop:enable Metrics/BlockLength
