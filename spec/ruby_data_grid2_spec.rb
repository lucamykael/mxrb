# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Data grid 2 in the Ruby application' do # rubocop:disable Metrics/BlockLength
  def object_type(id, keys, nested = {})
    types = keys.map do |key|
      value_type = nested.key?(key) ? { 'ObjectType' => nested.fetch(key) } : {}
      { '$ID' => "#{id}-#{key}", 'PropertyKey' => key, 'ValueType' => value_type }
    end
    { '$ID' => id, 'PropertyTypes' => [2, *types] }
  end

  def widget_object(type, values)
    properties = values.map { |key, value| { 'TypePointer' => "#{type.fetch('$ID')}-#{key}", 'Value' => value } }
    { 'Properties' => [2, *properties] }
  end

  def primitive(value) = { 'PrimitiveValue' => value }

  def placeholder(name) = { '$Type' => 'Forms$Placeholder', 'Name' => name }

  def filter_widget(id, default = nil)
    type = object_type('filter', %w[defaultFilter])
    { 'Widgets' => [2, { 'Type' => { 'WidgetId' => id, 'ObjectType' => type },
                         'Object' => widget_object(type, default ? { 'defaultFilter' => primitive(default) } : {}) }] }
  end

  def official_filter(name, default = nil)
    filter_widget("com.mendix.widget.web.datagrid#{name.downcase}filter.Datagrid#{name}Filter", default)
  end

  def attribute(name) = { 'AttributeRef' => { 'Attribute' => name } }

  let(:column_type) do
    object_type('column', %w[header attribute showContentAs dynamicText content filter sortable hidable width
                             size alignment])
  end
  let(:grid_type) do
    object_type('grid', %w[datasource columns pageSize itemSelection onClickTrigger filtersPlaceholder],
                'columns' => column_type)
  end

  def column(values)
    widget_object(column_type, values)
  end

  def template(text, parameters = [])
    { '$Type' => 'Forms$ClientTemplate', 'Template' => { 'Items' => [3, { 'Text' => text }] },
      'Parameters' => [2, *parameters] }
  end

  def header(text) = { 'TextTemplate' => template(text) }

  def raw_grid(columns, source: {}, **values)
    properties = {
      'datasource' => { 'DataSource' => { 'EntityRef' => { 'Entity' => 'Admin.Account' } }.merge(source) },
      'columns' => { 'Objects' => [2, *columns] }
    }.merge(values)
    { 'Name' => 'accounts', 'Type' => { 'ObjectType' => grid_type }, 'Object' => widget_object(grid_type, properties) }
  end

  let(:roles_path) do
    step = { 'Association' => 'System.UserRoles', 'DestinationEntity' => 'System.UserRole' }
    { 'AttributeRef' => { 'Attribute' => 'System.UserRole.Name', 'EntityRef' => { 'Steps' => [2, step] } } }
  end

  let(:columns) do
    [
      column('header' => header('Full name'), 'attribute' => attribute('Admin.Account.FullName'),
             'filter' => official_filter('Text', 'contains'), 'size' => primitive('2'),
             'alignment' => primitive('right')),
      column('header' => header('Roles'), 'attribute' => roles_path, 'filter' => official_filter('Dropdown'),
             'sortable' => primitive('false'), 'hidable' => primitive('hidden')),
      column('header' => header('Last login'), 'showContentAs' => primitive('dynamicText'),
             'dynamicText' => { 'TextTemplate' => template('Seen {1}', [attribute('System.User.LastLogin')]) },
             'filter' => filter_widget('com.example.Unknown'), 'width' => primitive('manual'),
             'size' => primitive('120')),
      column('header' => header('Actions'), 'showContentAs' => primitive('customContent'),
             'content' => { 'Widgets' => [2, placeholder('edit')] }, 'filter' => { 'Widgets' => [2, 'raw'] },
             'hidable' => primitive('no'), 'width' => primitive('autoFit'), 'alignment' => primitive('left'))
    ]
  end

  let(:model) do
    sort = [attribute('Admin.Account.FullName').merge('SortOrder' => 'Descending'),
            attribute('Admin.Account.Email'), { 'SortOrder' => 'Ascending' }]
    source = { 'XPathConstraint' => " [Name != empty]\n", 'SortBar' => { 'SortItems' => [2, *sort] } }
    Mxrb::Model::Page.allocate.send(
      :data_grid2_widget,
      raw_grid(columns, source:, 'onClickTrigger' => primitive('double'),
                        'filtersPlaceholder' => { 'Widgets' => [2, placeholder('new')] })
    )
  end

  def stringify(value) = JSON.parse(JSON.generate(value))

  it 'projects the datasource, header and every column kind of a Data grid 2' do
    options = model.fetch(:options)
    expect(options).to include(entity: 'Admin.Account', xpath: '[Name != empty]', on_click_trigger: 'double',
                               sort: [{ attribute: 'Admin.Account.FullName', direction: 'Descending' },
                                      { attribute: 'Admin.Account.Email', direction: 'Ascending' }])
    expect(model.fetch(:header)).to eq([{ type: :placeholder, name: 'new', options: { parameter: 'new' }, events: [] }])
    full_name, roles, last_login, actions = options.fetch(:columns)
    expect(full_name).to eq(name: 'Full name', caption: 'Full name', attribute: 'Admin.Account.FullName',
                            filter: { type: 'text', operator: 'contains' }, size: 2, alignment: 'right')
    expect(roles).to eq(name: 'Roles', caption: 'Roles', attribute: 'System.UserRole.Name',
                        association_path: [{ association: 'System.UserRoles', entity: 'System.UserRole' }],
                        filter: { type: 'drop_down' }, sortable: false, hidable: 'hidden')
    expect(last_login).to eq(name: 'Last login', caption: 'Last login', dynamic_text: 'Seen {1}',
                             parameters: ['$currentObject/LastLogin'], width: 'manual', size: 120)
    expect(actions).to eq(name: 'Actions', caption: 'Actions', hidable: false, width: 'auto_fit',
                          content: [{ type: :placeholder, name: 'edit', options: { parameter: 'edit' }, events: [] }])

    grid = raw_grid([column('showContentAs' => primitive('dynamicText'))], 'onClickTrigger' => primitive('single'))
    plain = Mxrb::Model::Page.allocate.send(:data_grid2_widget, grid)
    expect(plain.fetch(:options)).not_to include(:xpath, :sort, :on_click_trigger)
    expect(plain.dig(:options, :columns)).to eq([{ name: '', caption: '', dynamic_text: '' }])
    expect(plain).not_to have_key(:header)
  end

  it 'declares the projection with the data grid DSL' do
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    builder.instance_eval do
      data_grid 'accounts', entity: 'Admin.Account', xpath: '[Name != empty]', on_click_trigger: 'double',
                            sort: [sort_by('Admin.Account.FullName')] do
        header { placeholder 'new', parameter: 'new' }
        column 'Roles', attribute: 'System.UserRole.Name', association_path: [%w[System.UserRoles System.UserRole]],
                        filter: grid_filter(:drop_down), hidable: 'hidden'
        column 'Owner', association_path: [{ 'association' => 'Admin.Owner', entity: :'Admin.User' }]
        column 'Actions', width: :auto_fit, alignment: :right, size: 1 do
          placeholder 'edit', parameter: 'edit'
        end
      end
    end
    grid = builder.widgets.first
    expect(grid.dig(:options, :xpath)).to eq('[Name != empty]')
    expect(grid.fetch(:header)).to eq([{ type: :placeholder, name: 'new', options: { parameter: 'new' }, events: [] }])
    roles, owner, actions = grid.dig(:options, :columns)
    expect(roles).to include(association_path: [{ association: 'System.UserRoles', entity: 'System.UserRole' }],
                             filter: { type: 'drop_down' })
    expect(owner.fetch(:association_path)).to eq([{ association: 'Admin.Owner', entity: 'Admin.User' }])
    expect(actions).to include(width: 'auto_fit', alignment: 'right', size: 1)
    expect(actions.fetch(:content).first).to include(type: :placeholder, name: 'edit')
    expect(builder.grid_filter('text', operator: :contains)).to eq(type: 'text', operator: 'contains')
    expect { builder.data_grid('bad', mystery: true) }.to raise_error(ArgumentError, /mystery/)
  end

  it 'exports the projection as typed DSL that evaluates to the same widget' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    widget = stringify(model.merge(events: [{ event: :on_click, kind: :page, handler: 'Admin.Account_Edit' }]))
    expect(exporter.send(:runtime_data_grid_supported?, :data_grid, widget.fetch('options'), widget)).to be(true)
    source = exporter.send(:runtime_data_grid_source, widget, 0)
    expect(source).to include('sort: [sort_by("Admin.Account.FullName", direction: "Descending")',
                              'filter: grid_filter(:text, operator: :contains)', 'filter: grid_filter(:drop_down)',
                              'association_path: [["System.UserRoles", "System.UserRole"]]', '  header do')
    expect(source).not_to include('=>')
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    builder.instance_eval(source)
    expect(stringify(builder.widgets.first)).to eq(widget)

    empty = stringify(type: :data_grid, name: 'g', options: { columns: [{ name: 'c', content: [] }] }, events: [])
    rebuilt = Mxrb::Dsl::WidgetSlotBuilder.new.tap { _1.instance_eval(exporter.send(:runtime_data_grid_source, empty, 0)) }
    expect(stringify(rebuilt.widgets.first)).to eq(empty)
  end

  it 'keeps data grids the typed DSL cannot express generic' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    supported = lambda do |widget|
      value = stringify(widget)
      exporter.send(:runtime_data_grid_supported?, :data_grid, value.fetch('options'), value)
    end
    grid = ->(columns, **extra) { { type: :data_grid, name: 'g', options: { columns: }, events: [] }.merge(extra) }
    expect(supported.call(grid.call([{ name: 'c', association_path: [{ association: 'A.b', entity: 'A.C', x: 1 }] }])))
      .to be(false)
    expect(supported.call(grid.call([{ name: 'c', association_path: [{ association: 'A.b', entity: 1 }] }])))
      .to be(false)
    expect(supported.call(grid.call([{ name: 'c', association_path: 'A.b' }]))).to be(false)
    expect(supported.call(grid.call([{ name: 'c', content: [{ name: 'x' }] }]))).to be(false)
    expect(supported.call(grid.call([{ attribute: 'A.B.c' }]))).to be(false)
    expect(supported.call(grid.call([], header: [{ name: 'x' }]))).to be(false)
    expect(supported.call(grid.call([], header: []))).to be(true)
    expect(exporter.send(:runtime_nested_widget_supported?, stringify(grid.call([], header: [{ name: 'x' }]))))
      .to be(false)

    { { 'type' => 'text', 'operator' => 1 } => nil, { 'type' => 1 } => nil, { 'kind' => 'text' } => nil, 'text' => nil,
      { 'type' => 'date' } => 'grid_filter(:date)' }.each do |filter, expected|
      expect(exporter.send(:runtime_grid_filter_expression, filter)).to eq(expected)
    end
    literal = stringify(grid.call([{ name: 'c', filter: 'text' }]))
    expect(exporter.send(:runtime_data_grid_source, literal, 0)).to include('filter: "text"')
  end

  # The store calls synchronize_roles makes, over in-memory UserRole objects.
  def role_store
    role = Data.define(:id, :members)
    Class.new do
      attr_reader :commits

      define_method(:initialize) { (@objects = []) && (@commits = 0) }
      define_method(:retrieve) { |_entity| @objects.dup }
      define_method(:create) { |_entity| role.new(@objects.size.to_s, {}).tap { @objects << _1 } }
      define_method(:commit) { |_object| @commits += 1 }
    end.new
  end

  it 'grants each user role the roles it manages' do
    store = role_store
    definitions = [{ name: 'Administrator', guid: 'admin', manageable: %w[Administrator User] },
                   { name: 'User', guid: 'user', manageable: [] }, { name: 'Legacy', guid: 'legacy' }]
    grants = lambda do
      store.retrieve('System.UserRole').to_h do |object|
        [object.members['Name'], Array(object.members['grantableRoles']).map { _1.members['Name'] }.sort]
      end
    end
    Mxrb::Runtime::SystemDomain.synchronize_roles(store, definitions)
    expect(grants.call).to eq('Administrator' => %w[Administrator User], 'User' => [], 'Legacy' => [])
    commits = store.commits
    Mxrb::Runtime::SystemDomain.synchronize_roles(store, definitions)
    expect(store.commits).to eq(commits)
    definitions[1][:manageable] = ['User']
    Mxrb::Runtime::SystemDomain.synchronize_roles(store, definitions)
    expect(grants.call['User']).to eq(['User'])
  end

  it 'reads the manageable roles of the project security' do
    project = double('project')
    control = Mxrb::Runtime::AccessControl.allocate
    control.instance_variable_set(:@project, project)
    roles = [{ 'Name' => 'Administrator', 'ManageAllRoles' => true },
             { 'Name' => 'Manager', 'ManageableRoles' => [1, 'User'] }, { 'Name' => 'User' }]
    control.instance_variable_set(:@security, 'UserRoles' => [3, *roles])
    expect(control.user_role_definitions.map { _1.fetch(:manageable) })
      .to eq([%w[Administrator Manager User], ['User'], []])
  end
end
