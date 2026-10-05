# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Contracts do
    microflow(:Notify) { show_message 'Background action completed' }
    page :Home do
      title 'Page contracts'
      button(:OpenEditor, caption: 'Open editor') do
        on_click page: 'Contracts.Editor', pass: { Caption: "'Passed caption'" }
      end
      button(:RunAsync, caption: 'Run asynchronously') do
        on_click microflow: 'Contracts.Notify', settings: client_settings(asynchronous: true)
      end
    end
    page :Editor do
      title 'Parameter editor'
      parameter :Caption, type: :string, required: false, default_value: "'Default caption'"
      variable :Draft, type: :string, default_value: '$Caption'
      popup! mode: :modal, width: 520, height: 320, resizable: true
      text_box :DraftInput, source_variable: page_variable('Contracts.Editor.Draft', kind: :local_variable),
                            caption: 'Draft caption'
      button(:OpenChild, caption: 'Open child') do
        on_click page: 'Contracts.Child', pass: { Caption: '$Draft' }
      end
      button(:CloseEditor, caption: 'Close editor') { on_click action: :close_page }
    end
    page :Child do
      title 'Nested editor'
      parameter :Caption, type: :string
      variable :Draft, type: :string, default_value: '$Caption'
      popup! mode: :modal, width: 400, resizable: false
      text_box :NestedDraft, source_variable: page_variable('Contracts.Child.Draft', kind: :local_variable),
                             caption: 'Nested draft'
      button(:CloseBoth, caption: 'Close both') do
        on_click action: :close_page, settings: client_settings(close_count: '2')
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Contracts.Home' }
end
# rubocop:enable Metrics/BlockLength
