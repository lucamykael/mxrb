# frozen_string_literal: true

require 'mxrb'
require 'base64'

# The font contains two original geometric glyphs. The unused JavaScript action
# certifies an editable callback signature; it does not implement deep linking.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
module EditableMenuActionsFixture
  module_function

  def build(destination)
    font = Base64.strict_encode64(File.binread(File.join(__dir__, 'icons.woff')))
    Mxrb.define(destination) do
      mendix_version '11.12.1'
      self.module :Menus do
        custom_icon_collection :Symbols, collection_class: 'fixture-icons', prefix: 'fixture',
                                         font: { data: font, subtype: :generic },
                                         icons: [{ name: 'Square', character_code: 0xe001 },
                                                 { name: 'Triangle', character_code: 0xe002 }]
        page :Home do
          title 'Editable menus and callbacks'
          page_title :Title
          menu_bar :MainMenu, menu: 'Menus.Main'
        end
        page :Alternate do
          title 'Alternate page'
          page_title :Title
        end
        menu :Main do
          item 'Square', page: 'Menus.Home', icon: { collection: 'Menus.Symbols.Square' }
          item 'Triangle', page: 'Menus.Alternate', icon: { collection: 'Menus.Symbols.Triangle' }
        end
        javascript_action(
          :CallbackContract, platform: 'Web', return_type: { kind: :void },
                             parameters: [{ name: 'Callback', required: false, type: { kind: :nanoflow } }]
        )
      end
      navigation do
        profile :Responsive, home_page: 'Menus.Home', app_title: 'Editable menus'
      end
    end
  end
end

EditableMenuActionsFixture.build(ENV.fetch('MXRB_OUTPUT_PATH')) if ENV['MXRB_OUTPUT_PATH']

# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
