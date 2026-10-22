# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength, Metrics/AbcSize
RSpec.describe 'native layouts in the Ruby application' do
  def define_native_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) do
        module_role :User
        layout_document(:Shell) do
          content(:native_layout_content) do
            layout_type 'Popup'
            show_bottom_bar true
            sidebar true
            widgets(:placeholder) { name 'Main' }
            right_header_placeholder { name 'Header' }
            sidebar_widgets(:placeholder) { name 'Menu' }
          end
        end
        layout_document(:Plain) do
          content(:native_layout_content) { widgets(:placeholder) { name 'Main' } }
        end
        page(:Home) do
          layout 'App.Shell'
          allowed_roles :User
          text 'Welcome'
        end
        page(:Tasks) { allowed_roles :User }
      end
      security do
        security_level :CheckEverything
        user_role :User, module_roles: ['App.User']
      end
      navigation do
        profile :Responsive, home_page: 'App.Home'
        profile :NativePhone, kind: 'Native', home_page: 'App.Home' do
          bottom_bar_item 'Home', page: 'App.Home', icon: { collection: 'Atlas_Core.Atlas_Filled.home' }
          bottom_bar_item 'Tasks', page: 'App.Tasks'
        end
      end
    end
  end

  it 'projects a native layout with its header, sidebar and bottom bar and composes pages through it' do
    Dir.mktmpdir do |root|
      path = File.join(root, 'App.mpr')
      exported = File.join(root, 'ruby')
      define_native_project(path)
      Mxrb::Exporter.new(path, exported, mode: :ruby).export!

      presentation = File.read(File.join(exported, 'app', 'presentation', 'app.rb'))
      expect(presentation).to include(
        'native_layout "NativeLayout", layout_type: "popup", show_bottom_bar: true, sidebar: true do',
        "    region \"content\" do\n      placeholder \"Main\", parameter: \"Main\"\n    end",
        "    region \"header\" do\n      placeholder \"Header\", parameter: \"Header\"\n    end",
        "    region \"sidebar\" do\n      placeholder \"Menu\", parameter: \"Menu\"\n    end",
        'native_layout "NativeLayout", layout_type: "default", show_bottom_bar: false, sidebar: false do'
      )
      expect(presentation.scan('region "sidebar"').size).to eq(1)
      expect(File.read(File.join(exported, 'frontend', 'src', 'generated', 'types.ts')))
        .to include('"native_layout" |', 'bottom_bar?: NativeBottomBarItem[];', 'show_bottom_bar?: boolean;')

      application = Mxrb::RubyApp::Application.new(exported)
      widgets = application.page('App.Home').fetch(:widgets)
      expect(widgets.size).to eq(1)
      expect(widgets.first).to include(
        'type' => 'native_layout',
        'options' => { 'layout_type' => 'popup', 'show_bottom_bar' => true, 'sidebar' => true }
      )
      expect(widgets.first.fetch('regions')).to include('header' => [], 'sidebar' => [])
      expect(widgets.first.dig('regions', 'content').map { _1.slice('type', 'name') })
        .to eq([{ 'type' => 'text', 'name' => 'Welcome' }])
      native = application.schema.fetch(:navigation).fetch('profiles').find { _1['kind'] == 'Native' }
      expect(native.fetch('bottom_bar').map { _1['page'] }).to eq(%w[App.Home App.Tasks])
      expect(native.fetch('bottom_bar').first['icon']).to eq('collection' => 'Atlas_Core.Atlas_Filled.home')
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength, Metrics/AbcSize
