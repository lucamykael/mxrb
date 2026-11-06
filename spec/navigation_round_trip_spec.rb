# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'navigation through a project.rb round trip' do
  def writer(version)
    Mxrb::Writer.allocate.tap { _1.instance_variable_set(:@definition, { version: }) }
  end

  def menu_item(version, previous: nil, **item)
    writer(version).send(:navigation_menu_item_doc, { caption: { 'en_US' => 'Item' }, **item }, previous:)
  end

  def stored_item(fields)
    profile = Mxrb::Model::NavigationProfile.new(
      'Menu' => { 'Items' => [2, { '$Type' => 'Menus$MenuItem', **fields }] }
    )
    profile.menu_items.first
  end

  def text(value = 'Title')
    { '$Type' => 'Texts$Text', 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => value }] }
  end

  describe 'reading a stored menu item' do
    it 'names a popup and a disabled button' do
      item = stored_item('Action' => { 'DisabledDuringExecution' => true,
                                       'FormSettings' => { 'Form' => 'App.Home', 'Location' => 'Popup' } })

      expect(item).to include(page: 'App.Home', location: 'Popup', disabled_during_execution: true)
    end

    it 'distinguishes an empty title from no title' do
      empty = { '$Type' => 'Microflows$TextTemplate', 'Text' => { '$Type' => 'Texts$Text', 'Items' => [2] } }

      expect(stored_item('Action' => { 'FormSettings' => { 'Form' => 'A.B', 'TitleOverride' => empty } }))
        .to include(title: {})
      expect(stored_item('Action' => { 'FormSettings' => { 'Form' => 'A.B', 'TitleOverride' => nil } }))
        .not_to include(:title)
    end

    it 'reads a title stored as a template, as a text or under its legacy name' do
      template = { 'Text' => text }

      [{ 'TitleOverride' => template }, { 'TitleOverride' => text }, { 'FormTitle' => text }].each do |settings|
        expect(stored_item('Action' => { 'FormSettings' => settings }))
          .to include(title: { 'en_US' => 'Title' })
      end
    end

    it 'leaves the default settings of a microflow out' do
      item = stored_item('Action' => { 'MicroflowSettings' => {
                           'Microflow' => 'App.Run', 'FormValidations' => 'All', 'ProgressBar' => 'None',
                           'Asynchronous' => false, 'UseAllPages' => false,
                           'ConfirmationInfo' => nil, 'ProgressMessage' => nil
                         } })

      expect(item.keys).to contain_exactly(:caption, :microflow, :items)
    end

    it 'names the settings of a microflow that differ from the default' do
      item = stored_item('Action' => { 'MicroflowSettings' => {
                           'Microflow' => 'App.Run', 'FormValidations' => 'None', 'ProgressBar' => 'Blocking',
                           'Asynchronous' => true, 'UseAllPages' => true, 'ProgressMessage' => text('Wait'),
                           'ConfirmationInfo' => { 'Question' => text('Sure?'), 'ProceedButtonCaption' => text('Yes'),
                                                   'CancelButtonCaption' => text('No') }
                         } })

      expect(item).to include(
        form_validations: 'None', progress_bar: 'Blocking', asynchronous: true, use_all_pages: true,
        progress_message: { 'en_US' => 'Wait' },
        confirmation: { question: { 'en_US' => 'Sure?' }, proceed: { 'en_US' => 'Yes' }, cancel: { 'en_US' => 'No' } }
      )
    end

    it 'reads every kind of icon' do
      expect(stored_item('Icon' => { '$Type' => 'Forms$GlyphIcon', 'Code' => 57_377 })[:icon]).to eq(57_377)
      expect(stored_item('Icon' => { '$Type' => 'Forms$IconCollectionIcon', 'Image' => 'A.B.c' })[:icon])
        .to eq(collection: 'A.B.c')
      expect(stored_item('Icon' => { '$Type' => 'Forms$ImageIcon', 'Image' => 'A.B.c' })[:icon]).to eq(image: 'A.B.c')
    end
  end

  describe 'writing a menu item' do
    it 'stores a popup and a disabled button' do
      action = menu_item('7.5.0', page: 'App.Home', location: 'Popup', disabled_during_execution: true).fetch('Action')

      expect(action).to include('DisabledDuringExecution' => true)
      expect(action.fetch('FormSettings')).to include('Form' => 'App.Home', 'Location' => 'Popup')
    end

    it 'stores no location unless one is declared' do
      expect(menu_item('11.12.1', page: 'App.Home').dig('Action', 'FormSettings')).not_to include('Location')
    end

    it 'stores a title as each version expects it' do
      modern = menu_item('11.12.1', page: 'A.B', title: {}).dig('Action', 'FormSettings', 'TitleOverride')
      middle = menu_item('9.6.1', page: 'A.B', title: { 'en_US' => 'T' }).dig('Action', 'FormSettings')
      legacy = menu_item('7.5.0', page: 'A.B', title: { 'en_US' => 'T' }).dig('Action', 'FormSettings')

      expect(modern).to include('$Type' => 'Microflows$TextTemplate')
      expect(middle.dig('TitleOverride', '$Type')).to eq('Texts$Text')
      expect(legacy.dig('FormTitle', '$Type')).to eq('Texts$Text')
      expect(legacy).not_to include('TitleOverride')
    end

    it 'keeps what a declaration leaves out of the stored item' do
      prior = { 'DisabledDuringExecution' => true,
                'FormSettings' => { 'Location' => 'Popup', 'TitleOverride' => { 'Kept' => true } } }
      action = menu_item('11.12.1', page: 'A.B', previous: { 'Action' => prior }).fetch('Action')

      expect(action).to include('DisabledDuringExecution' => true)
      expect(action.fetch('FormSettings')).to include('Location' => 'Popup', 'TitleOverride' => { 'Kept' => true })
    end

    it 'keeps the stored fields of an item that Ruby does not describe' do
      item = menu_item('5.21.4', previous: { 'Documentation' => '', 'Icon' => { 'Code' => 1 } })

      expect(item).to include('Documentation' => '', 'Icon' => nil)
    end

    it 'lets a declaration replace the stored values' do
      prior = { 'DisabledDuringExecution' => true, 'FormSettings' => { 'Location' => 'Popup' } }
      action = menu_item('7.5.0', page: 'A.B', location: 'Content', disabled_during_execution: false,
                                  previous: { 'Action' => prior }).fetch('Action')

      expect(action).to include('DisabledDuringExecution' => false)
      expect(action.fetch('FormSettings')).to include('Location' => 'Content')
    end

    it 'stores the defaults of a microflow' do
      action = menu_item('7.5.0', microflow: 'App.Run').fetch('Action')

      expect(action.fetch('MicroflowSettings')).to include(
        'Microflow' => 'App.Run', 'FormValidations' => 'All', 'ProgressBar' => 'None', 'Asynchronous' => false
      )
      expect(action).not_to include('DisabledDuringExecution')
    end

    it 'stores the declared settings of a microflow' do
      action = menu_item(
        '7.5.0', microflow: 'App.Run', form_validations: 'None', progress_bar: 'Blocking', asynchronous: true,
                 use_all_pages: true, disabled_during_execution: true, progress_message: { 'en_US' => 'Wait' },
                 confirmation: { question: { 'en_US' => 'Sure?' }, proceed: { 'en_US' => 'Yes' },
                                 cancel: { 'en_US' => 'No' } }
      ).fetch('Action')
      settings = action.fetch('MicroflowSettings')

      expect(action).to include('DisabledDuringExecution' => true)
      expect(settings).to include('FormValidations' => 'None', 'ProgressBar' => 'Blocking',
                                  'Asynchronous' => true, 'UseAllPages' => true)
      expect(settings.dig('ProgressMessage', '$Type')).to eq('Texts$Text')
      expect(settings.dig('ConfirmationInfo', '$Type')).to eq('Forms$ConfirmationInfo')
    end

    it 'keeps the stored settings of a microflow' do
      prior = { 'MicroflowSettings' => { 'ProgressBar' => 'Blocking', 'OutputMappings' => [3] } }
      settings = menu_item('7.5.0', microflow: 'App.Run', previous: { 'Action' => prior })
                 .dig('Action', 'MicroflowSettings')

      expect(settings).to include('ProgressBar' => 'Blocking', 'OutputMappings' => [3], 'Microflow' => 'App.Run')
    end

    it 'stores an image icon' do
      expect(menu_item('5.21.4', icon: { image: 'A.Images.c' }).fetch('Icon'))
        .to include('$Type' => 'Forms$ImageIcon', 'Image' => 'A.Images.c')
    end

    it 'keeps the identity of a stored image icon' do
      item = menu_item('5.21.4', icon: { image: 'A.Images.c' }, previous: { 'Icon' => { '$ID' => 'kept' } })

      expect(item.fetch('Icon')).to include('$ID' => 'kept')
    end
  end

  describe 'the application title of a profile' do
    def profile(previous)
      writer('7.5.0').send(:navigation_profile_doc, { name: 'Responsive', app_title: { 'en_US' => 'New' } }, previous:)
    end

    it 'stays under the name the stored profile uses' do
      document = profile('ApplicationTitle' => 'Old')

      expect(document).to include('ApplicationTitle' => 'New')
      expect(document).not_to include('AppTitle')
    end

    it 'is a translatable text otherwise' do
      expect(profile({}).dig('AppTitle', '$Type')).to eq('Texts$Text')
    end
  end

  it 'rejects an option a menu item does not have' do
    expect { Mxrb::Dsl::NavigationMenuItemBuilder.new('Home', popup: true) }
      .to raise_error(ArgumentError, /unknown navigation item option :popup/)
  end

  it 'declares the options on nested items too' do
    builder = Mxrb::Dsl::NavigationMenuItemBuilder.new('Parent')
    builder.item('Child', page: 'App.Home', location: 'Popup')

    expect(builder.to_h.fetch(:items).first).to include(location: 'Popup', page: 'App.Home')
  end

  context 'with a whole project' do
    def define(name, dir, location: nil)
      path = File.join(dir, name, 'app.mpr')
      FileUtils.mkdir_p(File.dirname(path))
      define_project(path, location ? { location: } : {})
    end

    def define_project(path, options)
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:App) { page(:Home) { text 'message', caption: 'Text' } }
        navigation do
          profile :Responsive, home_page: 'App.Home' do
            item 'Home', page: 'App.Home', title: {}, disabled_during_execution: true,
                         icon: { collection: 'App.Icons.home' }, **options
          end
        end
      end && path
    end

    it 'exports the options of a menu item to Ruby and reads them back' do
      Dir.mktmpdir do |dir|
        source = define('source', dir)
        exported = File.join(dir, 'ruby')
        Mxrb::Exporter.new(source, exported, mode: :mendix).export!

        expect(File.read(File.join(exported, 'app', 'navigation', 'navigation.rb')))
          .to include('title: {}', 'disabled_during_execution: true', 'icon: {collection: "App.Icons.home"}')
      end
    end

    it 'rebuilds the options of a menu item without a difference' do
      Dir.mktmpdir do |dir|
        source = define('source', dir, location: 'Popup')
        exported = File.join(dir, 'ruby')
        rebuilt = File.join(dir, 'rebuilt', 'app.mpr')
        FileUtils.mkdir_p(File.dirname(rebuilt))
        Mxrb::Exporter.new(source, exported, mode: :mendix).export!
        begin
          ENV['MXRB_OUTPUT_PATH'] = rebuilt
          load File.join(exported, 'project.rb')
        ensure
          ENV.delete('MXRB_OUTPUT_PATH')
        end

        expect(Mxrb.compare(source, rebuilt).differences).to be_empty
      end
    end

    it 'reports a menu item changed in the stored navigation document' do
      Dir.mktmpdir do |dir|
        left = define('left', dir)
        right = define('right', dir, location: 'Popup')

        expect(Mxrb.compare(left, right).differences.join("\n")).to match(/navigation\.document\..*Location/)
        expect(Mxrb.compare(left, left).differences).to be_empty
      end
    end
  end

  describe 'a sort item stored by a generator' do
    let(:codec) { Mxrb::Forms::MprCodec.new }

    def sort_item(fields)
      { '$ID' => 'ignored', '$Type' => 'Forms$GridSortItem', 'AttributeRef' => nil, **fields }
    end

    it 'does not take its direction from SortDirection' do
      node = codec.decode(sort_item('SortDirection' => 'Descending'))

      expect(codec.encode(node)).not_to include('SortOrder' => 'Descending')
    end

    it 'keeps the direction of SortOrder' do
      expect(codec.encode(codec.decode(sort_item('SortOrder' => 'Descending')))).to include('SortOrder' => 'Descending')
    end

    it 'has no other name for the field' do
      property = Mxrb::Forms::Catalog.for('11.12.1').fetch_type('GridSortItem').fetch_property('sortDirection')

      expect(Mxrb::Forms::StorageNaming.candidates(property)).to eq(%w[SortOrder])
    end
  end
end
# rubocop:enable Metrics/BlockLength
