# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

RSpec.describe Mxrb::RubyApp::DesignClasses do # rubocop:disable Metrics/BlockLength
  let(:definitions) do
    {
      'Widget' => [{ 'name' => 'Spacing', 'type' => 'Spacing',
                     'padding' => [{ 'name' => 'S', 'top' => { 'class' => 'spacing-inner-top' } }],
                     'margin' => [{ 'name' => 'M', 'left' => { 'class' => 'spacing-outer-left-medium' } }] }],
      'Button' => [{ 'name' => 'Size', 'type' => 'ToggleButtonGroup',
                     'options' => [{ 'name' => 'Large', 'class' => 'btn-lg' }] }],
      'DivContainer' => [{ 'name' => 'Disable row wrap', 'type' => 'Toggle', 'class' => 'flex-nowrap' }],
      'com.example.Badge' => [{ 'name' => 'Color', 'type' => 'Dropdown',
                                'options' => [{ 'name' => 'Brand', 'class' => 'badge-brand' }] }]
    }
  end

  def value(key, option = nil, type: option ? 'Forms$OptionDesignPropertyValue' : 'Forms$ToggleDesignPropertyValue')
    { 'Key' => key, 'Value' => { '$Type' => type, 'Option' => option }.compact }
  end

  def spacing(*sides)
    properties = sides.map { |key, option| value(key, option) }
    { 'Key' => 'Spacing',
      'Value' => { '$Type' => 'Forms$CompoundDesignPropertyValue', 'Properties' => [2, *properties] } }
  end

  it 'merges the web design properties of the theme modules' do
    Dir.mktmpdir do |root|
      %w[themesource/atlas_core/web theme/web themesource/broken/web].each { FileUtils.mkdir_p(File.join(root, _1)) }
      File.write(File.join(root, 'themesource/atlas_core/web/design-properties.json'),
                 JSON.generate('Button' => [{ 'name' => 'Size' }]))
      File.write(File.join(root, 'theme/web/design-properties.json'), JSON.generate('Button' => [{ 'name' => 'Mine' }]))
      File.write(File.join(root, 'themesource/broken/web/design-properties.json'), '{')
      expect(described_class.definitions(root).fetch('Button').map { _1['name'] }).to eq(%w[Size Mine])
    end
  end

  it 'resolves toggles, options and spacing as the Mendix client does' do
    button = [value('Size', 'Large'), spacing(%w[padding-top S], %w[margin-left M], %w[margin-top XL]),
              value('Unknown'), 'raw', value('Size', 'Huge')]
    expect(described_class.resolve('Button', button, definitions))
      .to eq('btn-lg spacing-inner-top spacing-outer-left-medium')
    expect(described_class.resolve('DivContainer', [value('Disable row wrap')], definitions)).to eq('flex-nowrap')
    other = { 'Key' => 'Size', 'Value' => { '$Type' => 'Forms$Other' } }
    expect(described_class.resolve('Button', [other], definitions)).to eq('')
  end

  it 'records the classes of the widgets of pages, snippets and layouts' do
    widgets = [
      { '$Type' => 'Forms$ActionButton', 'Name' => 'save',
        'Appearance' => { 'DesignProperties' => [3, value('Size', 'Large')] } },
      { '$Type' => 'Forms$DivContainer', 'Name' => 'bar',
        'Appearance' => { 'DesignProperties' => [3, value('Disable row wrap')] } },
      { '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'badge', 'Type' => { 'WidgetId' => 'com.example.Badge' },
        'Appearance' => { 'DesignProperties' => [3, value('Color', 'Brand')] } },
      { '$Type' => 'Forms$ActionButton', 'Name' => 'plain', 'Appearance' => { 'DesignProperties' => [3] } },
      { '$Type' => 'Forms$ActionButton', 'Name' => 'unknown',
        'Appearance' => { 'DesignProperties' => [3, value('Size', 'Huge')] } }
    ]
    page = double('page', name: 'Home', raw_document: { 'Widgets' => [2, *widgets.first(2)] })
    mod = double('module', name: 'App', pages: [page],
                           presentation_documents: [{ name: 'Layout', doc: { 'Widgets' => [2, *widgets.drop(2)] } },
                                                    { name: 'Empty', doc: {} }])
    project = double('project', modules: [mod])
    allow(described_class).to receive(:definitions).and_return(definitions)
    expect(described_class.collect(project, '/root')).to eq(
      'App.Home' => { 'save' => 'btn-lg', 'bar' => 'flex-nowrap' }, 'App.Layout' => { 'badge' => 'badge-brand' }
    )
    allow(described_class).to receive(:definitions).and_return({})
    expect(described_class.collect(project, '/root')).to eq({})
  end

  it 'adds the recorded classes to the widgets the application serves' do
    save = { 'type' => 'button', 'name' => 'save', 'options' => { 'caption' => 'Save' } }
    page = { 'widgets' => [save, { 'type' => 'container', 'name' => 'bar' }, { 'name' => 'not a widget' }] }
    expect(described_class.apply(page, 'save' => 'btn-lg', 'bar' => 'flex-nowrap')).to eq(
      'widgets' => [save.merge('options' => { 'caption' => 'Save', 'design_class' => 'btn-lg' }),
                    { 'type' => 'container', 'name' => 'bar', 'options' => { 'design_class' => 'flex-nowrap' } },
                    { 'name' => 'not a widget' }]
    )
    expect(described_class.apply(page, nil)).to equal(page)
  end

  it 'serves the presentation resources with their recorded classes' do
    application = Mxrb::RubyApp::Application.allocate
    layout = { kind: 'snippet', widgets: [{ type: 'container', name: 'bar' }] }
    Dir.mktmpdir do |root|
      allow(application).to receive(:root).and_return(root)
      expect(application.send(:design_classes)).to eq({})
      application.instance_variable_set(:@design_classes, nil)
      FileUtils.mkdir_p(File.join(root, '.mxrb'))
      File.write(File.join(root, described_class::PATH), JSON.generate('App.Layout' => { 'bar' => 'flex-nowrap' }))
      allow(Mxrb::RubyApp::Registry).to receive(:all).with(:presentation)
                                                     .and_return('App.Layout' => layout, 'App.Other' => { kind: 'x' })
      served = application.send(:design_classed_presentation)
      expect(served.fetch('App.Layout').dig('widgets', 0, 'options')).to eq('design_class' => 'flex-nowrap')
      expect(served.fetch('App.Other')).to eq(kind: 'x')
    end
  end

  it 'adds the recorded classes to a served page' do
    application = Mxrb::RubyApp::Application.allocate
    implementation = double('page', mendix_name: 'App.Home', mendix_id: 'home', title: 'Home', appearance_class: '',
                                    appearance_style: '', data_source: nil, presentation_contract: nil)
    allow(Mxrb::RubyApp::Registry).to receive(:fetch).with(:page, 'App.Home').and_return(implementation)
    allow(application).to receive(:authorize_document!)
    allow(Mxrb::RubyApp::Presentation).to receive(:page)
      .and_return(widgets: [{ type: 'button', name: 'save', options: {} }])
    application.instance_variable_set(:@design_classes, 'App.Home' => { 'save' => 'btn-lg' })
    expect(application.page('App.Home').dig('widgets', 0, 'options')).to eq('design_class' => 'btn-lg')
    application.instance_variable_set(:@design_classes, {})
    expect(application.page('App.Home')[:widgets]).to eq([{ type: 'button', name: 'save', options: {} }])
    expect(Mxrb::RubyApp::Application.allocate.send(:design_classes)).to eq({})
  end

  it 'imports the icon of sidebar toggle buttons' do
    icon = { '$Type' => 'Forms$IconCollectionIcon', 'Image' => 'Atlas_Core.Atlas_Filled.navigation-menu' }
    toggle = { '$Type' => 'Forms$SidebarToggleButton', 'Name' => 'toggle', 'ButtonStyle' => 'Primary', 'Icon' => icon }
    page = Mxrb::Model::Page.allocate
    expect(page.send(:widget_options, toggle,
                     :sidebar_toggle)).to include(icon: 'Atlas_Core.Atlas_Filled.navigation-menu')
    expect(page.send(:widget_options, toggle.merge('Icon' => nil), :sidebar_toggle)).not_to have_key(:icon)
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    builder.sidebar_toggle('toggle', caption: '', icon: 'Atlas_Core.Atlas_Filled.navigation-menu')
    expect(builder.widgets.first.dig(:options, :icon)).to eq('Atlas_Core.Atlas_Filled.navigation-menu')
  end
end
