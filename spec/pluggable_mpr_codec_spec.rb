# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'

RSpec.describe Mxrb::Pluggable::MprCodec do
  def schema_bytes(schema) = Mxrb::IO::BsonCodec.serialize(schema)

  def value_type(kind, list: false, object_type: nil, required: false)
    Mxrb::Pluggable::ValueType.new(
      kind:, list:, linked: false, metadata: false, entity_property: '',
      allow_non_persistable_entities: false, path_kind: 'No', path_type: 'None',
      parameter_list: false, multiline: false, default_value: '', required:,
      on_change_property: '', data_source_property: '', selectable_objects_property: '',
      attribute_types: [].freeze, association_types: [].freeze, selection_types: [].freeze,
      enumeration_values: [].freeze, action_variables: [].freeze, object_type:,
      return_type: nil, translations: [].freeze, set_label: false,
      default_type: 'None', allow_upload: false
    )
  end

  def property(key, kind, list: false, object_type: nil, required: false)
    Mxrb::Pluggable::PropertyType.new(
      key:, ruby_name: Mxrb::Forms::Naming.ruby_name(key), category: 'General',
      caption: key, description: '', prompt: '', default: false,
      value_type: value_type(kind, list:, object_type:, required:)
    )
  end

  def widget_type
    column = Mxrb::Pluggable::ObjectType.new(
      [property('caption', 'String'), property('attribute', 'Attribute')].freeze
    )
    object = Mxrb::Pluggable::ObjectType.new(
      [
        property('showHeader', 'Boolean'), property('pageSize', 'Integer'),
        property('columns', 'Object', list: true, object_type: column),
        property('content', 'Widgets')
      ].freeze
    )
    Mxrb::Pluggable::WidgetType.new(
      id: 'com.example.typed.Grid', name: 'Typed grid', description: 'Grid', prompt: '',
      studio_pro_category: 'Data', studio_category: '', platform: 'Web', offline: true,
      needs_context: true, plugin: true, help_url: 'https://example.invalid/grid',
      object_type: object
    )
  end

  it 'round-trips selection through its physical field rather than the unrelated primitive field' do
    schema = widget_type.with(id: 'com.example.selection.Input',
                              object_type: Mxrb::Pluggable::ObjectType.new([property('selection', 'Selection')]))
    registry = Mxrb::Pluggable::Catalog.default
    registry.register(schema)
    forms_codec = Mxrb::Forms::MprCodec.new(pluggable_catalog: registry)
    codec = described_class.new(forms_codec:, catalog: registry)

    %w[None Single Multi].each do |selection|
      node = Mxrb::Pluggable::Node.new(schema, catalog: registry)
      node.object.set('selection', selection)
      stored = codec.encode(node)
      value = stored.fetch('Object').fetch('Properties').last.fetch('Value')
      expect(value.fetch('Selection')).to eq(selection)
      expect(value.fetch('PrimitiveValue')).to eq('')
      source = Mxrb::Forms::SourceEmitter.new.emit(codec.decode(stored))
      restored = eval(source) # rubocop:disable Security/Eval
      expect(codec.encode(restored).fetch('Object').fetch('Properties').last.fetch('Value')['Selection'])
        .to eq(selection)
    end
  end

  it 'round-trips a complete embedded schema without exposing pointer ids or hashes' do
    registry = Mxrb::Pluggable::Catalog.default
    registry.register(widget_type)
    forms_codec = Mxrb::Forms::MprCodec.new
    codec = described_class.new(forms_codec:, catalog: registry)
    node = Mxrb::Pluggable.widget('com.example.typed.Grid', catalog: registry) do
      identifier 'orders_grid'
      editable :always
      conditional_visibility do
        set :module_roles, []
        ignore_security false
      end
      properties do
        show_header true
        page_size 25
        columns do
          caption 'Customer'
          attribute 'Sales.Order.Customer'
        end
        content(:dynamic_text) { name 'empty_message' }
      end
    end

    document = codec.encode(node)
    decoded = codec.decode(document)
    source = Mxrb::Forms::SourceEmitter.new.emit(decoded)
    rebuilt = eval(source) # rubocop:disable Security/Eval

    expect(document.dig('Object', 'Properties').first).to eq(2)
    expect(decoded.object.fetch(:show_header)).to be(true)
    expect(decoded.object.fetch(:columns).first.fetch(:attribute).to_s)
      .to eq('Sales.Order.Customer')
    expect(rebuilt.object.fetch(:page_size)).to eq(25)
    expect(rebuilt.conditional_visibility.schema_type.name).to eq('ConditionalVisibilitySettings')
    expect(source).to include('Mxrb::Pluggable.widget "com.example.typed.Grid"',
                              'columns do', 'content(:dynamic_text) do')
    expect(source).not_to include('$ID', 'TypePointer', '{', '}', 'native_widget', 'deep_structure')
  end

  it 'rejects unknown custom-widget storage instead of retaining an opaque fragment' do
    registry = Mxrb::Pluggable::Catalog.new
    registry.register(widget_type)
    codec = described_class.new(forms_codec: Mxrb::Forms::MprCodec.new, catalog: registry)
    document = codec.encode(Mxrb::Pluggable.widget('com.example.typed.Grid', catalog: registry))
    document['OpaqueFutureField'] = 'forbidden'

    expect { codec.decode(document) }
      .to raise_error(Mxrb::Pluggable::UnsupportedStoragePropertyError, /OpaqueFutureField/)
  end

  it 'unifies schema revisions of the same widget without losing properties' do
    registry = Mxrb::Pluggable::Catalog.new
    first = widget_type.with(object_type: Mxrb::Pluggable::ObjectType.new(
      [property('pageSize', 'Integer')].freeze
    ))
    second = widget_type.with(object_type: Mxrb::Pluggable::ObjectType.new(
      [property('showHeaderFilters', 'Boolean')].freeze
    ))

    registry.register(first)
    merged = registry.register(second)

    expect(merged.object_type.property(:page_size)).not_to be_nil
    expect(merged.object_type.property(:show_header_filters)).not_to be_nil
    expect(registry.fetch(widget_type.id)).to equal(merged)
    expect(registry.schema_definitions).to eq([first, second])
  end

  it 'encodes each instance with its compatible concrete schema revision' do
    registry = Mxrb::Pluggable::Catalog.new
    first = widget_type.with(object_type: Mxrb::Pluggable::ObjectType.new(
      [property('pageSize', 'Integer')].freeze
    ))
    second = widget_type.with(object_type: Mxrb::Pluggable::ObjectType.new(
      [property('showHeaderFilters', 'Boolean')].freeze
    ))
    registry.register(first)
    registry.register(second)
    codec = described_class.new(forms_codec: Mxrb::Forms::MprCodec.new, catalog: registry)

    page = Mxrb::Pluggable.widget(widget_type.id, catalog: registry) { properties { page_size 25 } }
    filters = Mxrb::Pluggable.widget(widget_type.id, catalog: registry) do
      properties { show_header_filters true }
    end

    encoded_keys = [page, filters].map do |node|
      document = codec.encode(node)
      document.dig('Type', 'ObjectType', 'PropertyTypes').drop(1).map { _1['PropertyKey'] }
    end
    expect(encoded_keys).to eq([['pageSize'], ['showHeaderFilters']])
  end

  it 'round-trips association references with their complete entity path' do
    schema = Mxrb::Pluggable::ObjectType.new([property('association', 'Association')].freeze)
    definition = widget_type.with(id: 'com.example.typed.Association', object_type: schema)
    registry = Mxrb::Pluggable::Catalog.new
    registry.register(definition)
    Mxrb::Pluggable::Catalog.default.register(definition)
    codec = described_class.new(forms_codec: Mxrb::Forms::MprCodec.new, catalog: registry)
    target = Mxrb::Forms::AttributeReference.through(
      'Sales.Line.Order',
      via: Mxrb::Forms::EntityReference.through(
        Mxrb::Forms::EntityPathStep.to('Sales.Order_Lines', 'Sales.Line')
      )
    )
    node = Mxrb::Pluggable.widget(definition.id, catalog: registry) do
      properties { association Mxrb::Pluggable.reference(:association, target) }
    end

    document = codec.encode(node)
    decoded = codec.decode(document)
    source = Mxrb::Forms::SourceEmitter.new.emit(decoded)
    rebuilt = eval(source) # rubocop:disable Security/Eval
    value = document.dig('Object', 'Properties', 1, 'Value', 'AttributeRef')

    expect(value.dig('EntityRef', '$Type')).to eq('DomainModels$IndirectEntityRef')
    expect(decoded.object.fetch(:association).target).to eq(target)
    expect(rebuilt.object.fetch(:association).target).to eq(target)
    expect(source).to include('Mxrb::Forms::AttributeReference.through')
  end

  it 'restores embedded schema identity from the semantic page baseline' do
    registry = Mxrb::Pluggable::Catalog.new
    registry.register(widget_type)
    codec = Mxrb::Forms::MprCodec.new(pluggable_catalog: registry)
    node = Mxrb::Pluggable.widget(widget_type.id, catalog: registry) do
      identifier 'orders_grid'
      properties do
        show_header true
        page_size 25
      end
    end
    baseline = codec.encode(node)
    decoded = codec.decode(baseline)
    rebuilt = codec.encode(decoded, baseline:)

    baseline_pointers = baseline.dig('Object', 'Properties').drop(1).map do
      [_1['TypePointer'], _1.dig('Value', 'TypePointer')]
    end
    rebuilt_pointers = rebuilt.dig('Object', 'Properties').drop(1).map do
      [_1['TypePointer'], _1.dig('Value', 'TypePointer')]
    end
    expect(rebuilt['Type']).to eq(baseline['Type'])
    expect(rebuilt_pointers).to eq(baseline_pointers)
  end

  it 'preserves absent optional schema fields while encoding edited widget values' do
    registry = Mxrb::Pluggable::Catalog.new
    registry.register(widget_type)
    codec = Mxrb::Forms::MprCodec.new(pluggable_catalog: registry)
    node = Mxrb::Pluggable.widget(widget_type.id, catalog: registry) do
      properties { columns { caption 'Customer' } }
    end
    baseline = codec.encode(node)
    schema = baseline.fetch('Type')
    schema.delete('Prompt')
    properties = schema.dig('ObjectType', 'PropertyTypes').drop(1)
    properties.each { _1.delete('Prompt') }
    nested = properties.find { _1['PropertyKey'] == 'columns' }
    nested.dig('ValueType', 'ObjectType', 'PropertyTypes').drop(1).each do |property|
      property.delete('Prompt')
      property.fetch('ValueType').delete('AllowUpload')
    end
    # A present, nonempty prompt must survive alongside absent prompts.
    properties.first['Prompt'] = 'Show the column header'
    schema.replace(schema.sort.to_h)
    original_schema = Marshal.load(Marshal.dump(schema))

    decoded = codec.decode(baseline)
    decoded.object.fetch(:columns).first.set(:caption, 'Orders')
    rebuilt = codec.encode(decoded, baseline:)

    expect(schema_bytes(rebuilt.fetch('Type'))).to eq(schema_bytes(original_schema))
    expect(baseline.fetch('Type')).to eq(original_schema)
    expect(codec.decode(rebuilt).object.fetch(:columns).first.fetch(:caption)).to eq('Orders')
  end

  it 'prefers an exact property key when MPK keys collide after Ruby normalization' do
    schema = Mxrb::Pluggable::ObjectType.new(
      [property('Label', 'System'), property('label', 'TextTemplate')].freeze
    )

    expect(schema.property(:label).key).to eq('label')
    expect(schema.property('Label').key).to eq('Label')
  end

  it 'emits scalar property names that collide with Kernel through explicit set' do
    schema = Mxrb::Pluggable::ObjectType.new([property('loop', 'Boolean')].freeze)
    definition = widget_type.with(id: 'com.example.typed.Carousel', object_type: schema)
    registry = Mxrb::Pluggable::Catalog.default
    registry.register(definition)
    node = Mxrb::Pluggable.widget(definition.id)
    node.object.set(:loop, true)

    source = Mxrb::Forms::SourceEmitter.new.emit(node)
    rebuilt = eval(source) # rubocop:disable Security/Eval

    expect(source).to include('set :loop, true')
    expect(rebuilt.object.fetch(:loop)).to be(true)
  end

  it 'preserves nil for conditionally inactive properties marked required by the MPK' do
    schema = Mxrb::Pluggable::ObjectType.new(
      [property('headerText', 'TextTemplate', required: true)].freeze
    )
    definition = widget_type.with(id: 'com.example.typed.RequiredNullable', object_type: schema)
    registry = Mxrb::Pluggable::Catalog.new
    registry.register(definition)
    codec = described_class.new(forms_codec: Mxrb::Forms::MprCodec.new, catalog: registry)
    node = Mxrb::Pluggable.widget(definition.id, catalog: registry) do
      properties { header_text nil }
    end

    document = codec.encode(node)
    decoded = codec.decode(document)

    expect(decoded.object.fetch(:header_text)).to be_nil
    expect(document.dig('Object', 'Properties', 1, 'Value', 'TextTemplate')).to be_nil
  end

  it 'round-trips native nested source variables and core Forms data sources' do
    schema = Mxrb::Pluggable::ObjectType.new([property('datasource', 'DataSource')].freeze)
    definition = widget_type.with(id: 'com.example.typed.DataSource', object_type: schema)
    registry = Mxrb::Pluggable::Catalog.new
    registry.register(definition)
    Mxrb::Pluggable::Catalog.default.register(definition)
    codec = described_class.new(forms_codec: Mxrb::Forms::MprCodec.new, catalog: registry)
    variable = Mxrb::Forms.page_variable { snippet_parameter 'CurrentItem' }
    xpath = Mxrb::Pluggable::XPathSource.new(
      Mxrb::Forms::EntityReference.coerce('Sales.Order'),
      Mxrb::Forms::XPathConstraint.coerce(''), nil, variable, false
    )
    node = Mxrb::Pluggable.widget(definition.id, catalog: registry)
    node.object.set(:datasource, xpath)

    document = codec.encode(node)
    value = document.dig('Object', 'Properties', 1, 'Value')
    decoded = codec.decode(document)
    expect(value['SourceVariable']).to be_nil
    expect(value.dig('DataSource', 'SourceVariable', '$Type')).to eq('Forms$PageVariable')
    expect(decoded.object.fetch(:datasource).source_variable.snippet_parameter.target).to eq('CurrentItem')

    flow_source = Mxrb::Forms.microflow_source { force_full_objects false }
    node.object.set(:datasource, flow_source)
    rebuilt = codec.encode(node)
    decoded = codec.decode(rebuilt)
    source = Mxrb::Forms::SourceEmitter.new.emit(decoded)
    evaluated = eval(source) # rubocop:disable Security/Eval
    expect(rebuilt.dig('Object', 'Properties', 1, 'Value', 'DataSource', '$Type'))
      .to eq('Forms$MicroflowSource')
    expect(decoded.object.fetch(:datasource).schema_type.name).to eq('MicroflowSource')
    expect(evaluated.object.fetch(:datasource).schema_type.name).to eq('MicroflowSource')
  end
end
