# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::PageBundleCompiler, 'core widget catalog coverage' do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'CoreWidgets.mpr')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          layout :Shell
          page(:Home) { layout 'Demo.Shell' }
        end
      end
      example.run
    end
  end

  def text(value)
    { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => value }] }
  end

  def client_template(value)
    { 'Template' => text(value), 'Parameters' => [2] }
  end

  it 'keeps the compiler and certification inventories equal to the versioned Forms catalog' do
    expected = Mxrb::Forms::Catalog.for('11.12.1').concrete_widgets.map { "Forms$#{_1.name}" }.sort

    expect(described_class::CORE_WIDGET_RENDERERS.keys.sort).to eq(expected)
    expect(Mxrb::WidgetCertification::CORE_WIDGET_TYPES.sort).to eq(expected)
  end

  it 'renders every formerly missing concrete widget through an explicit auditable path' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    argument = unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }
    argument['Widgets'] = [
      2,
      { '$Type' => 'Forms$DataGrid', 'Name' => 'grid', 'Columns' => [2], 'ControlBar' => nil },
      { '$Type' => 'Forms$DropDown', 'Name' => 'status', 'EmptyOptionCaption' => text('Choose') },
      { '$Type' => 'Forms$DropDownButton', 'Name' => 'more', 'Caption' => client_template('More'),
        'Items' => [2, { '$Type' => 'Forms$DropDownButtonItem', 'Caption' => text('Open'),
                         'Action' => { '$Type' => 'Forms$NoAction' } }] },
      { '$Type' => 'Forms$DynamicImageViewer', 'Name' => 'photo', 'DefaultImage' => '' },
      { '$Type' => 'Forms$ImageUploader', 'Name' => 'upload' },
      { '$Type' => 'Forms$InputReferenceSetSelector', 'Name' => 'roles' },
      { '$Type' => 'Forms$LoginButton', 'Name' => 'login', 'CaptionTemplate' => client_template('Sign in'),
        'ValidationMessageWidget' => 'loginError' },
      { '$Type' => 'Forms$LoginIdTextBox', 'Name' => 'username', 'Label' => text('Username'),
        'Placeholder' => text('Username') },
      { '$Type' => 'Forms$NavigationList', 'Name' => 'links', 'Items' => [2, {
        '$Type' => 'Forms$NavigationListItem', 'Name' => 'first', 'Widgets' => [2],
        'Action' => { '$Type' => 'Forms$NoAction' }
      }] },
      { '$Type' => 'Forms$PasswordTextBox', 'Name' => 'password', 'Label' => text('Password'),
        'Placeholder' => text('Password') },
      { '$Type' => 'Forms$ReferenceSelector', 'Name' => 'owner' },
      { '$Type' => 'Forms$ReferenceSetSelector', 'Name' => 'members' },
      { '$Type' => 'Forms$TabContainer', 'Name' => 'tabs', 'TabPages' => [2, {
        '$Type' => 'Forms$TabPage', 'Name' => 'general', 'Caption' => text('General'), 'Widgets' => [2]
      }] },
      { '$Type' => 'Forms$TemplateGrid', 'Name' => 'cards', 'Contents' => {
        '$Type' => 'Forms$TemplateGridContents', 'Widgets' => [2]
      } },
      { '$Type' => 'Forms$TemplatePlaceholder', 'Name' => 'slot', 'Type' => 'Contents' },
      { '$Type' => 'Forms$ValidationMessage', 'Name' => 'loginError' }
    ]

    bundle = described_class.new(source).compile(unit)

    expect(bundle.unsupported_widgets).to be_empty
    expect(bundle.source).to include(
      'data-mxrb-widget-type', 'Forms$DataGrid', '$MxrbDropDownButton', '$MxrbLoginInput',
      '$MxrbLoginButton', '$NavigationList', '$TabContainer', 'mx-validation-message',
      'Forms$TemplateGrid', '$Placeholder'
    )
    _stdout, stderr, status = Open3.capture3(
      'node', '--input-type=module', '--check', stdin_data: bundle.source
    )
    expect(stderr).to eq('')
    expect(status).to be_success
  end

  it 'lowers configured list, enum, association, image, and upload contracts to Runtime properties' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    compiler = described_class.new(source)
    compiler.compile(unit)
    compiler.instance_variable_set(
      :@data_view_scopes, [{ scope: 'p.Demo.Home.item', entity: 'Demo.Item' }]
    )

    grid = {
      '$Type' => 'Forms$DataGrid', 'Name' => 'items', 'NumberOfRows' => 10,
      'DataSource' => {
        '$Type' => 'Forms$GridXPathSource',
        'EntityRef' => { 'Entity' => 'Demo.Item' }, 'XPathConstraint' => ''
      },
      'Columns' => [2, {
        '$Type' => 'Forms$GridColumn', 'Name' => 'name', 'Caption' => text('Name'),
        'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' }
      }]
    }
    drop_down = {
      '$Type' => 'Forms$DropDown', 'Name' => 'status',
      'AttributeRef' => { 'Attribute' => 'Demo.Item.Status' },
      'LabelTemplate' => client_template('Status'), 'EmptyOptionCaption' => text('Choose'),
      'ReadOnlyStyle' => 'Control',
      'OnChangeAction' => { '$Type' => 'Forms$OpenLinkClientAction', 'LinkType' => 'Web',
                            'Address' => { 'IsDynamic' => false, 'Value' => 'https://change.test' } },
      'OnEnterAction' => { '$Type' => 'Forms$OpenLinkClientAction', 'LinkType' => 'Web',
                           'Address' => { 'IsDynamic' => false, 'Value' => 'https://enter.test' } }
    }
    reference = {
      '$Type' => 'Forms$ReferenceSelector', 'Name' => 'owner',
      'AttributeRef' => {
        'Attribute' => 'Demo.Owner.Name', 'EntityRef' => { 'Steps' => [2, {
          'Association' => 'Demo.Item_Owner', 'DestinationEntity' => 'Demo.Owner'
        }] }
      }, 'LabelTemplate' => client_template('Owner')
    }

    rendered = []
    rendered << compiler.send(:render_data_grid, grid)
    expect(rendered.last).to include(
      '$ListView', 'DatabaseObjectListProperty', '$MxrbAttributeValue', 'Demo.Item'
    )
    rendered << compiler.send(:render_drop_down, drop_down)
    expect(rendered.last).to include(
      '$EnumSelect', 'AttributeProperty', 'https://change.test', 'https://enter.test',
      '"readOnlyStyle": "control"', '"onEnter": ActionProperty'
    )
    rendered << compiler.send(:render_reference_selector, reference)
    expect(rendered.last).to include(
      '$ReferenceSelector', 'AssociationProperty', 'ListAttributeProperty', 'Demo.Item_Owner'
    )
    rendered << compiler.send(:render_dynamic_image, {
      '$Type' => 'Forms$DynamicImageViewer', 'Name' => 'photo',
      'ClickAction' => { '$Type' => 'Forms$OpenLinkClientAction', 'LinkType' => 'Web',
                         'Address' => { 'IsDynamic' => false, 'Value' => 'https://image.test' } }
    })
    expect(rendered.last).to include('$Image', 'WebDynamicImageProperty', 'https://image.test', 'onClick')
    rendered << compiler.send(:render_image_uploader, {
      '$Type' => 'Forms$ImageUploader', 'Name' => 'upload'
    })
    expect(rendered.last).to include('$FileManager', 'DynamicFileProperty')
    rendered << compiler.send(:render_tab_control, {
      '$Type' => 'Forms$TabContainer', 'Name' => 'tabs',
      'ActivePageAttributeRef' => { 'Attribute' => 'Demo.Item.ActiveTab' },
      'ActivePageOnChangeAction' => {
        '$Type' => 'Forms$OpenLinkClientAction', 'LinkType' => 'Web',
        'Address' => { 'IsDynamic' => false, 'Value' => 'https://tab.test' }
      },
      'TabPages' => [2, {
        '$Type' => 'Forms$TabPage', 'Name' => 'details', 'Caption' => text('Details'),
        'Badge' => client_template('1'), 'Widgets' => [2]
      }]
    })
    expect(rendered.last).to include(
      '$TabContainer', '"activeTab": AttributeProperty', '"onTabChange": ActionProperty',
      'https://tab.test', '"badge": TextProperty'
    )

    imports = compiler.send(:widget_imports)
    expect(imports).to include(
      'mendix/widgets/web/EnumSelect', 'mendix/widgets/web/ReferenceSelector',
      'mendix/AssociationProperty', 'mendix/WebDynamicImageProperty'
    )
    javascript = <<~JS
      import React from "react";
      #{imports}
      export default () => React.createElement(React.Fragment, null, [#{rendered.join(', ')}]);
    JS
    _stdout, stderr, status = Open3.capture3(
      'node', '--input-type=module', '--check', stdin_data: javascript
    )
    expect(stderr).to eq('')
    expect(status).to be_success
  end
end
# rubocop:enable Metrics/BlockLength
