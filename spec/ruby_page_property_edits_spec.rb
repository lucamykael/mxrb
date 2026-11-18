# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Exported Ruby page property edits' do # rubocop:disable Metrics/BlockLength
  def named(value, name)
    return value if value.is_a?(Hash) && value['Name'] == name

    children = value.is_a?(Hash) ? value.values : Array(value)
    children.filter_map { named(_1, name) if _1.is_a?(Hash) || _1.is_a?(Array) }.first
  end

  def change_native(path, widget, field, value)
    Mxrb.open(path, readonly: false) do |project|
      page = project.modules.find { _1.name == 'App' }.pages.first
      raw = page.raw_document
      named(raw, widget)[field] = value
      project.mpr.update_unit(page.id, raw)
    end
  end

  def fixture(path) # rubocop:disable Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) do
        entity(:Item) { string :Name }
        page(:Home) do
          data_view :Details, from: context(entity: 'App.Item') do
            body do
              text_box :Name, attribute: 'App.Item.Name', caption: 'Name'
              text :Heading, caption: 'Details'
              button :Save, caption: 'Save'
            end
          end
        end
      end
    end
  end

  # Expectations come from native storage fields, not the implementation's mapping.
  [
    ['Save', 'ButtonStyle', 'Primary', 'Success', 'button_style: "primary"', 'button_style: "success"'],
    ['Save', 'RenderType', 'Link', 'Button', 'render_type: "link"', 'render_type: "button"'],
    ['Save', 'RenderType', 'Button', 'Link', 'caption: "Save"', 'caption: "Save", render_type: "link"'],
    ['Heading', 'RenderMode', 'H1', 'H2', 'render_mode: "h1"', 'render_mode: "h2"'],
    ['Heading', 'RenderMode', 'Text', 'H2', 'caption: "Details"', 'caption: "Details", render_mode: "h2"'],
    ['Name', 'Editable', 'Never', 'Always', 'editable: "never"', 'editable: "always"'],
    ['Name', 'ReadOnlyStyle', 'Text', 'Control', 'read_only_style: "text"', 'read_only_style: "control"'],
    ['Name', 'MaxLengthCode', 19, 31, 'max_length: 19', 'max_length: 31'],
    ['Name', 'IsPasswordBox', false, true, 'password: false', 'password: true'],
    ['Name', 'AriaRequired', false, true, 'aria_required: false', 'aria_required: true'],
    ['Name', 'TabIndex', 3, 4, 'tab_index: 3', 'tab_index: 4'],
    ['Details', 'LabelWidth', 4, 6, 'label_width: 4', 'label_width: 6'],
    ['Details', 'ShowFooter', false, true, 'show_footer: false', 'show_footer: true'],
    ['Details', 'Editability', 'Never', 'Always', 'editable: "never"', 'editable: "always"'],
    ['Details', 'ReadOnlyStyle', 'Control', 'Text', 'read_only_style: "control"', 'read_only_style: "text"']
  ].each do |edit|
    widget, field, before, after, from, to = edit
    it "applies #{widget}.#{field} and preserves every other native unit through re-export" do
      Dir.mktmpdir do |root|
        source = File.join(root, 'source', 'Shop.mpr')
        fixture(source)
        change_native(source, widget, field, before)
        FileUtils.cp_r(File.dirname(source), File.join(root, 'expected'))
        expected = File.join(root, 'expected', 'Shop.mpr')
        change_native(expected, widget, field, after)
        app = File.join(root, 'ruby')
        Mxrb::Exporter.new(source, app, mode: :ruby).export!
        manifest = Mxrb::RubyApp::Manifest.load(app)
        FileUtils.rm_rf(File.dirname(manifest.absolute_path('runtime_mpr')))
        path = File.join(app, 'app/pages/app/home_page.rb')
        code = File.read(path)
        expect(code.scan(from).size).to eq(1)
        File.write(path, code.sub(from, to))
        built = Mxrb::RubyApp.compile(app, File.join(root, 'built', 'Shop.mpr'))
        expect(Mxrb.compare(expected, built)).to be_identical
        again = File.join(root, 'again')
        Mxrb::Exporter.new(built, again, mode: :ruby).export!
        rebuilt = Mxrb::RubyApp.compile(again, File.join(root, 'rebuilt', 'Shop.mpr'))
        expect(Mxrb.compare(built, rebuilt)).to be_identical
      end
    end
  end

  it 'refuses presentation contract changes instead of silently discarding them' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source', 'Shop.mpr')
      fixture(source)
      app = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, app, mode: :ruby).export!
      path = File.join(app, 'app/pages/app/home_page.rb')
      code = File.read(path)
      expect(code).to include('autofocus: "Off"')
      File.write(path, code.sub('autofocus: "Off"', 'autofocus: "All"'))
      expect { Mxrb::RubyApp.compile(app, File.join(root, 'built', 'Shop.mpr')) }
        .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /presentation.*autofocus/)
    end
  end

  it 'refuses an excluded declaration that has no native synchronization instead of ignoring it' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source', 'Shop.mpr')
      fixture(source)
      app = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, app, mode: :ruby).export!
      path = File.join(app, 'app/pages/app/home_page.rb')
      code = File.read(path)
      File.write(path, code.sub('mendix_name "App.Home"', "mendix_name \"App.Home\"\n    excluded"))
      expect { Mxrb::RubyApp.compile(app, File.join(root, 'built', 'Shop.mpr')) }
        .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /excluded changed/)
    end
  end

  it 'refuses invalid values, incompatible native widgets and changed baselines without modifying them' do
    properties = Mxrb::RubyApp::PageEditProperties
    owner = { '$Type' => 'Forms$TextBox', 'Name' => 'Input', 'Editable' => 'Never',
              'IsPasswordBox' => false, 'MaxLengthCode' => 19 }
    before = Marshal.load(Marshal.dump(owner))
    [
      %w[editable never invalid], ['editable', 'never', nil],
      ['password', false, 'true'], ['max_length', 19, '20'],
      %w[editable always never], ['tab_index', 0, 1]
    ].each do |key, old, value|
      expect { properties.apply(owner, 'text_box', key, old, value) }.to raise_error(ArgumentError)
      expect(owner).to eq(before)
    end
    expect { properties.apply(owner, 'button', 'button_style', 'default', 'primary') }
      .to raise_error(ArgumentError, /no supported native field/)
    raw = { 'Widgets' => [2, owner] }
    expect do
      Mxrb::RubyApp::PageEdits::Document.new('App.Home', raw).apply([[:property, 'Input', 'text_box',
                                                                      'editable', 'never', 'invalid']])
    end
      .to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App.Home: Input.editable/)
  end

  it 'edits the boolean DataView field in Mendix 7/9 without introducing the Mendix 11 enum' do
    owner = { '$Type' => 'Forms$DataView', 'Editable' => true, 'Name' => 'Details', 'Widget' => nil }
    properties = Mxrb::RubyApp::PageEditProperties
    properties.apply(owner, 'data_view', 'editable', 'always', 'never')
    expect(owner).to eq('$Type' => 'Forms$DataView', 'Editable' => false, 'Name' => 'Details', 'Widget' => nil)
    expect { properties.apply(owner, 'data_view', 'editable', 'never', 'conditional') }
      .to raise_error(ArgumentError, /invalid value/)
    expect { properties.apply({ '$Type' => 'Forms$DataView' }, 'data_view', 'editable', 'always', 'never') }
      .to raise_error(ArgumentError, /no supported native field/)
  end
end
