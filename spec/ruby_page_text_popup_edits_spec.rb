# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Ruby input text and popup edits' do # rubocop:disable Metrics/BlockLength
  def named(value, name)
    return value if value.is_a?(Hash) && value['Name'] == name

    children = value.is_a?(Hash) ? value.values : Array(value)
    children.filter_map { named(_1, name) if _1.is_a?(Hash) || _1.is_a?(Array) }.first
  end

  def fixture(path, popup: false) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) do
        entity(:Item) { string :Name }
        page(:Home) do
          if popup
            popup! mode: :modal, width: 800, height: 0
          else
            data_view :Details, from: context(entity: 'App.Item') do
              body do
                text_box :Name, attribute: 'App.Item.Name', caption: ''
                text :Heading, caption: 'Details'
                button :Save, caption: 'Save'
              end
            end
          end
        end
      end
    end
    return if popup

    change(path) do |raw|
      input_text(raw).fetch('Items')[1]['Text'] = 'Enter name'
      named(raw, 'Name')['LabelTemplate'] = nil
      named(raw, 'Name')['ScreenReaderLabel'] = empty_template
    end
  end

  def input_text(raw) = named(raw, 'Name').fetch('PlaceholderTemplate').fetch('Template')

  def empty_template
    { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ClientTemplate', 'Parameters' => [2],
      'Template' => native_text('').merge('Items' => [3]),
      'Fallback' => native_text('').merge('Items' => [3]) }
  end

  def change(path)
    Mxrb.open(path, readonly: false) do |project|
      page = project.modules.find { _1.name == 'App' }.pages.first
      raw = page.raw_document
      yield raw
      project.mpr.update_unit(page.id, raw)
    end
  end

  [
    ['placeholder', 'placeholder: "Enter name"', 'placeholder: "Enter full name"',
     ->(raw) { input_text(raw).fetch('Items')[1]['Text'] = 'Enter full name' }],
    ['empty accessibility label', 'aria_label: ""', 'aria_label: "Accessible name"',
     lambda { |raw|
       named(raw, 'Name').fetch('ScreenReaderLabel').fetch('Template')['Items'] = [3, {
         '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation',
         'LanguageCode' => 'en_US', 'Text' => 'Accessible name'
       }]
     }],
    ['popup width', 'width: 800', 'width: 1000', ->(raw) { raw['PopupWidth'] = 1000 }],
    ['popup height', 'height: 0', 'height: 600', ->(raw) { raw['PopupHeight'] = 600 }],
    ['popup resizing', 'resizable: true', 'resizable: false', ->(raw) { raw['PopupResizable'] = false }]
  ].each do |label, from, to, native_edit|
    it "applies #{label} through the public Ruby declaration without unrelated changes" do
      Dir.mktmpdir do |root|
        source = File.join(root, 'source', 'Shop.mpr')
        fixture(source, popup: label.start_with?('popup'))
        FileUtils.cp_r(File.dirname(source), File.join(root, 'expected'))
        expected = File.join(root, 'expected/Shop.mpr')
        change(expected) { |raw| instance_exec(raw, &native_edit) }
        app = File.join(root, 'ruby')
        Mxrb::Exporter.new(source, app, mode: :ruby).export!
        manifest = Mxrb::RubyApp::Manifest.load(app)
        FileUtils.rm_rf(File.dirname(manifest.absolute_path('runtime_mpr')))
        page = File.join(app, 'app/pages/app/home_page.rb')
        code = File.read(page)
        expect(code.scan(from).size).to eq(1)
        File.write(page, code.sub(from, to))
        built = Mxrb::RubyApp.compile(app, File.join(root, 'built/Shop.mpr'))
        expect(Mxrb.compare(expected, built)).to be_identical
        again = File.join(root, 'again')
        Mxrb::Exporter.new(built, again, mode: :ruby).export!
        rebuilt = Mxrb::RubyApp.compile(again, File.join(root, 'rebuilt/Shop.mpr'))
        expect(Mxrb.compare(built, rebuilt)).to be_identical
      end
    end
  end

  def native_text(value)
    { '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text', 'Items' => [3, {
      '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation', 'LanguageCode' => 'en_US', 'Text' => value
    }] }
  end

  it 'preserves the browser witness before editing its public Ruby declarations' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source', 'Contracts.mpr')
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = source
      load File.expand_path('fixtures/ruby_text_popup_edits/project.rb', __dir__)
      app = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, app, mode: :ruby).export!
      manifest = Mxrb::RubyApp::Manifest.load(app)
      FileUtils.rm_rf(File.dirname(manifest.absolute_path('runtime_mpr')))
      built = Mxrb::RubyApp.compile(app, File.join(root, 'built/Contracts.mpr'))
      expect(Mxrb.compare(source, built)).to be_identical
    ensure
      previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
    end
  end

  def text_owner(value = 'Same')
    { '$Type' => 'Forms$TextBox', 'Name' => 'Input', 'PlaceholderTemplate' => {
      '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ClientTemplate', 'Template' => native_text(value),
      'Fallback' => native_text('Fallback'), 'Parameters' => [2]
    } }
  end

  it 'preserves other translations, their IDs, the fallback and template parameters' do
    owner = text_owner('Hello {1}')
    template = owner.fetch('PlaceholderTemplate')
    template['Parameters'] << { '$ID' => SecureRandom.uuid, 'Expression' => '$currentObject/Name' }
    translated = native_text('Hello {1}').fetch('Items')[1].merge('LanguageCode' => 'pt_BR')
    template.fetch('Template').fetch('Items') << translated
    expected = Marshal.load(Marshal.dump(owner))
    expected.dig('PlaceholderTemplate', 'Template', 'Items')[1]['Text'] = 'Welcome {1}'

    Mxrb::RubyApp::PageEditTexts.apply(owner, 'text_box', 'placeholder', 'Hello {1}', 'Welcome {1}', language: nil)
    expect(owner).to eq(expected)
  end

  it 'preserves legacy plain text storage instead of introducing a client template' do
    owner = { '$Type' => 'Forms$TextArea', 'Placeholder' => native_text('Before') }
    expected = Marshal.load(Marshal.dump(owner))
    expected.fetch('Placeholder').fetch('Items')[1]['Text'] = 'After'
    Mxrb::RubyApp::PageEditTexts.apply(owner, 'text_area', 'placeholder', 'Before', 'After', language: nil)
    expect(owner).to eq(expected)
  end

  it 'creates one translation in the project default language when a text has no translations' do
    owner = text_owner
    template = owner.fetch('PlaceholderTemplate')
    template.fetch('Template')['Items'] = [3]
    text_id = template.fetch('Template').fetch('$ID')
    fallback = Marshal.load(Marshal.dump(template.fetch('Fallback')))
    Mxrb::RubyApp::PageEditTexts.apply(owner, 'number_input', 'placeholder', '', 'Valor', language: 'pt_BR')
    expect(template.fetch('Template').fetch('$ID')).to eq(text_id)
    expect(template.fetch('Template').fetch('Items')).to match([3, include(
      '$ID' => match(/\A[0-9a-f-]{36}\z/), '$Type' => 'Texts$Translation',
      'LanguageCode' => 'pt_BR', 'Text' => 'Valor'
    )])
    expect(template.fetch('Fallback')).to eq(fallback)
  end

  it 'rejects invalid text edits and malformed storage without mutating the native document' do
    operations = [
      [nil, 'After', nil, nil], ['Same', nil, nil, nil], ['Old', 'After', nil, nil],
      ['Same', 'After {1}', nil, nil], ['Same', 'After', nil, ->(o) { o['$Type'] = 'Forms$DynamicText' }],
      ['Same', 'After', nil, ->(o) { o.delete('PlaceholderTemplate') }],
      ['Same', 'After', nil, ->(o) { o['PlaceholderTemplate'] = nil }],
      ['Same', 'After', nil, ->(o) { o['PlaceholderTemplate'] = { '$Type' => 'Unknown' } }],
      ['Same', 'After', nil, ->(o) { o.dig('PlaceholderTemplate', 'Template').delete('Items') }],
      ['Same', 'After', nil, ->(o) { o.dig('PlaceholderTemplate', 'Template')['Items'] = [] }],
      ['Same', 'After', nil, ->(o) { o.dig('PlaceholderTemplate', 'Template')['Items'] = [3, 'bad'] }],
      ['Same', 'After', nil, ->(o) { o.dig('PlaceholderTemplate', 'Template', 'Items')[1]['$Type'] = 'Unknown' }],
      ['Same', 'After', 'en_US', ->(o) { o.dig('PlaceholderTemplate', 'Template')['Items'] = [3] }],
      ['', 'After', nil, ->(o) { o.dig('PlaceholderTemplate', 'Template')['Items'] = [3] }]
    ]
    operations.each do |before, after, language, corrupt|
      owner = text_owner
      corrupt&.call(owner)
      original = Marshal.load(Marshal.dump(owner))
      expect { Mxrb::RubyApp::PageEditTexts.apply(owner, 'text_box', 'placeholder', before, after, language:) }
        .to raise_error(ArgumentError)
      expect(owner).to eq(original)
    end
  end

  it 'rejects incompatible widget types and reports text errors with their page and widget names' do
    expect { Mxrb::RubyApp::PageEditTexts.apply(text_owner, 'unknown', 'placeholder', 'Same', 'After', language: nil) }
      .to raise_error(ArgumentError)
    document = Mxrb::RubyApp::PageEdits::Document.new('App.Home', { 'Widgets' => [2, text_owner] })
    expect do
      document.apply([[:text_property, 'Input', 'text_box', 'placeholder', 'Same', nil]])
    end.to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App.Home: Input.placeholder/)
  end

  it 'keeps unsupported page contracts guarded and refuses invalid popup dimensions without mutation' do
    contracts = Mxrb::RubyApp::PageEditContracts
    before = { 'popup' => { 'mode' => 'modal', 'width' => 800, 'height' => 0, 'resizable' => true } }
    [
      {}, { 'popup' => nil }, { 'popup' => before.fetch('popup').merge('mode' => 'popup') },
      before.merge('parameters' => [{ 'name' => 'Changed' }]),
      { 'popup' => before.fetch('popup').except('width') }
    ].each { |after| expect { contracts.changes(before, after) }.to raise_error(ArgumentError) }
    expect { contracts.changes({}, before) }.to raise_error(ArgumentError)
    expect { contracts.changes({ 'popup' => before.fetch('popup').except('width') }, before) }
      .to raise_error(ArgumentError)
    owner = { '$Type' => 'Forms$Page', 'PopupWidth' => 800, 'PopupResizable' => true }
    original = owner.dup
    [-1, 2_147_483_648, 1.5, '800', nil].each do |value|
      expect { contracts.apply(owner, 'width', 800, value) }.to raise_error(ArgumentError)
      expect(owner).to eq(original)
    end
    expect { contracts.apply(owner, 'resizable', true, 'false') }.to raise_error(ArgumentError)
    expect { contracts.apply(owner, 'width', 600, 900) }.to raise_error(ArgumentError)
    expect { contracts.apply(owner, 'height', 0, 600) }.to raise_error(ArgumentError)
    expect { contracts.apply(owner.merge('$Type' => 'Forms$Layout'), 'width', 800, 900) }.to raise_error(ArgumentError)
    expect do
      Mxrb::RubyApp::PageEdits::Document.new('App.Home', owner).apply([[:popup, 'width', 800, -1]])
    end.to raise_error(Mxrb::RubyApp::PageEdits::UnsupportedEdit, /App.Home: invalid popup width/)
    expect(owner).to eq(original)
  end
end
