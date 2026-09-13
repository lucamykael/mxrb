# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::PageBundleCompiler, 'core widget interaction branches' do
  around do |example|
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'Interactions.mpr')
      Mxrb.define(mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          layout :Shell
          page(:Home) { layout 'Demo.Shell' }
        end
      end
      source = Mxrb::Compiler::SourceModel.read(mpr)
      @compiler = described_class.new(source)
      @compiler.compile(source.units_of('Forms$Page').first)
      example.run
    end
  end

  def text(value)
    { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => value }] }
  end

  def client_template(value)
    { 'Template' => text(value), 'Parameters' => [2] }
  end

  def open_link(address)
    {
      '$Type' => 'Forms$OpenLinkClientAction', 'LinkType' => 'Web',
      'Address' => { 'IsDynamic' => false, 'Value' => address }
    }
  end

  def encoded(*values) = [2, *values]

  it 'covers grid controls with disabled and executable buttons' do
    expect(@compiler.send(:render_grid_controls, 'IsControlBarVisible' => false)).to be_nil

    disabled = {
      '$Type' => 'Forms$GridNewButton', 'Name' => 'new',
      'CaptionTemplate' => client_template(''), 'Action' => { '$Type' => 'Forms$NoAction' }
    }
    executable = {
      '$Type' => 'Forms$GridEditButton', 'Name' => 'edit',
      'CaptionTemplate' => client_template('Edit'), 'Action' => open_link('https://edit.test')
    }
    controls = @compiler.send(
      :render_grid_controls,
      'Name' => 'items', 'ControlBar' => { 'NewButtons' => encoded(disabled, executable) }
    )

    expect(controls).to include('mx-grid-controlbar', 'New', 'Edit', 'https://edit.test', 'disabled')
  end

  it 'covers collection children, optional actions, dimensions, and association paths' do
    grid = {
      '$Type' => 'Forms$TemplateGrid', 'Name' => 'cards', 'NumberOfColumns' => 3,
      'DataSource' => {
        '$Type' => 'Forms$GridXPathSource', 'EntityRef' => { 'Entity' => 'Demo.Item' },
        'XPathConstraint' => ''
      },
      'Contents' => { 'Widgets' => [2, { '$Type' => 'Forms$StaticLabel', 'Name' => 'title',
                                         'Caption' => text('Card') }] }
    }
    expect(@compiler.send(:render_template_grid, grid)).to include('Forms$StaticLabel', 'data-columns')

    items = [2,
             { '$Type' => 'Forms$DropDownButtonItem', 'Caption' => text('None'),
               'Action' => { '$Type' => 'Forms$NoAction' } },
             { '$Type' => 'Forms$DropDownButtonItem', 'Caption' => text('Open'),
               'Action' => open_link('https://open.test') }]
    dropdown = @compiler.send(:render_drop_down_button, {
      '$Type' => 'Forms$DropDownButton', 'Name' => 'more',
      'Caption' => client_template('More'), 'Items' => items
    })
    expect(dropdown).to include('None', 'Open', 'https://open.test')

    no_navigation = {
      '$Type' => 'Forms$NavigationListItem', 'Name' => 'none', 'Widgets' => [2],
      'Action' => { '$Type' => 'Forms$NoAction' }
    }
    open_navigation = {
      '$Type' => 'Forms$NavigationListItem', 'Name' => 'open', 'Widgets' => [2],
      'Action' => open_link('https://navigation.test')
    }
    navigation = @compiler.send(
      :render_navigation_list,
      '$Type' => 'Forms$NavigationList', 'Name' => 'links',
      'Items' => encoded(no_navigation, open_navigation)
    )
    expect(navigation).to include('https://navigation.test')

    expect(@compiler.send(:image_dimension, 10, 'Pixels')).to eq('10px')
    expect(@compiler.send(:image_dimension, 25, 'Percentage')).to eq('25%')
    expect(@compiler.send(:image_dimension, 10, 'Unknown')).to be_nil
    expect(@compiler.send(:image_dimension, 0, 'Pixels')).to be_nil
    steps = encoded(
      { 'Association' => 'Demo.Item_Owner', 'DestinationEntity' => 'Demo.Owner' },
      { 'Association' => '', 'DestinationEntity' => nil }
    )
    expect(@compiler.send(:entity_reference_path, 'EntityRef' => { 'Steps' => steps }))
      .to eq('Demo.Item_Owner/Demo.Owner')
  end

  it 'imports the reference-set renderer after compiling a bound selector' do
    @compiler.instance_variable_set(
      :@data_view_scopes, [{ scope: 'p.Demo.Home.item', entity: 'Demo.Item' }]
    )
    output = @compiler.send(:render_reference_set_selector, {
      '$Type' => 'Forms$ReferenceSetSelector', 'Name' => 'owners',
      'AttributeRef' => {
        'Attribute' => 'Demo.Owner.Name',
        'EntityRef' => { 'Steps' => encoded(
          { 'Association' => 'Demo.Item_Owners', 'DestinationEntity' => 'Demo.Owner' }
        ) }
      }
    })

    expect(output).to include('$MxrbReferenceSetSelector', 'AssociationProperty')
    expect(@compiler.send(:widget_imports)).to include('MxrbReferenceSetSelector.displayName')
  end
end
# rubocop:enable Metrics/BlockLength
