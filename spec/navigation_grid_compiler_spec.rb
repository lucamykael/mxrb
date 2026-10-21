# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::NavigationGridCompiler do
  let(:zero) { '00000000-0000-0000-0000-000000000000' }
  let(:source_type) do
    Struct.new(:units, :version) do
      def units_of(type) = units.select { _1.document['$Type'] == type }
      def web_page?(unit) = unit.document['Native'] != true
      def web_layout?(unit) = unit.document['Native'] != true
    end
  end

  def unit(type, name, document)
    Mxrb::Compiler::SourceModel::Unit.new(
      id: name, container_id: 'module', containment: 'Documents', module_name: 'App',
      document: { '$ID' => name, '$Type' => type, 'Name' => name }.merge(document)
    )
  end

  def text(id) = { '$ID' => id, '$Type' => 'Texts$Text', 'Items' => [3] }

  def column(name, attribute, aggregate: 'None', steps: nil)
    reference = attribute && { '$ID' => "#{name}-ref", '$Type' => 'DomainModels$AttributeRef',
                               'Attribute' => attribute, 'EntityRef' => steps && indirect(*steps) }
    { '$ID' => name, '$Type' => 'Forms$DataGridColumn', 'Name' => name, 'WidthValue' => 50, 'Editable' => false,
      'ShowTooltip' => false, 'AggregateFunction' => aggregate, 'Caption' => text("#{name}-caption"),
      'AggregateCaption' => text("#{name}-aggregate"), 'AttributeRef' => reference,
      'FormattingInfo' => { '$ID' => "#{name}-format", '$Type' => 'Forms$FormattingInfo', 'DecimalPrecision' => 2,
                            'GroupDigits' => false, 'EnumFormat' => 'Text', 'DateFormat' => 'Date',
                            'CustomDateFormat' => '' } }
  end

  def settings(id, form)
    { '$ID' => id, '$Type' => 'Forms$FormSettings', 'Form' => form, 'ParameterMappings' => [3], 'TitleOverride' => nil }
  end

  def microflow_settings(id, microflow)
    { '$ID' => id, '$Type' => 'Forms$MicroflowSettings', 'Microflow' => microflow, 'ProgressMessage' => nil,
      'ConfirmationInfo' => nil, 'ProgressBar' => 'None', 'Asynchronous' => false, 'FormValidations' => 'All',
      'ParameterMappings' => [3] }
  end

  def grid(name, data_source, **options)
    { '$ID' => name, '$Type' => options.fetch(:type, 'Forms$DataGrid'), 'Name' => name, 'TabIndex' => 0,
      'IsControlBarVisible' => true, 'SelectionMode' => 'Single', 'SelectFirst' => false,
      'DefaultButtonTrigger' => 'Double', 'RefreshTime' => 0, 'NumberOfRows' => 20, 'ShowEmptyRows' => false,
      'TooltipForm' => '', 'ShowPagingBar' => true, 'DataSource' => data_source,
      'Columns' => [3, *options.fetch(:columns, [])],
      'ControlBar' => control_bar(name, options.fetch(:buttons, []), options[:pointer]) }
      .merge(options.fetch(:extra, {}))
  end

  def control_bar(name, buttons, pointer)
    { '$ID' => "#{name}-bar", '$Type' => 'Forms$GridControlBar', 'NewButtons' => [3, *buttons],
      'DefaultButtonPointer' => pointer }
  end

  def xpath_source(id, reference, path: nil)
    { '$ID' => id, '$Type' => 'Forms$GridXPathSource', 'EntityRef' => reference, 'XPathConstraint' => '',
      'EntityPath' => path }.compact
  end

  def direct(entity) = { '$ID' => "direct-#{entity}", '$Type' => 'DomainModels$DirectEntityRef', 'Entity' => entity }

  def indirect(*steps)
    { '$ID' => 'indirect', '$Type' => 'DomainModels$IndirectEntityRef',
      'Steps' => [3, *steps.map do |association, entity|
        { 'Association' => association, 'DestinationEntity' => entity }
      end] }
  end

  def microflow(name, parameters: [], returns: nil)
    objects = parameters.map do |parameter, type|
      { '$ID' => "#{name}-#{parameter}", '$Type' => 'Microflows$MicroflowParameter', 'Name' => parameter,
        'VariableType' => type }
    end
    unit('Microflows$Microflow', name, 'ObjectCollection' => { 'Objects' => [3, *objects] },
                                       'MicroflowReturnType' => returns)
  end

  def attribute(name, type, key: 'NewType')
    { '$ID' => "attribute-#{name}", '$Type' => 'DomainModels$Attribute', 'Name' => name,
      key => { '$Type' => "DomainModels$#{type}AttributeType" } }
  end

  def entity(name, *attributes, dates: false)
    generalization = { '$Type' => 'DomainModels$NoGeneralization', 'Persistable' => true,
                       'HasCreatedDateAttr' => dates, 'HasChangedDateAttr' => dates }
    { '$ID' => "entity-#{name}", '$Type' => 'DomainModels$Entity', 'Name' => name, 'Attributes' => [3, *attributes],
      'MaybeGeneralization' => generalization }
  end

  def compile(units, version)
    schema = Mxrb::Compiler::RuntimeModelSchema.new(Mxrb::Compiler::ModelPackage.empty, version:)
    source = source_type.new(units, version)
    widgets = Mxrb::Compiler::WebWidgetInventory.new(source)
    described_class.new(schema, source, widgets).compile
  end

  let(:attributes) do
    [attribute('Number', 'String'), attribute('Total', 'Decimal'), attribute('Paid', 'Boolean'),
     attribute('Placed', 'DateTime'), attribute('Status', 'Enumeration'), attribute('Lines', 'Integer'),
     attribute('Weight', 'Long'), attribute('Serial', 'AutoNumber'), attribute('Pin', 'HashedString'),
     attribute('Legacy', 'String', key: 'Type'), { 'Name' => 'Typeless' }]
  end
  let(:domain) do
    unit('DomainModels$DomainModel', 'Domain',
         'Entities' => [3, entity('Order', *attributes, dates: true), entity('Line', attribute('Note', 'String'))])
  end
  let(:layouts) do
    [unit('Forms$Layout', 'Shell', 'Content' => { 'LayoutType' => 'Responsive' }),
     unit('Forms$Layout', 'Popup', 'Content' => { 'LayoutType' => 'ModalPopup' })]
  end
  let(:pages) do
    [unit('Forms$Page', 'Order_NewEdit', 'FormCall' => { 'Form' => 'App.Popup' }),
     unit('Forms$Page', 'Order_Overview', 'FormCall' => { 'Form' => 'App.Shell' }, 'Widgets' => [3, overview_grid])]
  end
  let(:overview_buttons) do
    [{ '$ID' => 'search', '$Type' => 'Forms$GridSearchButton' },
     { '$ID' => 'new', '$Type' => 'Forms$GridNewButton', 'Name' => 'newButton1', 'EditLocation' => 'Form',
       'Entity' => 'App.Order', 'FormSettings' => settings('new-settings', 'App.Order_NewEdit') },
     { '$ID' => 'edit', '$Type' => 'Forms$GridActionButton', 'Name' => 'editButton1',
       'Action' => { '$ID' => 'edit-action', '$Type' => 'Forms$FormAction', 'PagesForSpecializations' => [3],
                     'FormSettings' => settings('edit-settings', 'App.Order_Overview') } },
     { '$ID' => 'delete', '$Type' => 'Forms$GridActionButton', 'Name' => 'deleteButton1',
       'Action' => { '$ID' => 'delete-action', '$Type' => 'Forms$DeleteClientAction', 'ClosePage' => false,
                     'DisabledDuringExecution' => true } }]
  end
  let(:overview_columns) do
    paths = { 'number' => 'App.Order.Number', 'total' => 'App.Order.Total', 'paid' => 'App.Order.Paid',
              'placed' => 'App.Order.Placed', 'status' => 'App.Order.Status', 'lines' => 'App.Order.Lines',
              'weight' => 'App.Order.Weight', 'serial' => 'App.Order.Serial', 'pin' => 'App.Order.Pin',
              'legacy' => 'App.Order.Legacy', 'typeless' => 'App.Order.Typeless',
              'name' => 'System.FileDocument.Name', 'size' => 'System.FileDocument.Size', 'nothing' => nil,
              'unknown' => 'App.Order.Missing' }
    paths.map { |name, path| column(name, path, aggregate: name == 'total' ? 'Sum' : 'None') } +
      [column('created', 'App.Order.createdDate'), column('changed', 'App.Order.changedDate'),
       column('note', 'App.Line.Note', steps: [%w[App.Order_Line App.Line]]),
       column('owner', 'System.User.Name', steps: [%w[App.Order_Line App.Line], %w[System.owner System.User]])]
  end
  let(:overview_grid) do
    grid('grid1', xpath_source('grid1-source', direct('App.Order')), pointer: 'edit', buttons: overview_buttons,
                                                                     columns: overview_columns)
  end

  it 'compiles the data grids of the web documents with the entity, paths and column kinds MxBuild writes' do
    grids = compile([domain, *layouts, *pages], '11.12.1')

    expect(grids.length).to eq(1)
    grid = grids.first
    expect(grid.keys).to eq(
      %w[$ID $Type ControlBar Columns Name TabIndex Entity IsControlBarVisible SelectionMode SelectFirst
         DefaultButtonTrigger RefreshTime NumberOfRows ShowEmptyRows TooltipForm]
    )
    expect(grid).to include('$ID' => 'grid1', 'Entity' => 'App.Order', 'Name' => 'grid1', 'NumberOfRows' => 20)
    expect(grid['ControlBar']).to include('DefaultButtonPointer' => 'edit')
    search, new_button, edit, delete = grid.dig('ControlBar', 'NewButtons')
    expect(search).to eq('$ID' => 'search', '$Type' => 'Forms$GridSearchButton')
    expect(new_button).to eq(
      '$ID' => 'new', '$Type' => 'Forms$GridNewButton', 'Entity' => 'App.Order', 'EditLocation' => 'Form',
      'FormSettings' => { '$ID' => 'new-settings', '$Type' => 'Forms$FormSettings', 'TitleOverride' => nil,
                          'ParameterMappings' => [], 'Form' => 'App.Order_NewEdit', 'Location' => 'ModalPopup' }
    )
    expect(edit.dig('Action', 'FormSettings')).to include('Location' => 'Content')
    expect(edit.dig('Action', 'PagesForSpecializations')).to eq([])
    expect(delete['Action']).to eq('$ID' => 'delete-action', '$Type' => 'Forms$DeleteClientAction',
                                   'ClosePage' => false)

    kinds = grid['Columns'].to_h { [_1['AttributePath'], _1['ColumnKindString']] }
    expect(kinds).to eq(
      'App.Order.Number' => 'String', 'App.Order.Total' => 'Decimal', 'App.Order.Paid' => 'Boolean',
      'App.Order.Placed' => 'DateTime', 'App.Order.Status' => 'Enumeration', 'App.Order.Lines' => 'Integer',
      'App.Order.Weight' => 'Integer', 'App.Order.Serial' => 'Integer', 'App.Order.Pin' => 'String',
      'App.Order.Legacy' => 'String', 'App.Order.Typeless' => 'String', 'System.FileDocument.Name' => 'String',
      'System.FileDocument.Size' => 'Integer', '' => 'String', 'App.Order.Missing' => 'String',
      'App.Order.createdDate' => 'DateTime', 'App.Order.changedDate' => 'DateTime',
      'App.Order_Line/App.Line/App.Line.Note' => 'String',
      'App.Order_Line/App.Line/System.owner/System.User/System.User.Name' => 'String'
    )
    total = grid['Columns'][1]
    expect(total.keys).to eq(
      %w[$ID $Type Caption FormattingInfo AggregateCaption AttributePath ColumnKindString ShowTooltip AggregateFunction
         Editable]
    )
    expect(total).to include('AggregateFunction' => 'Sum',
                             'Caption' => { '$ID' => 'total-caption',
                                            '$Type' => 'Texts$Text' })
    expect(total['FormattingInfo']).to eq(
      '$ID' => 'total-format', '$Type' => 'Forms$FormattingInfo', 'DecimalPrecision' => 2, 'GroupDigits' => false,
      'EnumFormat' => 'Text', 'DateFormat' => 'Date', 'CustomDateFormat' => ''
    )
  end

  it 'lists grids in the order of the units and the widget tree, web documents only, with button defaults' do
    select_all = { '$ID' => 'select-all', '$Type' => 'Forms$GridSelectAllButton' }
    deselect = { '$ID' => 'deselect', '$Type' => 'Forms$GridDeselectAllButton' }
    excel = { '$ID' => 'excel', '$Type' => 'Forms$DataGridExportToExcelButton', 'MaxNumberOfRows' => 50 }
    csv = { '$ID' => 'csv', '$Type' => 'Forms$DataGridExportToCSVButton' }
    list_button = { '$ID' => 'list', '$Type' => 'Forms$GridActionButton',
                    'Action' => { '$ID' => 'list-action', '$Type' => 'Forms$MicroflowAction',
                                  'MicroflowSettings' => microflow_settings('list-settings', 'App.Ship') } }
    object_button = { '$ID' => 'object', '$Type' => 'Forms$GridActionButton',
                      'Action' => { '$ID' => 'object-action', '$Type' => 'Forms$MicroflowAction',
                                    'MicroflowSettings' => microflow_settings('object-settings', 'App.Show') } }
    unknown_button = { '$ID' => 'unknown', '$Type' => 'Forms$GridActionButton',
                       'Action' => { '$ID' => 'unknown-action', '$Type' => 'Forms$MicroflowAction',
                                     'MicroflowSettings' => microflow_settings('unknown-settings', 'App.Gone') } }
    layout_grid = grid('layoutGrid', xpath_source('layout-source', indirect(%w[App.Order_Line App.Line])),
                       buttons: [select_all, deselect, excel, csv, list_button, object_button, unknown_button])
    snippet_grid = grid('snippetGrid', { '$ID' => 'snippet-source', '$Type' => 'Forms$MicroflowSource',
                                         'MicroflowSettings' => microflow_settings('ds', 'App.Orders') })
    unknown_grid = grid('unknownGrid', { '$ID' => 'unknown-source', '$Type' => 'Forms$MicroflowSource',
                                         'MicroflowSettings' => microflow_settings('ds2', 'App.Gone') })
    legacy_grid = grid('legacyGrid', xpath_source('legacy-source', nil, path: 'App.Order_Line/App.Line'))
    empty_grid = grid('emptyGrid', xpath_source('empty-source', indirect))
    nested = { '$ID' => 'container', '$Type' => 'Forms$DivContainer', 'Widgets' => [3, unknown_grid, legacy_grid] }
    units = [
      unit('Forms$Layout', 'Shell', 'Content' => { 'LayoutType' => 'Responsive' }, 'Widgets' => [3, layout_grid]),
      unit('Forms$Snippet', 'Card', 'Type' => 'Web', 'Widgets' => [3, snippet_grid]),
      unit('Forms$Snippet', 'Tile', 'Type' => 'Native', 'Widgets' => [3, grid('nativeSnippetGrid', {})]),
      unit('Forms$Page', 'Native', 'Native' => true, 'Widgets' => [3, grid('nativeGrid', {})]),
      unit('Forms$Page', 'Home', 'FormCall' => { 'Form' => 'App.Shell' }, 'Widgets' => [3, nested, empty_grid]),
      microflow('Ship', parameters: [['Orders', { '$Type' => 'DataTypes$ListType', 'Entity' => 'App.Order' }]]),
      microflow('Show', parameters: [['Order', { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'App.Order' }]]),
      microflow('Orders', returns: { '$Type' => 'DataTypes$ListType', 'Entity' => 'App.Order' }),
      domain
    ]

    grids = compile(units, '11.12.1')

    expect(grids.map { [_1['Name'], _1['Entity']] }).to eq(
      [['layoutGrid', 'App.Line'], ['snippetGrid', 'App.Order'], ['unknownGrid', ''], ['legacyGrid', 'App.Line'],
       ['emptyGrid', '']]
    )
    expect(grids.map { _1.dig('ControlBar', 'DefaultButtonPointer') }).to all(eq(zero))
    buttons = grids.first.dig('ControlBar', 'NewButtons')
    expected_defaults = [
      { '$ID' => 'select-all', '$Type' => 'Forms$GridSelectAllButton', 'SelectionType' => 'SelectPage' },
      { '$ID' => 'deselect', '$Type' => 'Forms$GridDeselectAllButton' },
      { '$ID' => 'excel', '$Type' => 'Forms$DataGridExportToExcelButton', 'MaxNumberOfRows' => 50,
        'UseExcelDateType' => true },
      { '$ID' => 'csv', '$Type' => 'Forms$DataGridExportToCSVButton', 'MaxNumberOfRows' => 1000,
        'DecimalSeparator' => '.', 'GroupSeparator' => ',', 'Delimiter' => ';', 'GenerateExcelHint' => false,
        'UseGridDateFormat' => false }
    ]
    expect(buttons.first(4)).to eq(expected_defaults)
    list, object, unknown = buttons.last(3).map { _1.dig('Action', 'MicroflowSettings') }
    expect(list).to eq(
      '$ID' => 'list-settings', '$Type' => 'Forms$MicroflowSettings', 'ProgressMessage' => nil,
      'ConfirmationInfo' => nil, 'Microflow' => 'App.Ship', 'ProgressBar' => 'None', 'Asynchronous' => false,
      'FormValidations' => 'All', 'ExpectListArgument' => true
    )
    expect(object).to include('Microflow' => 'App.Show', 'ExpectListArgument' => false)
    expect(unknown).to include('Microflow' => 'App.Gone', 'ExpectListArgument' => false)
  end

  let(:template_extra) { { 'NumberOfColumns' => 2, 'Contents' => { 'Widgets' => [3] } } }
  let(:selector_buttons) do
    [{ '$ID' => 'add', '$Type' => 'Forms$DataGridAddButton',
       'FormSettings' => settings('add-settings', 'App.Order_NewEdit') },
     { '$ID' => 'remove', '$Type' => 'Forms$DataGridRemoveButton' },
     { '$ID' => 'select', '$Type' => 'Forms$DataGridSelectButton' }]
  end

  it 'compiles template grids and reference set selectors with the Mendix 10 schema' do
    template = grid('templateGrid', xpath_source('template-source', direct('App.Order')), type: 'Forms$TemplateGrid',
                                                                                          extra: template_extra)
    selector = grid('selector', { '$ID' => 'selector-source', '$Type' => 'Forms$ReferenceSetSource',
                                  'EntityRef' => indirect(%w[App.Order_Line App.Line]) },
                    type: 'Forms$ReferenceSetSelector', extra: { 'SelectableXPathConstraint' => '[Paid = true()]' },
                    buttons: selector_buttons)
    units = [domain, *layouts, *pages.first(1),
             unit('Forms$Page', 'Home', 'FormCall' => { 'Form' => 'App.Shell' }, 'Widgets' => [3, template, selector])]

    template_grid, selector_grid = compile(units, '10.24.0.73019')

    expect(template_grid).to eq(
      '$ID' => 'templateGrid', '$Type' => 'Forms$TemplateGrid', 'Name' => 'templateGrid', 'TabIndex' => 0,
      'Entity' => 'App.Order', 'IsControlBarVisible' => true, 'SelectionMode' => 'Single', 'SelectFirst' => false,
      'DefaultButtonTrigger' => 'Double', 'RefreshTime' => 0, 'NumberOfRows' => 20, 'NumberOfColumns' => 2,
      'ControlBar' => { '$ID' => 'templateGrid-bar', '$Type' => 'Forms$GridControlBar', 'NewButtons' => [],
                        'DefaultButtonPointer' => zero }
    )
    expect(selector_grid.keys).to eq(
      %w[$ID $Type ControlBar Columns Name TabIndex Entity IsControlBarVisible SelectionMode SelectFirst
         DefaultButtonTrigger RefreshTime NumberOfRows ShowEmptyRows TooltipForm SelectableXPathConstraint]
    )
    expect(selector_grid).to include('Entity' => 'App.Line', 'SelectableXPathConstraint' => '[Paid = true()]')
    add, remove, select = selector_grid.dig('ControlBar', 'NewButtons')
    expect(add).to eq(
      '$ID' => 'add', '$Type' => 'Forms$DataGridAddButton',
      'FormSettings' => { '$ID' => 'add-settings', '$Type' => 'Forms$FormSettings', 'TitleOverride' => nil,
                          'ParameterMappings' => [], 'Form' => 'App.Order_NewEdit', 'Location' => 'ModalPopup' }
    )
    expect(remove).to eq('$ID' => 'remove', '$Type' => 'Forms$DataGridRemoveButton')
    expect(select).to eq('$ID' => 'select', '$Type' => 'Forms$DataGridSelectButton')
  end
end
# rubocop:enable Metrics/BlockLength
