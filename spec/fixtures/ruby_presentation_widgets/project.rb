# frozen_string_literal: true

require 'mxrb'
require 'base64'

# Ten core presentation types with real native resource references.
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Presentation do
    entity(:Category) { string :Name }
    entity :Tag do
      string :Name
      association 'Presentation.Category', name: :Tag_Category
    end
    entity :Document do
      generalizes 'System.FileDocument'
      string :Name
      boolean :Approved
      association 'Presentation.Tag', type: :ReferenceSet, name: :Document_Tags
    end
    microflow :Load do
      return_type 'Presentation.Document'
      retrieve_objects 'Presentation.Document', as: :documents
      list_operation :head, :documents, as: :existing
      decision '$existing != empty' do
        on(true) { return_value '$existing' }
        on(false) do
          create_object 'Presentation.Category', as: :category, commit: true, set: { Name: "'Visible'" }
          create_object 'Presentation.Tag', as: :tag, commit: true,
                                            set: { Name: "'Ruby tag'", Tag_Category: '$category' }
          create_object 'Presentation.Tag', as: :hidden_tag, commit: true, set: { Name: "'Hidden tag'" }
          create_object 'Presentation.Document', as: :document, commit: true, set: { Name: "'Standalone'" }
          return_value '$document'
        end
      end
    end
    microflow(:Ping) { show_message 'Ruby action executed' }
    menu :Main do
      item 'Alternate page', page: 'Presentation.Alternate'
      item 'Actions' do
        item 'Run Ruby', microflow: 'Presentation.Ping'
      end
    end
    native_document :Images, type: 'Images$ImageCollection', deep_structure: {
      'Images' => [2, {
        '$Type' => 'Images$Image', 'Name' => 'Pixel', 'ImageFormat' => 'png',
        'Image' => BSON::Binary.new(Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1kAAAAASUVORK5CYII='))
      }]
    }
    native_document :Details, type: 'Forms$Snippet', deep_structure: {
      'Widgets' => [2, {
        '$Type' => 'Forms$TextBox', 'Name' => 'SnippetName',
        'AttributeRef' => { '$Type' => 'DomainModels$AttributeRef', 'Attribute' => 'Presentation.Document.Name' }
      }], 'Parameters' => [2], 'Variables' => [2]
    }
    page :Home do
      title 'Standalone presentation'
      data_source microflow: 'Presentation.Load'
      menu_bar :MainMenu, menu: 'Presentation.Main'
      button(:EditDraft, caption: 'Edit draft') { on_click page: 'Presentation.Edit' }
      navigation_tree :Tree, menu: 'Presentation.Main'
      static_image :Logo, image: 'Presentation.Images.Pixel', alternative_text: 'Exported image'
      snippet :Details, from: 'Presentation.Details'
      file_manager :File, mode: :both
      image_uploader :UploadImage, caption: 'Image upload'
      image_viewer :Preview, entity: 'Presentation.Document', alternative_text: 'Stored image',
                             default_image: 'Presentation.Images.Pixel', show_as_thumbnail: true
      native_widget :Tags, type: 'Forms$InputReferenceSetSelector', deep_structure: {
        'SelectableXPathConstraint' => "[Presentation.Tag_Category/Presentation.Category[Name = 'Visible']]",
        'AttributeRef' => {
          '$Type' => 'DomainModels$AttributeRef',
          'Attribute' => 'Presentation.Tag.Name',
          'EntityRef' => { '$Type' => 'DomainModels$IndirectEntityRef', 'Steps' => [2, {
            'Association' => 'Presentation.Document_Tags', 'DestinationEntity' => 'Presentation.Tag'
          }] }
        }
      }
      native_widget :Scroll, type: 'Forms$ScrollContainer', deep_structure: {
        'LayoutMode' => 'Sidebar',
        'Left' => { '$Type' => 'Forms$ScrollContainerRegion', 'SizeMode' => 'Pixels', 'Size' => 240,
                    'ToggleMode' => 'ShrinkContentInitiallyClosed', 'Widgets' => [2, {
                      '$Type' => 'Forms$TextBox', 'Name' => 'AdvancedRegionName',
                      'AttributeRef' => { '$Type' => 'DomainModels$AttributeRef',
                                          'Attribute' => 'Presentation.Document.Name' }
                    }] },
        'CenterRegion' => { '$Type' => 'Forms$ScrollContainerRegion', 'Widgets' => [2, {
          '$Type' => 'Forms$SidebarToggleButton', 'Name' => 'ToggleRegion',
          'CaptionTemplate' => { '$Type' => 'Forms$ClientTemplate',
                                 'Template' => { 'Items' => [2,
                                                             { 'LanguageCode' => 'en_US',
                                                               'Text' => 'Toggle sidebar' }] } }
        }, {
          '$Type' => 'Forms$TextBox', 'Name' => 'RegionName',
          'AttributeRef' => { '$Type' => 'DomainModels$AttributeRef', 'Attribute' => 'Presentation.Document.Name' }
        }] }
      }
      native_widget :Links, type: 'Forms$NavigationList', deep_structure: {
        'Items' => [2, {
          '$Type' => 'Forms$NavigationListItem',
          'Name' => 'OpenAlternate',
          'Action' => { '$Type' => 'Forms$FormAction',
                        'FormSettings' => { '$Type' => 'Forms$FormSettings', 'Form' => 'Presentation.Alternate' } },
          'Widgets' => [2, {
            '$Type' => 'Forms$Label', 'Name' => 'Alternate link',
            'Caption' => { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Alternate link' }] }
          }]
        }]
      }
    end
    page :Edit do
      title 'Client actions'
      data_source microflow: 'Presentation.Load'
      text_box :DraftName, attribute: 'Presentation.Document.Name', caption: 'Draft name'
      check_box :DraftApproved, attribute: 'Presentation.Document.Approved', caption: 'Approved'
      button(:SaveDraft, caption: 'Save draft') { on_click action: :save_changes, close_page: false }
      button(:CancelDraft, caption: 'Cancel draft') { on_click action: :cancel_changes, close_page: false }
      button(:CloseDraft, caption: 'Close draft') { on_click action: :close_page }
      layout_grid :ResponsiveGrid do
        row horizontal_alignment: :center do
          column(desktop: 6, tablet: 8, phone: 12) { text 'First responsive column' }
          column(desktop: 6, tablet: 4, phone: 12) { text 'Second responsive column' }
        end
      end
    end
    page(:Alternate) { text 'Alternate page content' }
  end
  navigation { profile :Responsive, home_page: 'Presentation.Home' }
end
# rubocop:enable Metrics/BlockLength
