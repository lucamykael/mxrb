# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength
module MenuDocumentsFixture
  VERSION = '11.12.1'

  module_function

  def build(destination)
    Mxrb.define(destination) do
      mendix_version VERSION
      self.module :Menus do
        page :Home do
          title 'Menu certification'
          menu_bar :MainMenu, menu: 'Menus.Main'
        end
        page(:Alternate) { title 'Alternate' }
        microflow(:Ping) { show_message 'Ping' }
        menu :Main do
          documentation 'Primary menu'
          item 'Home', page: 'Menus.Home', icon: :home, translations: { pt_BR: 'Início' }
          item 'Run', microflow: 'Menus.Ping', icon: :settings
          item 'More' do
            item 'Alternate', page: 'Menus.Alternate'
          end
        end
        menu(:Obsolete) { item 'Old', page: 'Menus.Home' }
      end
      navigation do
        profile :Responsive, home_page: 'Menus.Home', app_title: 'Menu Documents'
      end
    end
  end
end

MenuDocumentsFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
