# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/source_emitter'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Pluggable typed edge contracts' do
  let(:catalog) { Mxrb::Pluggable::Catalog.new }

  def define_widget(id = 'com.example.Edge', registry: catalog, &block)
    Mxrb::Pluggable.widget_type(id, catalog: registry, &block)
  end

  it 'emits and reloads complete schema metadata, flags, constraints, and nested schemas' do
    widget = define_widget('com.example.CompleteSchema') do
      name 'Complete'
      description 'Description'
      prompt 'Prompt'
      studio_pro_category 'Data'
      studio_category 'Custom'
      platform 'Native'
      help_url 'https://example.invalid/help'
      offline!
      needs_context!
      plugin!
      properties do
        property 'everything', :data_source do
          category 'General'
          caption 'Everything'
          description 'Description'
          prompt 'Prompt'
          entity_property 'entity'
          default_value 'default'
          on_change_property 'changed'
          data_source_property 'source'
          selectable_objects_property 'selectable'
          default_property!
          list!
          linked!
          metadata!
          allow_non_persistable_entities!
          parameter_list!
          multiline!
          required!
          set_label!
          allow_upload!
          path :reference, :entity
          default_type :string
          attribute_type :string
          association_type :reference
          selection_type :single
          choice 'one', 'One'
          action_variable 'item', :object, 'Item'
          translation 'en_US', 'Translated'
          return_type :object do
            list!
            entity_property 'entity'
            assignable_to 'Base.Entity'
          end
          properties { property 'nestedValue', :string }
        end
      end
    end

    source = Mxrb::Pluggable::SchemaSourceEmitter.new.emit(widget)
    expect(source).to include(
      'offline!', 'needs_context!', 'plugin!', 'default_property!', 'allow_upload!',
      'path "Reference", "Entity"', 'choice "one", "One"',
      'action_variable "item", "Object", "Item"', 'translation "en_US", "Translated"',
      'return_type :object do', 'assignable_to "Base.Entity"', 'properties do'
    )
    expect { eval(source) }.not_to raise_error # rubocop:disable Security/Eval
  end

  it 'supports minimal schema builders with omitted nested blocks' do
    property = Mxrb::Pluggable::PropertyTypeBuilder.new('value', :string)
    property.return_type(:string)
    property.properties
    expect(property.build.value_type).to have_attributes(
      return_type: be_a(Mxrb::Pluggable::ReturnType), object_type: be_a(Mxrb::Pluggable::ObjectType)
    )
    widget = Mxrb::Pluggable::WidgetTypeBuilder.new('com.example.Minimal')
    widget.properties
    expect(widget.build.object_type.properties).to be_empty
    empty = define_widget('com.example.Empty')
    expect(empty).to be_a(Mxrb::Pluggable::WidgetType)
    source = Mxrb::Pluggable::SchemaSourceEmitter.new.emit([empty, property_widget(property.build)])
    expect(source).to include('return_type :string do')
  end

  def property_widget(property)
    Mxrb::Pluggable::WidgetTypeBuilder.new('com.example.MinimalProperty').tap do |widget|
      widget.instance_variable_set(:@object_type, Mxrb::Pluggable::ObjectType.new([property].freeze))
    end.build
  end

  it 'rejects invalid catalog entries and falls back safely across schema revisions' do
    expect { catalog.register(Object.new) }.to raise_error(TypeError, /WidgetType/)
    expect { catalog.resolve('missing.Widget', Mxrb::Pluggable::ObjectNode.allocate) }
      .to raise_error(KeyError, /unknown pluggable widget/)

    first = define_widget('com.example.Revisions') do
      properties { property 'count', :integer }
    end
    incompatible_schema = Mxrb::Pluggable::ObjectTypeBuilder.new.tap do |object|
      object.property('future', :boolean)
    end.build
    incompatible = Mxrb::Pluggable::ObjectNode.new(incompatible_schema).tap { _1.set(:future, true) }
    expect(catalog.resolve(first.id, incompatible)).to equal(first)

    second = define_widget('com.example.Revisions') do
      properties do
        property 'count', :string
        property 'nested', :object do
          properties { property 'caption', :string }
        end
      end
    end
    merged = catalog.fetch(second.id)
    expect(merged.object_type.fetch_property(:count).value_type.kind).to eq('String')
    expect(catalog.property_count).to be >= 3
    expect(catalog.resolve(second.id, incompatible)).to equal(merged)

    property = second.object_type.fetch_property(:count)
    assignment = Mxrb::Pluggable::Assignment.new(property, 'value', nil)
    fake_object = Struct.new(:assignments).new([assignment])
    schema_without_value = Mxrb::Pluggable::ObjectType.new([property.with(value_type: nil)].freeze)
    expect(catalog.send(:schema_excess, schema_without_value, fake_object)).to eq(0)
    expect(catalog.send(:schema_excess, Mxrb::Pluggable::ObjectType.new([].freeze), fake_object)).to eq(-1)
  end

  it 'exposes XPath builder getters and explicit receiver evaluation without inventing defaults' do
    builder = Mxrb::Pluggable::XPathSourceBuilder.new
    expect(builder.entity).to be_nil
    expect(builder.constraint).to be_nil
    expect(builder.force_full_objects).to be(false)
    expect(builder.sort_bar).to be_nil
    expect(builder.source_variable).to be_nil
    builder.entity('Sales.Order')
    builder.constraint('[Active = true()]')
    builder.force_full_objects(true)
    builder.sort_bar { |bar| bar.set(:sort_items, []) }
    builder.source_variable { |source| source.page_parameter 'Order' }

    expect(builder.build).to have_attributes(
      entity: be_a(Mxrb::Forms::EntityReference),
      constraint: be_a(Mxrb::Forms::XPathConstraint), force_full_objects: true
    )
  end

  it 'validates object construction, assignment order, sources, and dynamic calls' do
    expect { Mxrb::Pluggable::ObjectNode.new(Object.new) }.to raise_error(TypeError, /ObjectType/)
    schema = Mxrb::Pluggable::ObjectTypeBuilder.new.tap do |object|
      object.property('title', :string)
      object.property('items', :object) do
        list!
        properties { property 'caption', :string }
      end
      object.property('action', :action)
      object.property('source', :data_source)
    end.build
    object = Mxrb::Pluggable::ObjectNode.new(schema)
    expect { object.source(:title) {} }.to raise_error(ArgumentError, /assign title before/)
    expect { object.append(:title, 'invalid') }.to raise_error(TypeError, /not a collection/)
    expect { object.unknown }.to raise_error(NoMethodError)
    expect { object.title('one', 'two') }.to raise_error(ArgumentError, /exactly one/)
    expect { object.action {} }.to raise_error(ArgumentError, /requires a Forms type/)

    expect(object.evaluate { |node| node.title 'Title' }).to equal(object)
    expect(object.title).to eq('Title')
    object.source(:title) { page_parameter 'Current' }
    expect(object.source(:title)).to be_a(Mxrb::Forms::Node)
    object.items { caption 'First' }
    expect(object.fetch(:items).first.fetch(:caption)).to eq('First')
    object.set(:source, type: :microflow_source) {}
    expect(object.fetch(:source).schema_type.name).to eq('MicroflowSource')
    object.set(:source) { |source| source.entity 'Sales.Order' }
    expect(object.fetch(:source).entity.to_s).to eq('Sales.Order')
    expect { object.title { 'invalid' } }.to raise_error(ArgumentError, /does not accept a nested block/)
  end

  it 'normalizes every semantic property family and rejects mismatched values' do
    definition = define_widget('com.example.Values') do
      properties do
        property 'decimal', :decimal
        property 'expression', :expression
        property 'constraint', :entity_constraint
        property 'attribute', :attribute
        property 'entity', :entity
        property 'label', :translatable_string
        property 'system', :system
        property 'association', :association
      end
    end
    object = Mxrb::Pluggable::Node.new(definition, catalog:).object
    object.set(:decimal, '1.50')
    object.set(:expression, '$currentObject/Name')
    object.set(:constraint, '[Active = true()]')
    object.set(:attribute, 'Sales.Order.Name')
    object.set(:entity, 'Sales.Order')
    object.set(:label, 'Orders')
    object.set(:system, Object.new)
    object.set(:association, Mxrb::Pluggable.reference(:association, 'Sales.Order_Customer'))

    expect(object.fetch(:decimal).to_s).to eq('1.5')
    expect(object.fetch(:constraint)).to be_a(Mxrb::Forms::XPathConstraint)
    expect(object.fetch(:attribute)).to be_a(Mxrb::Forms::AttributeReference)
    expect(object.fetch(:entity)).to be_a(Mxrb::Forms::EntityReference)
    expect(object.fetch(:label)).to be_a(Mxrb::Forms::Text)
    expect { object.set(:decimal, Object.new) }.to raise_error(ArgumentError)
    expect { object.set(:association, 'not a reference') }.to raise_error(TypeError, /expects Association/)
  end

  it 'validates widget outer fields and explicit receiver blocks' do
    definition = define_widget('com.example.Outer') { properties {} }
    expect { Mxrb::Pluggable::Node.new(Object.new) }.to raise_error(TypeError, /WidgetType/)
    node = Mxrb::Pluggable::Node.new(definition, catalog:)
    expect(node.evaluate { |widget| widget.identifier 'edge' }).to equal(node)
    expect(node.properties).to equal(node.object)
    expect { node.identifier('one', 'two') }.to raise_error(ArgumentError, /expects one value/)
    expect(node.appearance(nil)).to equal(node)
    expect { node.appearance(Object.new) }.to raise_error(TypeError, /expects a Forms node/)
    node.editable('Always')
    node.tab_index('7')
    expect(node).to have_attributes(editable: :Always, tab_index: 7)
    expect(node.send(:normalize_outer, :future, 'value')).to eq('value')
  end
end
# rubocop:enable Metrics/BlockLength
