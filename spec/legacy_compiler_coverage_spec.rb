# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'zip'
require 'spec_helper'

# Exercises the defensive edges of the legacy serializers with small, explicit contracts.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::LegacyCustomWidgetCompiler do
  def compiler_for(source, widget = {})
    described_class.new(
      source,
      { 'Type' => { 'WidgetId' => 'Demo.widget.Sample', 'ObjectType' => {} }, **widget },
      language: 'pt_BR'
    )
  end

  it 'serializes every schema value family and all translation/image fallbacks' do
    image = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: {
        '$Type' => 'Images$ImageCollection', 'Name' => 'Assets',
        'Images' => [2, { 'Name' => 'Logo', 'Image' => BSON::Binary.new("\x89PNG\r\n\x1A\nimage".b) }]
      }
    )
    source = instance_double(Mxrb::Compiler::SourceModel)
    allow(source).to receive(:units_of).with('Images$ImageCollection').and_return([image])
    compiler = compiler_for(source)

    values = {
      'Boolean' => [{ 'PrimitiveValue' => 'true' }, true],
      'Integer' => [{ 'PrimitiveValue' => '12' }, 12],
      'Decimal' => [{ 'PrimitiveValue' => '1.5' }, 1.5],
      'Enumeration' => [{ 'PrimitiveValue' => 'Open' }, 'Open'],
      'String' => [{ 'PrimitiveValue' => 'value' }, 'value'],
      'System' => [{ 'PrimitiveValue' => 'system' }, 'system'],
      'TranslatableString' => [{ 'TranslatableValue' => {
        'Items' => [2, { 'LanguageCode' => 'pt_BR', 'Text' => 'Traduzido' }]
      } }, 'Traduzido'],
      'Entity' => [{ 'EntityPath' => 'Demo.Item' }, 'Demo.Item'],
      'EntityConstraint' => [{ 'XPathConstraint' => '[Active]' }, '[Active]'],
      'Attribute' => [{ 'AttributePath' => 'Demo.Item.Name' }, 'Name'],
      'Microflow' => [{ 'Microflow' => 'Demo.Run' }, 'Demo.Run'],
      'Form' => [{ 'Form' => 'Demo.Home' }, 'Demo.Home'],
      'Image' => [{ 'Image' => 'Demo.Assets.Logo' }, 'img/Demo$Logo.png']
    }
    values.each do |type, (input, expected)|
      expect(compiler.send(:compile_value, type, input)).to eq(expected)
    end
    expect(compiler.send(:compile_value, 'Image', {})).to eq('')
    expect(compiler.send(:compile_value, 'Unknown', {})).to be_nil
    expect(compiler.send(:compile_value, 'Boolean', nil)).to be(false)

    translations = lambda do |items|
      compiler.send(:translated, items.nil? ? nil : { 'Items' => [2, *items] })
    end
    expect(translations.call([{ 'LanguageCode' => 'pt_BR', 'Text' => 'Atual' }])).to eq('Atual')
    expect(translations.call([{ 'LanguageCode' => 'en_US', 'Text' => 'English' }])).to eq('English')
    expect(translations.call([{ 'LanguageCode' => 'de_DE', 'Text' => 'Erste' }])).to eq('Erste')
    expect(translations.call([])).to eq('')
    expect(translations.call(nil)).to eq('')

    expect(compiler.send(:image_uri, 'Missing.Assets.Logo')).to be_nil
    expect(compiler.send(:image_uri, 'System.Images.Error')).to eq('img/System$Error.gif')
    expect(compiler.send(:image_uri, 'System.Images.Add')).to eq('img/System$Add.png')
    expect(compiler.send(:image_uri, 'System.Other.Add')).to be_nil
    expect(compiler.send(:image_uri, 'System.Images.')).to be_nil
  end

  it 'validates nested object schemas, missing properties, and unsupported values' do
    nested_id = SecureRandom.uuid
    bool_id = SecureRandom.uuid
    widget = {
      'Type' => {
        'WidgetId' => 'Demo.widget.Sample',
        'ObjectType' => {
          'PropertyTypes' => [2, {
            '$ID' => nested_id, 'PropertyKey' => 'items',
            'ValueType' => {
              'Type' => 'Object', 'ObjectType' => {
                'PropertyTypes' => [2, {
                  '$ID' => bool_id, 'PropertyKey' => 'enabled', 'ValueType' => { 'Type' => 'Boolean' }
                }]
              }
            }
          }]
        }
      },
      'Object' => {
        'Properties' => [2, {
          'TypePointer' => nested_id,
          'Value' => { 'Objects' => [2, { 'Properties' => [2, {
            'TypePointer' => bool_id, 'Value' => { 'PrimitiveValue' => 'true' }
          }] }] }
        }]
      }
    }
    source = instance_double(Mxrb::Compiler::SourceModel)
    allow(source).to receive(:units_of).with('Images$ImageCollection').and_return([])
    compiler = compiler_for(source, widget)

    expect(compiler).to be_supported
    expect(compiler.properties_hash).to eq('items' => [{ 'enabled' => true }])
    expect(compiler.send(:objects, nil)).to eq([])
    expect(compiler_for(source, 'Object' => nil)).to be_supported

    unsupported = widget.merge('Object' => {
      'Properties' => [2, { 'TypePointer' => bool_id, 'Value' => {} }]
    })
    unsupported['Type'] = widget['Type'].merge('ObjectType' => {
      'PropertyTypes' => [2, { '$ID' => bool_id, 'ValueType' => { 'Type' => 'Unsupported' } }]
    })
    expect(compiler_for(source, unsupported)).not_to be_supported

    image_id = SecureRandom.uuid
    missing_image = {
      'Type' => {
        'WidgetId' => 'Demo.widget.Sample',
        'ObjectType' => { 'PropertyTypes' => [2, {
          '$ID' => image_id, 'PropertyKey' => 'image', 'ValueType' => { 'Type' => 'Image' }
        }] }
      },
      'Object' => { 'Properties' => [2, {
        'TypePointer' => image_id, 'Value' => { 'Image' => 'Demo.Assets.Missing' }
      }] }
    }
    expect(compiler_for(source, missing_image)).not_to be_supported
  end

  it 'detects loose, archived, missing, and corrupt widget packages for real source models' do
    Dir.mktmpdir do |root|
      project = File.join(root, 'project.mpr')
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      source = Mxrb::Compiler::SourceModel.allocate
      source.instance_variable_set(:@path, project)

      compiler = compiler_for(source)
      expect(compiler.send(:package_module?)).to be(false)

      loose = File.join(widgets, 'Demo/widget/Sample.js')
      FileUtils.mkdir_p(File.dirname(loose))
      File.write(loose, 'define([])')
      expect(compiler.send(:package_module?)).to be(true)
      FileUtils.rm_f(loose)

      Zip::File.open(File.join(widgets, 'sample.mpk'), create: true) do |zip|
        zip.get_output_stream('Demo/widget/Sample.js') { _1.write('define([])') }
      end
      expect(compiler.send(:package_module?)).to be(true)
      FileUtils.rm_f(File.join(widgets, 'sample.mpk'))

      File.write(File.join(widgets, 'broken.mpk'), 'not a zip')
      expect(compiler.send(:package_module?)).to be(false)
    end
  end
end

RSpec.describe Mxrb::Compiler::LegacyPageBuilder do
  def unit(type, name, document = {}, module_name: 'Demo')
    Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name:,
      document: { '$Type' => type, 'Name' => name, **document }
    )
  end

  def source_with(units = [], documents: nil)
    source = instance_double(Mxrb::Compiler::SourceModel, documents: documents || units.map(&:document))
    allow(source).to receive(:units_of) { |type| units.select { _1.document['$Type'] == type } }
    source
  end

  def builder_for(units = [], documents: nil)
    described_class.new(source_with(units, documents:), '/not-used').tap do |builder|
      builder.instance_variable_set(:@widget_sequence, 0)
      builder.instance_variable_set(:@widget_ids_by_name, {})
      builder.instance_variable_set(:@templates, [])
    end
  end

  it 'filters native pages and layouts when operating on a concrete source model' do
    web_layout = unit('Forms$Layout', 'Web', { 'Content' => { '$Type' => 'Forms$WebLayoutContent' } })
    native_layout = unit('Forms$Layout', 'Native', { 'Content' => { '$Type' => 'Forms$NativeLayoutContent' } })
    web_page = unit('Forms$Page', 'WebPage', { 'FormCall' => { 'Form' => 'Demo.Web' } })
    native_page = unit('Forms$Page', 'NativePage', { 'FormCall' => { 'Form' => 'Demo.Native' } })
    source = Mxrb::Compiler::SourceModel.allocate
    source.instance_variable_set(:@units, [web_layout, native_layout, web_page, native_page])
    builder = described_class.new(source, '/not-used')

    expect(builder.send(:legacy_layouts)).to eq([web_layout])
    expect(builder.send(:legacy_pages)).to eq([web_page])
  end

  it 'audits each unsupported visible contract without silently discarding it' do
    source = source_with([])
    allow(source).to receive(:units_of).with('Images$ImageCollection').and_return([])
    builder = described_class.new(source, '/not-used')
    widgets = [
      { '$Type' => 'Forms$VerticalSplitPane' },
      { '$Type' => 'Forms$ActionButton', 'Action' => {} },
      { '$Type' => 'Forms$ActionButton', 'Action' => { '$Type' => 'Forms$UnknownAction' } },
      { '$Type' => 'Forms$DataView' },
      { '$Type' => 'Forms$DataView', 'DataSource' => { '$Type' => 'Forms$UnknownSource' } },
      { '$Type' => 'Forms$ListView' },
      { '$Type' => 'Forms$ListView', 'DataSource' => { '$Type' => 'Forms$UnknownListSource' } },
      { '$Type' => 'Forms$StaticImageViewer', 'ClickAction' => { '$Type' => 'Forms$NoAction' } },
      { '$Type' => 'Forms$ImageViewer' },
      { '$Type' => 'Forms$ImageUploader' },
      { '$Type' => 'Forms$ReferenceSetSelector' },
      { '$Type' => 'Forms$MenuBar' },
      { '$Type' => 'Forms$SnippetCallWidget', 'FormCall' => { 'Form' => 'Demo.Missing' } },
      {
        '$Type' => 'CustomWidgets$CustomWidget',
        'Type' => {
          'WidgetId' => 'Missing.Widget',
          'ObjectType' => { 'PropertyTypes' => [2, {
            '$ID' => 'unsupported', 'ValueType' => { 'Type' => 'Unsupported' }
          }] }
        },
        'Object' => { 'Properties' => [2, { 'TypePointer' => 'unsupported', 'Value' => {} }] }
      },
      { '$Type' => 'Forms$TextBox' }
    ]
    builder.send(:audit_unsupported_widgets, { 'Widgets' => [2, *widgets] }, 'Demo.Audit')

    expect(builder.send(:frozen_unsupported).fetch('Demo.Audit')).to include(
      'Forms$VerticalSplitPane', 'Forms$ActionButton(action)', 'Forms$UnknownAction',
      'Forms$DataView(source)', 'Forms$UnknownSource', 'Forms$ListView(source)',
      'Forms$UnknownListSource', 'Forms$StaticImageViewer', 'Forms$ImageViewer',
      'Forms$ImageUploader', 'Forms$ReferenceSetSelector', 'Forms$MenuBar',
      'Forms$SnippetCallWidget', 'Missing.Widget', 'Forms$TextBox'
    )
  end

  it 'renders remaining dispatcher and elementary layout branches' do
    builder = builder_for
    mobile = { '$Type' => 'Forms$MobileCancelButton', 'ClosePage' => false,
               'CaptionTemplate' => { 'Template' => nil } }
    expect(builder.send(:render_widget, mobile, 'Demo.Page', 'en_US')).to include('mxui.widget.CancelButton')
    expect(builder.send(:render_widget, { '$Type' => 'Unknown' }, 'Demo.Page', 'en_US')).to eq('')
    expect(builder.send(:render_widget, nil, 'Demo.Page', 'en_US')).to eq('')

    cell = { 'IsHeader' => false, 'Width' => 2, 'Height' => 3, 'Widgets' => [2] }
    expect(builder.send(:render_table_cell, cell, 'Demo.Page', 'en_US')).to include(
      "<td colspan='2' rowspan='3'>"
    )
    expect(builder.send(:image_dimension, 20, 'Percentage')).to eq('20%')
    expect(builder.send(:image_dimension, 20, 'Unknown')).to eq('')
    expect(builder.send(:positive_integer, 'bad', 7)).to eq(7)
  end

  it 'renders reference sets, custom widgets, scroll variants, and navigation fallbacks' do
    navigation = unit(
      'Navigation$NavigationDocument', 'Navigation',
      {
        'Profiles' => [2, { 'Name' => 'Tablet', 'Menu' => { '$ID' => SecureRandom.uuid } }],
        'PhoneProfile' => { 'Menu' => { '$ID' => SecureRandom.uuid } }
      },
      module_name: nil
    )
    menu = unit('Menus$MenuDocument', 'Empty', {}, module_name: 'Demo')
    source = source_with([navigation, menu])
    allow(source).to receive(:units_of).with('Images$ImageCollection').and_return([])
    builder = described_class.new(source, '/not-used')
    builder.instance_variable_set(:@widget_sequence, 0)
    builder.instance_variable_set(:@widget_ids_by_name, {})
    builder.instance_variable_set(:@templates, [])

    selector = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ReferenceSetSelector', 'Name' => 'tags',
      'DataSource' => { '$Type' => 'Forms$ReferenceSetSource',
                        'EntityPath' => 'Demo.Item_Tags/Demo.Tag' },
      'Columns' => [2], 'ControlBar' => {}, 'IsPagingEnabled' => false
    }
    custom = {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'sample',
      'Type' => { 'WidgetId' => 'Demo.widget.Sample', 'ObjectType' => {} }, 'Object' => nil
    }
    expect(builder.send(:render_widget, selector, 'Demo.Page', 'en_US'))
      .to include('mxui.widget.ReferenceSetSelector')
    expect(builder.send(:render_widget, custom, 'Demo.Page', 'en_US')).to include('Demo.widget.Sample')
    expect(builder.send(:render_custom_widget, { '$Type' => 'CustomWidgets$CustomWidget' }, 'en_US')).to eq('')

    vertical = {
      '$Type' => 'Forms$ScrollContainer', 'ScrollBehavior' => 'Document',
      'CenterRegion' => { 'SizeMode' => 'Auto', 'Widgets' => [2] }
    }
    html = builder.send(:render_widget, vertical, 'Demo.Page', 'en_US')
    expect(html).to include('mxui.widget.VerticalScrollContainer')
    expect(html).not_to include('mx-scrollcontainer-fixed')
    expect(builder.send(:legacy_toggle_mode, 'ShrinkContentInitiallyOpen')).to eq('shrinkContent')
    expect(builder.send(:legacy_toggle_mode, 'PushContentInitiallyClosed')).to eq('pushContentAside')
    expect(builder.send(:legacy_toggle_mode, 'SlideOverContentInitiallyOpen')).to eq('slideOverContent')
    expect(builder.send(:legacy_toggle_mode, 'OverlayInitiallyClosed')).to eq('overlay')
    expect(builder.send(:scroll_region_style, { 'SizeMode' => 'Pixels', 'Size' => 0 }, 'left')).to eq('')
    expect(builder.send(:scroll_region_style, { 'SizeMode' => 'Pixels', 'Size' => 20 }, 'top'))
      .to eq('height:20px')

    toggle = { '$Type' => 'Forms$SidebarToggleButton', 'RenderType' => 'Link',
               'CaptionTemplate' => { 'Template' => nil } }
    expect(builder.send(:render_sidebar_toggle, toggle, 'en_US')).to include('SidebarToggleButton')
    simple = { '$Type' => 'Forms$SimpleMenuBar', 'Orientation' => 'Vertical',
               'MenuSource' => { '$Type' => 'Forms$MenuDocumentSource', 'Menu' => 'Demo.Empty' } }
    expect(builder.send(:render_navigation, simple)).to include('mxui.widget.MenuBar', 'vertical')

    expect(builder.send(:menu_identifier, nil)).to be_nil
    expect(builder.send(:menu_identifier, '$Type' => 'Unknown')).to be_nil
    expect(builder.send(:menu_identifier, '$Type' => 'Forms$NavigationSource',
                                          'NavigationProfile' => 'Tablet', 'DeviceType' => 'Phone')).not_to be_nil
    expect(builder.send(:menu_identifier, '$Type' => 'Forms$NavigationSource',
                                          'NavigationProfile' => 'Missing', 'DeviceType' => 'Unknown')).to be_nil
    expect(builder.send(:menu_identifier, '$Type' => 'Forms$MenuDocumentSource',
                                          'Menu' => 'Demo.Missing')).to be_nil
  end

  it 'covers list, data-view, snippet, and dynamic association edge contracts' do
    nested = unit('Forms$Snippet', 'Nested', {
      'Widgets' => [2, { '$Type' => 'Forms$SnippetCallWidget',
                         'FormCall' => { 'Form' => 'Demo.Missing' } }]
    })
    cyclic = unit('Forms$Snippet', 'Cyclic', {
      'Widgets' => [2, { '$Type' => 'Forms$SnippetCallWidget',
                         'FormCall' => { 'Form' => 'Demo.Cyclic' } }]
    })
    page = unit('Forms$Page', 'Page', {
      'Widgets' => [2,
                    { '$Type' => 'Forms$SnippetCallWidget', 'FormCall' => { 'Form' => 'Demo.Nested' } },
                    { '$Type' => 'Forms$SnippetCallWidget', 'FormCall' => { 'Form' => 'Demo.Nested' } }]
    })
    source = source_with([page, nested, cyclic])
    builder = described_class.new(source, '/not-used')
    builder.instance_variable_set(:@widget_sequence, 0)
    builder.instance_variable_set(:@widget_ids_by_name, nil)
    builder.instance_variable_set(:@templates, [])

    empty_list = { '$Type' => 'Forms$ListView', 'Name' => '', 'Editable' => false,
                   'DataSource' => { '$Type' => 'Forms$ListViewXPathSource',
                                     'EntityRef' => { 'Entity' => 'Demo.Item' } },
                   'Widgets' => [2] }
    html = builder.send(:render_list_view, empty_list, 'Demo.Missing', 'en_US')
    expect(html).to include('mxui.widget.ListView', '"selectable":""')

    source_props = builder.send(
      :list_view_source,
      {
        'Name' => 'items', 'DataSource' => {
          '$Type' => 'Forms$ListViewXPathSource', 'EntityPath' => 'Demo.Item',
          'SortBar' => { 'SortItems' => [2, { 'AttributePath' => 'Demo.Item.Name',
                                              'SortOrder' => 'Descending' }] },
          'Search' => { 'SearchRefs' => [2, 'Demo.Item.Code'] }
        }
      },
      'Demo.Page', 'Demo.Item'
    )
    expect(source_props).to include('sort' => [%w[Name desc]], 'search' => ['Code'])
    expect(builder.send(:list_view_source,
                        { 'Name' => 'empty', 'DataSource' => { '$Type' => 'Forms$ListViewXPathSource' } },
                        'Demo.Page', '')).not_to have_key('sort')

    expect(builder.send(:legacy_related_documents, 'Demo.Missing')).to eq([])
    related = builder.send(:legacy_related_documents, 'Demo.Page')
    expect(related).to include(page.document, nested.document)
    expect(builder.send(:legacy_related_snippet_documents, cyclic, {})).to include(cyclic.document)
    missing_page = unit('Forms$Page', 'MissingSnippetPage', {
      'Widgets' => [2, { '$Type' => 'Forms$SnippetCallWidget',
                         'FormCall' => { 'Form' => 'Demo.NotThere' } }]
    })
    missing_builder = builder_for([missing_page])
    expect(missing_builder.send(:legacy_related_documents, 'Demo.MissingSnippetPage'))
      .to eq([missing_page.document])

    listen = { '$Type' => 'Forms$ListenTargetSource', 'ListenTarget' => 'missing' }
    builder.instance_variable_set(:@widget_ids_by_name, nil)
    expect(builder.send(:data_view_source, listen, 'Demo.Item')).to include('contextsource' => nil)
    expect(builder.send(:data_view_source, {}, 'Demo.Item')).to include('path' => 'Demo.Item')
    association = {
      'EntityRef' => { 'Steps' => [2, { 'Association' => 'Demo.Item_Owner',
                                        'DestinationEntity' => 'Demo.Account' }] }
    }
    expect(builder.send(:data_view_entity, association)).to eq('Demo.Account')
    expect(builder.send(:data_view_path, association)).to eq('Demo.Item_Owner/Demo.Account')
    expect(builder.send(:data_view_entity, 'EntityRef' => { 'Steps' => [2, {}] })).to eq('')
    expect(builder.send(:microflow_return_entity,
                        'MicroflowSettings' => { 'Microflow' => 'Demo.Missing' })).to eq('')

    missing_call = { '$Type' => 'Forms$SnippetCallWidget', 'FormCall' => { 'Form' => 'Demo.Missing' } }
    expect(builder.send(:render_snippet_call, missing_call, 'Demo.Page', 'en_US')).to eq('')
    recursive_call = { '$Type' => 'Forms$SnippetCallWidget', 'FormCall' => { 'Form' => 'Demo.Cyclic' } }
    expect(builder.send(:render_snippet_call, recursive_call, 'Demo.Page', 'en_US')).to eq('')
    failing_builder = builder_for
    allow(failing_builder).to receive(:snippet_unit).and_raise('lookup failed')
    expect { failing_builder.send(:render_snippet_call, missing_call, 'Demo.Page', 'en_US') }
      .to raise_error('lookup failed')
    expect { failing_builder.send(:audit_snippet_call, missing_call, 'Demo.Page', false) }
      .to raise_error('lookup failed')

    parameter = {
      'AttributeRef' => {
        'Attribute' => 'Demo.Account.Name',
        'EntityRef' => { 'Steps' => [2, { 'Association' => 'Demo.Item_Owner',
                                          'DestinationEntity' => 'Demo.Account' }] }
      }
    }
    expect(builder.send(:dynamic_text_attribute_path, parameter))
      .to eq('Demo.Item_Owner/Demo.Account/Name')
    builder.instance_variable_set(:@data_view_stack, nil)
    expect(builder.send(:dynamic_text_attribute_path,
                        'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' })).to eq('Demo.Item.Name')
  end

  it 'covers editor, media, action, and domain-model defensive contracts' do
    image = unit('Images$ImageCollection', 'Assets', {
      'Images' => [2, { 'Name' => 'Logo', 'Image' => BSON::Binary.new("\x89PNG\r\n\x1A\nimage".b) }]
    })
    page = unit('Forms$Page', 'Target', { 'PopupResizable' => false })
    domain = unit('DomainModels$DomainModel', 'Domain', {
      'Entities' => [2, {
        'Name' => 'Item', 'Attributes' => [2,
                                           { 'Name' => 'Name', 'NewType' => {
                                             '$Type' => 'DomainModels$StringAttributeType', 'Length' => 40
                                           } },
                                           { 'Name' => 'When', 'NewType' => {
                                             '$Type' => 'DomainModels$DateTimeAttributeType'
                                           } },
                                           { 'Name' => 'LegacyState', 'Type' => {
                                             '$Type' => 'DomainModels$EnumerationAttributeType',
                                             'Enumeration' => 'Demo.MissingEnumeration'
                                           } }]
      }]
    })
    source = source_with([image, page, domain])
    allow(source).to receive(:version).and_return('11.12.1')
    builder = described_class.new(source, '/not-used')
    builder.instance_variable_set(:@widget_sequence, 0)
    builder.instance_variable_set(:@widget_ids_by_name, {})
    builder.instance_variable_set(:@templates, [])
    context = { entity: 'Demo.Item', label_width: 3, editable: true }

    expect(builder.send(:bound_input_contract, { '$Type' => 'Unknown' }, 'en_US', context)).to be_nil
    text = { '$Type' => 'Forms$TextBox', 'AttributePath' => 'Demo.Item.Name',
             'InputMask' => 'AAA', 'MaxLengthCode' => 0 }
    expect(builder.send(:bound_input_contract, text, 'en_US', context).last)
      .to include('mask' => 'AAA', 'maxLength' => 40)
    legacy_text = text.merge('AttributePath' => 'Demo.Item.LegacyState')
    expect(builder.send(:bound_input_contract, legacy_text, 'en_US', context).first)
      .to eq('mxui.widget.TextInput')
    area = { '$Type' => 'Forms$TextArea', 'AttributePath' => 'Demo.Item.Name', 'MaxLengthCode' => 12 }
    expect(builder.send(:bound_input_contract, area, 'en_US', context).last).to include('maxLength' => 12)
    date = { '$Type' => 'Forms$DatePicker', 'AttributePath' => 'Demo.Item.When',
             'FormattingInfo' => { 'DateFormat' => 'Time', 'CustomDateFormat' => 'HH:mm' } }
    expect(builder.send(:bound_input_contract, date, 'en_US', context).last)
      .to include('selector' => 'time', 'format' => 'HH:mm')
    expect(builder.send(:read_only_style, 'ReadOnlyStyle' => 'Control')).to eq('control')
    expect(builder.send(:render_label, { 'RenderMode' => 'Paragraph' }, 'en_US')).to start_with('<p')

    reference = {
      '$Type' => 'Forms$ReferenceSelector', 'AttributePath' => 'Demo.Item_Category/Demo.Category.Name',
      'SelectorSource' => { '$Type' => 'Forms$SelectorXPathSource' },
      'GotoFormSettings' => { 'Form' => 'Demo.Target', 'Location' => 'Content' }
    }
    expect(builder.send(:bound_input_contract, reference, 'en_US', context).last)
      .to include('gotoPageSettings' => include('location' => 'content'))
    set = reference.merge('$Type' => 'Forms$InputReferenceSetSelector', 'GotoFormSettings' => nil,
                          'PopupFormSettings' => {}, 'SelectorSource' => {
                            '$Type' => 'Forms$SelectorXPathSource', 'XPathConstraint' => ''
                          })
    expect(builder.send(:bound_input_contract, set, 'en_US', context).last)
      .not_to have_key('selectPageSettings')

    static = { '$Type' => 'Forms$StaticImageViewer', 'Image' => 'Demo.Assets.Logo',
               'ClickAction' => { '$Type' => 'Forms$NoAction' }, 'Responsive' => false }
    expect(builder.send(:render_static_image, static)).not_to include('img-responsive', '&quot;action&quot;')
    viewer = { '$Type' => 'Forms$ImageViewer', 'DefaultImage' => 'Demo.Assets.Logo',
               'Responsive' => true, 'Width' => 1, 'WidthUnit' => 'Pixels' }
    expect(builder.send(:render_image_viewer, viewer)).to include('img-responsive', 'img/Demo$Logo.png')
    expect(builder.send(:render_image_viewer, viewer.merge('DefaultImage' => '')))
      .to include('"defaultUrl":""')
    uploader = { '$Type' => 'Forms$ImageUploader', 'ThumbnailSize' => '0;0' }
    expect(builder.send(:render_image_uploader, uploader)).to include(
      '"thumbnailWidth":100', '"thumbnailHeight":75'
    )
    expect(builder.send(:button_properties,
                        { 'Icon' => { 'Image' => 'Demo.Assets.Logo' } }, 'en_US')).to have_key('iconUrl')

    expect(builder.send(:legacy_client_action, '$Type' => 'Unknown')).to be_nil
    action = { '$Type' => 'Forms$MicroflowAction', 'MicroflowSettings' => {
      'Microflow' => 'Demo.Missing', 'FormValidations' => 'None'
    } }
    expect(builder.send(:legacy_client_action, action)['params']).not_to have_key('validate')
    expect(builder.send(:page_settings, 'Form' => 'Demo.Missing', 'Location' => 'Content'))
      .to eq('path' => 'Demo/Missing.page.xml', 'location' => 'content')
    expect(builder.send(:system_image_uri, 'Other', 'Add')).to be_nil
    expect(builder.send(:system_image_uri, 'Images', 'Add')).to eq('img/System$Add.png')
    expect(builder.send(:system_image_uri, 'Images', 'Error')).to eq('img/System$Error.gif')

    expect(builder.send(:dynamic_text_format,
                        'AttributeRef' => { 'Attribute' => 'Demo.Item.When' },
                        'FormattingInfo' => { 'CustomDateFormat' => 'yyyy' }))
      .to eq('type' => 'custom', 'pattern' => 'yyyy')
    expect(builder.send(:dynamic_text_format,
                        'AttributeRef' => { 'Attribute' => 'Missing' })).to eq({})
    expect(builder.send(:dynamic_text_format,
                        'AttributeRef' => { 'Attribute' => 'Demo.Item.When' },
                        'FormattingInfo' => { 'DateFormat' => 'Relative' })).to eq({})
    expect(builder.send(:dynamic_text_format,
                        'AttributeRef' => { 'Attribute' => 'Demo.Item.LegacyState' })).to eq({})
    expect(builder.send(:attribute_definition, 'Missing')).to be_nil

    seed = instance_double(Mxrb::Compiler::SystemModelSeed, domain_document: { 'Entities' => [2] })
    allow(Mxrb::Compiler::SystemModelSeed).to receive(:for).and_return(seed)
    expect(builder.send(:domain_document, 'System')).to eq('Entities' => [2])
    second_builder = described_class.new(source, '/not-used')
    allow(Mxrb::Compiler::SystemModelSeed).to receive(:for)
      .and_raise(Mxrb::CompilationError, 'missing seed')
    expect(second_builder.send(:domain_document, 'System')).to be_nil
    expect(builder.send(:enumeration_options, 'Missing', 'en_US')).to eq([])
    expect(builder.send(:enumeration_options, 'Demo.Item.LegacyState', 'en_US')).to eq([])
    expect(builder.send(:translated,
                        { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Fallback' }] },
                        'pt_BR')).to eq('Fallback')
  end

  it 'validates supported-widget predicates through their false and true edges' do
    source = source_with([])
    allow(source).to receive(:units_of).with('Images$ImageCollection').and_return([])
    builder = described_class.new(source, '/not-used')

    dynamic_link = { 'Action' => { '$Type' => 'Forms$OpenLinkClientAction',
                                   'Address' => { 'IsDynamic' => true } } }
    expect(builder.send(:supported_action_button?, dynamic_link)).to be(false)
    expect(builder.send(:supported_data_view?, 'DataSource' => { '$Type' => 'Unknown' })).to be(false)

    wrong_viewer = { 'DataSource' => { '$Type' => 'Unknown', 'EntityPath' => 'System.Image' } }
    expect(builder.send(:supported_image_viewer?, wrong_viewer, true)).to be(false)
    viewer = { 'DataSource' => { '$Type' => 'Forms$ImageViewerSource', 'EntityPath' => '' },
               'DefaultImage' => '', 'OnClickBehavior' => { '$Type' => 'Forms$OnClickNothing' } }
    expect(builder.send(:supported_image_viewer?, viewer, true)).to be(false)
    viewer['DataSource']['EntityPath'] = 'System.Image'
    viewer['DefaultImage'] = 'Demo.Assets.Missing'
    expect(builder.send(:supported_image_viewer?, viewer, true)).to be(false)
    viewer['DefaultImage'] = ''
    expect(builder.send(:supported_image_viewer?, viewer, true)).to be(true)

    selector = { 'DataSource' => { '$Type' => 'Forms$ReferenceSetSource',
                                   'EntityPath' => 'one/two/three' } }
    expect(builder.send(:supported_reference_set_selector?, selector, true, 'Demo.Page')).to be(false)
    selector['DataSource']['EntityPath'] = 'one/two'
    selector.merge!('$ID' => SecureRandom.uuid, '$Type' => 'Forms$ReferenceSetSelector',
                    'Columns' => [2], 'ControlBar' => {}, 'IsPagingEnabled' => false)
    expect(builder.send(:supported_reference_set_selector?, selector, true, 'Demo.Page')).to be(true)

    reference = { '$Type' => 'Forms$ReferenceSelector', 'AttributePath' => 'Demo.Item_Category/Name' }
    expect(builder.send(:supported_bound_widget?, reference, true)).to be(false)
    empty_target = { '$Type' => 'Forms$ReferenceSelector', 'AttributePath' => '/',
                     'SelectorSource' => { '$Type' => 'Forms$SelectorXPathSource' } }
    expect(builder.send(:supported_bound_widget?, empty_target, true)).to be(false)
    reference['SelectorSource'] = { '$Type' => 'Forms$SelectorMicroflowSource',
                                    'DataSourceMicroflowSettings' => {} }
    expect(builder.send(:supported_bound_widget?, reference, true)).to be(false)
    reference['SelectorSource']['DataSourceMicroflowSettings']['Microflow'] = 'Demo.Load'
    expect(builder.send(:supported_bound_widget?, reference, true)).to be(true)
    expect(builder.send(:supported_bound_widget?, { '$Type' => 'Forms$TextBox',
                                                    'AttributePath' => 'Demo.Item.Name' }, true)).to be(true)
  end
end
# rubocop:enable Metrics/BlockLength
