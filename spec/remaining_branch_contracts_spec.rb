# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../lib/mxrb/studio_schema_catalog'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'remaining defensive branch contracts' do
  it 'normalizes record rename signatures and non-native array markers' do
    identity = Mxrb::RubyApp::RecordIdentity.allocate
    expect(identity.send(:rename_signature, :associations, 'App.Order_Customer', nil))
      .to eq('Order_Customer')
    expect(identity.send(:rename_signature, :lifecycle, :before_commit, nil)).to eq('before_commit')
    expect(identity.send(:rename_signature, :future, :value, nil)).to be_nil

    compatibility = Mxrb::StudioCompatibility.allocate
    expect(compatibility.send(:array_marker, ['value'])).to be_nil
  end

  it 'rejects scalar native fragments and cleans failed temporary writes' do
    Dir.mktmpdir('mxrb-fragment-branches-') do |dir|
      store = Mxrb::NativeFragmentStore.new(dir)
      payload = Mxrb::IO::BsonCodec.serialize('value' => 'scalar')
      digest = Digest::SHA256.hexdigest(payload)
      File.binwrite(File.join(dir, "#{digest}.bson"), payload)
      allow(Mxrb::IO::BsonCodec).to receive(:parse).with(payload).and_return('scalar')
      expect { store.fetch(digest) }
        .to raise_error(Mxrb::ValidationError, /is not a document/)

      allow(File).to receive(:rename).and_raise(IOError, 'blocked')
      expect { store.put('Future' => true) }.to raise_error(IOError, /blocked/)
      expect(Dir.glob(File.join(dir, '*.tmp-*'))).to be_empty
    end
  end

  it 'rejects duplicate page identities and restores only applicable design properties' do
    duplicate_manifest = double(modules: [{ 'pages' => [{ 'id' => 'same' }, { 'id' => 'same' }] }])
    expect { Mxrb::RubyApp::PageDesignIdentity.new(duplicate_manifest) }
      .to raise_error(Mxrb::ValidationError, /duplicate private page identity/)

    manifest = double(modules: [{ 'pages' => [{
      'id' => 'page-id', 'widgets' => [{
        'type' => 'data_view', 'name' => 'Details',
        'options' => { 'design_properties' => [{
          'key' => 'Color', 'option' => 'Red', 'id' => 'old-id', 'value_id' => 'old-value'
        }] }
      }]
    }] }])
    identity = Mxrb::RubyApp::PageDesignIdentity.new(manifest)
    untouched = [{ 'type' => 'data_view', 'name' => 'Details', 'options' => {} }]
    expect(identity.restore('missing', untouched)).to equal(untouched)
    expect(identity.restore('page-id', untouched)).to eq(untouched)

    declarations = [
      { 'future' => true },
      { 'key' => 'Color', 'option' => 'Blue' },
      { 'key' => 'RenamedColor', 'option' => 'Green', 'id' => 'old-id' }
    ]
    expect do
      identity.send(
        :resolve_properties,
        [{ 'key' => 'Color', 'option' => 'Red', 'id' => 'old-id', 'value_id' => 'old-value' }],
        declarations
      )
    end.to raise_error(Mxrb::ValidationError, /duplicate design property identity claim/)
  end

  it 'classifies schema references and rejects cycles and malformed fields' do
    catalog = Mxrb::StudioSchemaCatalog.allocate
    expect(catalog.send(:reference_kind, 'x.localByNameReference(y)')).to eq('by_name')
    expect(catalog.send(:reference_kind, 'x.byNameReference(y)')).to eq('by_name')
    expect(catalog.send(:reference_kind, 'x.byIdReference(y)')).to eq('by_id')
    expect(catalog.send(:reference_kind, 'x.Reference(y)')).to eq('reference')
    expect(catalog.send(:reference_kind, 'x.string()')).to be_nil
    types = {
      'A' => { base: 'B', properties: [] },
      'B' => { base: 'A', properties: [] }
    }
    expect { catalog.send(:inherited_properties, 'A', types) }
      .to raise_error(ArgumentError, /cyclic Studio schema inheritance/)
    expect { catalog.send(:split_key_value, 'missing-separator') }
      .to raise_error(ArgumentError, /invalid Studio schema field/)
  end

  it 'reconstructs data-source expressions with expression arguments and optional flags' do
    sources = Mxrb::RubyApp::PageDataSources
    variable = { 'kind' => 'widget', 'name' => 'Grid', 'sub_key' => 'row', 'use_all_pages' => true }
    association = {
      'kind' => 'association', 'entity' => 'App.Customer',
      'steps' => [{ 'association' => 'App.Order_Customer', 'entity' => 'App.Customer' }],
      'variable' => variable, 'force_full_objects' => false
    }
    expect(sources.send(:association_expression, association).source).to include('from: page_variable(')
    expect(sources.send(:association_expression,
                        association.merge('variable' => { 'kind' => 1 }))).to be_nil

    flow = {
      'kind' => 'microflow', 'name' => 'App.Load',
      'mappings' => [{ 'parameter' => 'Input', 'variable' => variable }],
      'settings_native' => { 'UseAllPages' => true }, 'force_full_objects' => true
    }
    expect(sources.send(:flow_expression, flow).source)
      .to include('microflow_source(', 'force_full_objects: true')
    expect(sources.send(:flow_expression, flow.merge('name' => ''))).to be_nil
    expect(sources.send(:flow_expression, flow.merge('unexpected' => true))).to be_nil

    expression_type = sources.const_get(:Expression, false)
    nested = expression_type.new(source: 'page_variable(:Grid)', value: { name: 'Grid' })
    rendered = sources.send(:expression, :page_variable, [nested], sub_key: nested)
    expect(rendered.source).to include('page_variable(:Grid)', 'sub_key: page_variable(:Grid)')
  end

  it 'covers pluggable codec schema restoration and empty source-variable encoding' do
    forms_codec = double
    codec = Mxrb::Pluggable::MprCodec.new(forms_codec:)
    object_type = double
    allow(object_type).to receive(:property).and_return(true)
    definition = double(object_type:)
    expect(codec.send(:with_legacy_outer_properties, definition, 'AttributePath' => 'App.Item.Name'))
      .to equal(definition)

    generated = { '$Type' => 'Future$Schema', '$ID' => nil, 'Present' => true }
    codec.send(:restore_schema_hash!, generated, { 'Missing' => true }, {})
    expect(generated).to eq({})

    source = double(entity: nil, constraint: nil, sort_bar: nil,
                    force_full_objects: false, source_variable: nil)
    document = {}
    codec.send(:encode_data_source, document, source, path: '$.Source')
    expect(document).to be_empty
  end

  it 'covers Forms codec optional typed values and absent reference metadata' do
    codec = Mxrb::Forms::MprCodec.new
    text_template = Mxrb::Forms::TextTemplate.build('Hello', parameters: ['$name'])
    condition = Mxrb::Forms::Condition.when_value('Open', visible: true)
    binary = Mxrb::Forms::BinaryAsset.from_bytes('bytes')
    expect(codec.send(:encode_one, nil, text_template, path: '$')).to include('$Type')
    expect(codec.send(:encode_one, nil, condition, path: '$')).to include('AttributeValue' => 'Open')
    expect(codec.send(:encode_one, nil, binary, path: '$')).to be_a(BSON::Binary)

    decoded = codec.send(
      :decode_text,
      { '$Type' => 'Texts$Text', 'Items' => [2, { 'LanguageCode' => nil, 'Text' => 'Fallback' }] },
      path: '$.Text'
    )
    expect(decoded.translations.first.language).to be_nil
    expect(codec.send(:decode_data_type, { '$Type' => 'DataTypes$StringType' }, path: '$'))
      .to eq(Mxrb::Forms::DataType.build('String', nil))
    property = double(type_name: 'OtherEnum')
    expect(codec.send(:legacy_enum_value, property, true)).to be(true)
    variable = codec.send(:decode_legacy_source_variable, '')
    expect(variable.fetch(:page_parameter)).to be_nil
    expect(codec.send(:encode_data_type, Mxrb::Forms::DataType.build('Object', nil)))
      .not_to have_key('Entity')
  end

  it 'covers page projection native fallbacks and nonempty optional structures' do
    page = Mxrb::Model::Page.allocate
    invalid_property = { '$Type' => 'Future$DesignProperty', 'Value' => {} }
    expect(page.send(:design_property_spec, invalid_property)).to equal(invalid_property)
    compound = {
      '$Type' => 'Forms$DesignPropertyValue', 'Key' => 'Outer',
      'Value' => {
        '$Type' => 'Forms$CompoundDesignPropertyValue',
        'Properties' => [2, invalid_property]
      }
    }
    expect(page.send(:design_property_spec, compound)).to equal(compound)
    expect(page.send(:unknown_native_fields, 'future', [])).to eq({})
    expect(page.send(:pluggable_value,
                     { 'EntityRef' => { 'Entity' => 'App.Item' } }, { 'Type' => 'Association' }))
      .to eq('App.Item')
    expect(page.send(:parse_source, 'future')).to be_nil

    settings = page.send(
      :data_view_microflow_settings,
      'Future' => true, 'OutputMappings' => [2, { 'Mapping' => true }]
    )
    expect(settings).to include('Future' => true, 'OutputMappings' => [2, { 'Mapping' => true }])

    grid = page.send(
      :layout_grid_widget,
      '$Type' => 'Forms$LayoutGrid', 'Name' => 'Grid', 'Width' => 'FixedWidth', 'Rows' => [2]
    )
    expect(grid.dig(:options, :width)).to eq(:fixed)
    native_root = {
      '$Type' => 'Forms$DataView',
      'DataSource' => { '$Type' => 'Forms$FutureSource' }
    }
    expect(page.send(:canonical_root_data_source, [native_root])).to be_nil
  end

  it 'validates pluggable property builder inputs and block styles' do
    bridge = Mxrb::RubyApp::PluggableProperties.allocate
    object_builder = Mxrb::RubyApp::PluggableProperties::ObjectValueBuilder.new(bridge)
    value = object_builder.evaluate { |builder| builder.set(:name, 'One') }
    expect(value.assignments).to eq([%w[name One]])
    expect { object_builder.set(:name, 'Two') }
      .to raise_error(ArgumentError, /duplicate object property/)

    list = Mxrb::RubyApp::PluggableProperties::ObjectListBuilder.new(bridge)
    expect { list.object }.to raise_error(ArgumentError, /requires a block/)
    list.object { |builder| builder.set(:name, 'One') }
    expect(list.build.objects.length).to eq(1)
    expect { bridge.objects }.to raise_error(ArgumentError, /requires a block/)
    expect(bridge.objects { |builder| builder.object { |item| item.set(:name, 'One') } }.objects.length)
      .to eq(1)
    expect { bridge.action(kind: '', handler: '') }.to raise_error(ArgumentError, /must not be empty/)
    expect { bridge.data_source(entity: '') }.to raise_error(ArgumentError, /must not be empty/)
    expect { bridge.send(:canonical_sort_item, [:only]) }
      .to raise_error(ArgumentError, /Array of pairs/)
    expect(bridge.send(:bridge_value, double, nil)).to be_nil
    expect { bridge.send(:image_reference, 123) }
      .to raise_error(TypeError, /String or Image reference/)
  end

  it 'covers legacy service migration syntax-tree guards' do
    migration = Mxrb::RubyApp::LegacyServiceSourceMigration.new(
      path: 'app/services/app/broken.rb', source: 'def broken('
    )
    expect(migration.migrate).to eq('def broken(')
    migration = Mxrb::RubyApp::LegacyServiceSourceMigration.new(path: 'x', source: '')
    expect(migration.send(:visit, :scalar, service: false, method: false)).to be_nil
    expect(migration.send(:call_identifier, :scalar)).to be_nil
    expect(migration.send(:first_symbol_argument, :scalar)).to be_nil
    expect(migration.send(:first_symbol_argument, %i[arg_paren scalar])).to be_nil
    expect(migration.send(:first_symbol_argument, [:args_add_block, nil])).to be_nil
    expect(migration.send(:first_symbol_argument,
                          [:args_add_block, [%i[symbol_literal bad]]])).to be_nil
    expect(migration.send(:self_receiver?, [:var_ref, nil])).to be(false)
    expect(migration.send(:constant_path, :scalar)).to eq([])
    expect(migration.send(:constant_path, [:var_ref, nil])).to eq([])
  end

  it 'validates source identity bundles, rename declarations, and missing bindings' do
    identity_class = Mxrb::RubyApp::SourceIdentity
    duplicate_files = [
      { path: identity_class::BUNDLE_PATH }, { path: identity_class::BUNDLE_PATH }
    ]
    expect { identity_class.read_bundle(duplicate_files) }
      .to raise_error(Mxrb::SerializationError, /duplicate Ruby source identity sidecar/)

    entry = {
      'kind' => 'record', 'id' => 'id', 'name' => 'App.Item',
      'path' => 'app/models/app/item.rb', 'ruby_class' => 'App::Item', 'native_kind' => ''
    }
    contents = JSON.generate('format_version' => 1, 'entries' => [entry, entry])
    file = {
      path: identity_class::BUNDLE_PATH, contents:,
      sha256: Digest::SHA256.hexdigest(contents)
    }
    expect { identity_class.read_bundle([file]) }
      .to raise_error(Mxrb::SerializationError, /duplicate Ruby source identities/)

    identity = identity_class.allocate
    identity.instance_variable_set(:@bindings, {})
    expect(identity.validate_flow!(Object.new, 'microflow')).to be_nil
    expect { identity.resolve(Object.new, 'record', 'App.Item') }
      .to raise_error(Mxrb::ValidationError, /requires a source file context/)
    identity.instance_variable_set(:@by_name, {})
    expect { identity.send(:renamed_entry, 'service', 'App.Run', nil, 'App.Old') }
      .to raise_error(Mxrb::ValidationError, /only for Ruby records/)
    expect { identity.send(:renamed_entry, 'record', 'App.Item', nil, '') }
      .to raise_error(Mxrb::ValidationError, /cannot be empty/)
    expect { identity.send(:renamed_entry, 'record', 'App.Item', nil, 'App.Item') }
      .to raise_error(Mxrb::ValidationError, /must differ/)
    expect { identity.send(:renamed_entry, 'record', 'App.Item', nil, 'App.Old') }
      .to raise_error(Mxrb::ValidationError, /unknown Ruby record rename source/)
    expect { identity.send(:unique_entry, [entry, entry]) }
      .to raise_error(Mxrb::ValidationError, /ambiguous Ruby source identity/)
  end

  it 'covers integration-document builder defaults and validation failures' do
    collection = Mxrb::Dsl::IntegrationDocuments::MessageDefinitionCollectionBuilder.new
    collection.entity_message(:Item, entity: 'App.Item')
    expect(collection.definitions.first).to include(id: nil)
    exposed = Mxrb::Dsl::IntegrationDocuments::MessageExposedEntityBuilder.new(
      id: nil, entity: 'App.Item', children_marker: 2
    )
    exposed.exposed_attribute(:Name, attribute: 'App.Item.Name')
    expect(exposed.to_h.fetch(:attributes).first).to include(id: nil)

    resources = Mxrb::Dsl::IntegrationDocuments::RestServiceBuilder.new
    expect { resources.resource('') }.to raise_error(ArgumentError, /cannot be empty/)
    resources.resource(:Orders)
    expect { resources.resource(:Orders) }.to raise_error(ArgumentError, /duplicate REST resource/)
    resources.resource(:Customers) { get :list, path: '', microflow: 'App.List' }
    expect(resources.resources.last.fetch(:operations)).not_to be_empty

    resource = Mxrb::Dsl::IntegrationDocuments::RestResourceBuilder.new('Orders')
    expect { resource.operation(:x, method: :trace, path: '', microflow: 'App.Run') }
      .to raise_error(ArgumentError, /unsupported REST method/)
    expect { resource.operation('', method: :get, path: '', microflow: 'App.Run') }
      .to raise_error(ArgumentError, /name cannot be empty/)
    resource.get(:one, path: '/one', microflow: 'App.One') do
      parameter :id, type: :string, maps_to: 'App.One.id'
      response 200
    end
    expect(resource.operations.first.fetch(:parameters).first).not_to have_key(:id)

    operation = Mxrb::Dsl::IntegrationDocuments::RestOperationBuilder.new
    expect { operation.response(99) }.to raise_error(ArgumentError, /invalid HTTP response status/)
    operation.response(200)
    expect { operation.response(200) }.to raise_error(ArgumentError, /duplicate HTTP response/)

    dataset = Mxrb::Dsl::IntegrationDocuments::DataSetBuilder.new
    dataset.oql { 'SELECT 1' }
    expect(dataset.query).to eq('SELECT 1')
    dataset.oql
    expect(dataset.query).to eq('')
    dataset.allow(:User)
    dataset.allow(:Admin) { parameter(:Id) { constraint('[id > 0]') } }
    expect(dataset.access.length).to eq(2)
  end

  it 'covers REST projection type and scalar alternatives' do
    host = Class.new do
      include Mxrb::Dsl::IntegrationDocuments
      attr_reader :name

      def initialize = @name = 'App'
    end.new
    expect(host.send(:qualified_rest_microflow_parameter, 'Run', 'Id')).to eq('App.Run.Id')
    native_type = { '$Type' => 'DataTypes$StringType', '$ID' => 'discarded' }
    expect(host.send(:rest_parameter_type_document, native_type).fetch('$ID')).not_to eq('discarded')
    expect(host.send(:rest_return_entity, :string)).to be_nil
    expect(host.send(:rest_return_entity, '$Type' => 'DataTypes$StringType')).to be_nil
    expect(host.send(:rest_attribute_type, type: :float)).to eq(:decimal)
    expect(host.send(:rest_attribute_type, type: :enum)).to eq(:string)
    expect(host.send(:rest_json_original, :boolean)).to eq('false')
    expect(host.send(:rest_json_example_value, :boolean)).to be(false)
    expect(host.send(:rest_microflow, 'App.Missing')).to be_nil
    expect(host.send(:rest_entity, 'App.Missing')).to be_nil
    expect(host.send(:rest_native_document?, 'Missing', 'Forms$Page')).to be(false)
    expect(host.send(
             :rest_operation_export_mapping, 'Api',
             return_type: { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'App.Missing' }
           )).to be_nil

    response_parameter = {
      name: 'HttpResponse',
      type: { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'System.HttpResponse' }
    }
    assignment = {
      type: :change_object, variable: 'HttpResponse',
      members: [{ attribute: 'System.HttpResponse.StatusCode', value: 201 }]
    }
    flow = { parameters: [response_parameter], body: [assignment] }
    host.send(:apply_rest_success_status!, flow, success_status: 201)
    expect(flow.fetch(:body)).to eq([assignment])
  end

  it 'covers document declarations without blocks and explicit REST parameter ids' do
    host_class = Class.new do
      include Mxrb::Dsl::IntegrationDocuments
      attr_reader :name

      def initialize = @name = 'App'
      def semantic_native_document(_name, _type, doc, **) = doc
    end
    host = host_class.new
    expect(host.dataset(:Empty)).to include('Parameters' => [2])
    expect(host.message_definition_collection(:Empty)).to include('MessageDefinitions' => [2])

    operation = Mxrb::Dsl::IntegrationDocuments::RestOperationBuilder.new
    operation.parameter(:id, type: :string, maps_to: 'App.Run.id', id: 'parameter-id')
    expect(operation.parameters.first).to include(id: 'parameter-id')
    access = Mxrb::Dsl::IntegrationDocuments::DataSetRoleAccessBuilder.new
    access.parameter(:Id)
    expect(access.parameters.first.fetch(:constraints)).to eq([])
  end

  it 'covers pluggable projection adapters and semantic caches' do
    properties_class = Mxrb::RubyApp::PluggableProperties
    expect(properties_class.try_for_widget(:Grid, widget_id: 'x', properties: nil)).to be_nil
    expect(properties_class.try_supported_subset_for_widget(:Grid, widget_id: 'x', properties: nil)).to be_nil
    bridge = double
    allow(bridge).to receive(:populate_projection)
    allow(bridge).to receive(:to_projection).and_return({ different: true })
    allow(properties_class).to receive(:for_widget).and_return(bridge)
    expect(properties_class.try_for_widget(:Grid, widget_id: 'x', properties: { value: true })).to be_nil

    instance = properties_class.allocate
    instance.instance_variable_set(:@object, Object.new)
    instance.instance_variable_set(:@semantic_values, {})
    instance.instance_variable_set(:@projection_order, [])
    yielded = false
    instance.evaluate { |_builder| yielded = true }
    expect(yielded).to be(true)
    expect { instance.send(:supported_object_value, double, 'invalid') }
      .to raise_error(TypeError, /requires a Hash/)
  end

  it 'covers pluggable semantic projection defaults and nil validation' do
    instance = Mxrb::RubyApp::PluggableProperties.allocate
    property = double(key: 'action', value_type: double(kind: 'Expression'))
    schema = double(fetch_property: property)
    instance.instance_variable_set(:@schema, schema)
    semantic = Mxrb::RubyApp::PluggableProperties::ActionValue.new('microflow', 'App.Run', [])
    instance.instance_variable_set(:@semantic_values, 'action' => semantic)
    instance.instance_variable_set(:@object, double)
    expect(instance.send(:typed_value, 'action')).to equal(semantic)
    expect(instance.send(:project_semantic_value, 'future')).to be_nil
    expect(instance.send(:validate_semantic_input!, property, nil)).to be_nil
  end

  it 'covers remaining Forms enum and duplicate-name encoding alternatives' do
    codec = Mxrb::Forms::MprCodec.new
    editable = double(type_name: 'EditableEnum')
    expect(codec.send(:legacy_enum_value, editable, false)).to eq('Never')

    first = Mxrb::Forms::Node.build('TextBox') { name 'Duplicate' }
    second = Mxrb::Forms::Node.build('TextBox') { name 'Duplicate' }
    codec.send(:prepare_node_ids, [first, second])
    expect(codec.instance_variable_get(:@local_encode_references)).to eq({})
  end

  it 'retains non-service APIs during legacy service source migration' do
    source = <<~RUBY
      class Other
        def native_call
          native_call
        end
      end
    RUBY
    migration = Mxrb::RubyApp::LegacyServiceSourceMigration.new(
      path: 'app/services/app/other.rb', source:
    )
    expect(migration.migrate).to eq(source)
  end

  it 'preserves data-view native extensions and pluggable widget slots' do
    page = Mxrb::Model::Page.allocate
    projected = page.send(
      :data_view_widget,
      '$Type' => 'Forms$DataView', 'Name' => 'Details', 'Future' => true
    )
    expect(projected.dig(:options, :unknown_native)).to eq('Future' => true)

    properties = { content: { widgets: [{ type: :text, name: 'Title' }] } }
    allow(page).to receive(:pluggable_properties).and_return(properties)
    widget = {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'Card',
      'Type' => { 'WidgetId' => 'App.Card', 'WidgetName' => 'Card' },
      'Object' => {}, 'ObjectType' => {}
    }
    expect(page.send(:generic_pluggable_widget, widget).fetch(:slots))
      .to eq([{ path: [:content], widgets: [{ type: :text, name: 'Title' }] }])
  end

  it 'covers legacy page source, editability, and grid class alternatives' do
    source = double(units_of: [], documents: [])
    builder = Mxrb::Compiler::LegacyPageBuilder.new(source, '/tmp/unused')
    expect(builder.send(:list_view_entity, 'DataSource' => {
      'EntityRef' => { 'Entity' => 'App.Item', 'Steps' => [2] }
    })).to eq('App.Item')
    expect(builder.send(:data_view_editable?, 'Editability' => 'Never')).to be(false)
    expect(builder.send(:microflow_return_entity,
                        '$Type' => 'Forms$NanoflowSource', 'Nanoflow' => 'App.Load')).to eq('')
    allow(builder).to receive(:data_view_entity).and_return('App.Item')
    expect(builder.send(:supported_data_view?,
                        'DataSource' => { '$Type' => 'Forms$NanoflowSource' })).to be(true)
    expect(builder.send(:grid_weight_class, 'md', -1)).to be_nil
    expect(builder.send(:grid_weight_class, 'md', -2)).to eq('col-md-auto')
    expect(builder.send(:grid_row_alignment_class, 'Center')).to eq('align-children-center')
    expect(builder.send(:grid_column_alignment_class, 'End')).to eq('align-self-end')
    expect(builder.send(:render_layout_grid,
                        { 'Width' => 'FixedWidth', 'Rows' => [2] }, 'App.Page', 'en_US'))
      .to include('mx-layoutgrid-fixed')
    expect(builder.send(:render_grid_row,
                        { 'SpacingBetweenColumns' => false, 'Columns' => [2] }, 'App.Page', 'en_US'))
      .to include('no-gutters')
  end

  it 'covers legacy list-view step and flow fallbacks' do
    builder = Mxrb::Compiler::LegacyPageBuilder.new(double(units_of: [], documents: []), '/tmp/unused')
    expect(builder.send(:list_view_entity, 'DataSource' => {
      'EntityRef' => { 'Entity' => 'App.Direct', 'Steps' => [2, {
        'DestinationEntity' => 'App.Step'
      }] }
    })).to eq('App.Step')
    allow(builder).to receive(:microflow_return_entity).and_return('App.FlowResult')
    expect(builder.send(:list_view_entity, 'DataSource' => {})).to eq('App.FlowResult')
  end

  it 'covers pluggable construction, object copying, and nil projection' do
    properties_class = Mxrb::RubyApp::PluggableProperties
    instance = properties_class.allocate
    allow(properties_class).to receive(:new).and_return(instance)
    expect(properties_class.build('vendor.Widget', catalog: double)).to equal(instance)

    property = double(key: 'kept')
    assignment = double(property:, value: 'value')
    instance.instance_variable_set(:@schema, double)
    instance.instance_variable_set(:@object, double(assignments: [assignment]))
    candidate = double
    allow(candidate).to receive(:set)
    allow(Mxrb::Pluggable::ObjectNode).to receive(:new).and_return(candidate)
    expect(instance.send(:copy_object, except: 'other')).to equal(candidate)
    expect(candidate).to have_received(:set).with('kept', 'value')
    expect(instance.send(:copy_object, except: 'kept')).to equal(candidate)
    expect(instance.send(:project_value, double, nil)).to be_nil
  end

  it 'covers source identity materialization and empty source metadata' do
    identity = Mxrb::RubyApp::SourceIdentity.allocate
    owner = double(mendix_name: 'App.Item', mendix_id: 'kept-id')
    binding = { 'kind' => 'record', 'native_kind' => '', 'id' => 'kept-id' }
    identity.instance_variable_set(:@bindings, owner => binding)
    identity.instance_variable_set(
      :@by_identity,
      %w[record kept-id] => [{ 'id' => 'kept-id' }]
    )
    entries = %w[other-id kept-id].map do |id|
      { 'kind' => 'record', 'name' => 'App.Item', 'native_kind' => '', 'id' => id }
    end
    allow(identity).to receive(:materialized_entries).and_return(entries)
    identity.reconcile!(double(modules: [double]))
    expect(binding.fetch('id')).to eq('kept-id')

    unit = {
      'UnitID' => 'unit-id', 'ContainmentName' => 'ProjectDocuments'
    }
    mpr = double(root_unit: { 'UnitID' => 'root' }, children_of: [unit])
    project = double(mpr:, parse_bson: {
      '$Type' => 'Security$ProjectSecurity', '$ID' => nil
    })
    expect(identity.send(:project_security_entries, project).first.fetch('id')).to eq('unit-id')

    mod = {
      'models' => [{ 'id' => 'id', 'name' => 'Item', 'path' => '' }],
      'dtos' => [], 'pages' => [], 'microflows' => [], 'nanoflows' => [], 'constants' => [],
      'enumerations' => [], 'scheduled_events' => []
    }
    expect(identity.send(:module_entries, mod)).to eq([])

    identity.instance_variable_set(:@source_path, 'app/models/app/item.rb')
    identity.instance_variable_set(:@by_path, Hash.new { |hash, key| hash[key] = [] })
    identity.instance_variable_set(:@by_class, {})
    identity.instance_variable_set(:@by_name, {})
    expect(identity.send(:implicit_entry, double(name: nil), 'record', 'App.Item')).to be_nil
  end
end
# rubocop:enable Metrics/BlockLength
