# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/source_emitter'

RSpec.describe Mxrb::Forms::SourceEmitter do # rubocop:disable Metrics/BlockLength
  subject(:emitter) { described_class.new }

  def sample_value(property, catalog) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
    target = catalog.type(property.type_name)
    value = if property.reference?
              'MyModule.Target'
            elsif target&.enum?
              target.values.first
            elsif target&.element?
              concrete = catalog.types.find do |candidate|
                candidate.element? && candidate.concrete? &&
                  (candidate == target || catalog.descendant?(candidate.name, target.name))
              end
              Mxrb::Forms::Node.new(concrete.name, catalog:)
            else
              {
                'string' => 'value', 'integer' => 1, 'boolean' => true,
                'size' => Mxrb::Forms::Size.new(100, 75), 'blob' => "\x00".b,
                'Text' => 'Text', 'Expression' => '$currentObject/Name',
                'AttributeReference' => 'MyModule.Entity.Name',
                'EntityReference' => 'MyModule.Entity', 'DataType' => 'String',
                'Condition' => '$currentObject/Active', 'TextTemplate' => 'Template',
                'XPathConstraint' => '[Active = true()]'
              }.fetch(property.type_name)
            end
    property.many? ? [value] : value
  end

  it 'emits and evaluates a nested Forms tree as clean Ruby source' do
    node = Mxrb::Forms.action_button do
      name 'save'
      button_style :primary
      caption do
        template Mxrb::Forms::Text.coerce(
          [Mxrb::Forms::Translation.new('en_US', 'Save'),
           Mxrb::Forms::Translation.new('pt_BR', 'Salvar')]
        )
      end
      action(:microflow_client_action) do
        disabled_during_execution true
        microflow_settings do
          microflow 'MyModule.Save'
        end
      end
    end

    source = emitter.emit(node)
    rebuilt = eval(source) # rubocop:disable Security/Eval

    expect(source).to start_with("Mxrb::Forms.action_button do\n")
    expect(source).to include('button_style :primary', 'action(:microflow_client_action) do')
    expect(source).not_to include('{', '}', '$ID', 'Hash', 'deep_structure', 'native_widget')
    expect(rebuilt.schema_type).to eq(node.schema_type)
    expect(rebuilt.button_style).to eq(node.button_style)
    expect(rebuilt.caption.template).to eq(node.caption.template)
    expect(rebuilt.action.schema_type.name).to eq('MicroflowClientAction')
  end

  it 'emits heterogeneous collections without a hash transport' do
    node = Mxrb::Forms.data_view do
      name 'customer'
      widgets(:text_box) { name 'customer_name' }
      widgets(:action_button) { name 'save' }
    end

    source = emitter.emit(node)
    rebuilt = eval(source) # rubocop:disable Security/Eval

    expect(source).to include('widgets(:text_box) do', 'widgets(:action_button) do')
    expect(rebuilt.widgets.map { _1.schema_type.name }).to eq(%w[TextBox ActionButton])
  end

  it 'emits empty collections and typed size values explicitly' do
    node = Mxrb::Forms.image_uploader do
      name 'photo'
      thumbnail_size Mxrb::Forms::Size.new(100, 75)
    end
    node.set(:allowed_extensions, []) if node.schema_type.property(:allowed_extensions)&.many?

    source = emitter.emit(node)
    rebuilt = eval(source) # rubocop:disable Security/Eval

    expect(rebuilt.thumbnail_size).to eq(Mxrb::Forms::Size.new(100, 75))
  end

  it 'emits evaluable clean Ruby for all 455 concrete widget property occurrences' do
    catalog = Mxrb::Forms::Catalog.for('11.12.1')
    sources = catalog.concrete_widgets.flat_map do |widget|
      widget.all_properties.map do |property|
        node = Mxrb::Forms::Node.new(widget.name, catalog:)
        node.set(property.name, sample_value(property, catalog))
        emitter.emit(node)
      end
    end

    expect(sources.size).to eq(455)
    expect { sources.each { eval(_1) } }.not_to raise_error # rubocop:disable Security/Eval
    expect(sources.join).not_to include('{', '}', '$ID', 'Hash', 'deep_structure', 'native_widget')
  end

  it 'rejects untyped roots and supports named and empty root declarations' do
    expect { emitter.emit(Object.new) }.to raise_error(TypeError, /typed Forms widget/)
    expect { emitter.emit_as(Object.new, 'widget') }.to raise_error(TypeError, /requires a Forms::Node/)
    empty = Mxrb::Forms::Node.new(:action_button)
    expect(emitter.emit(empty)).to eq("Mxrb::Forms.action_button\n")
    expect(emitter.emit_as(empty, 'custom_button')).to eq("custom_button do\nend\n")
  end

  it 'emits every semantic literal variant and rejects unpublished binary bytes' do
    direct = Mxrb::Forms::EntityReference.direct('Sales.Order')
    indirect = Mxrb::Forms::EntityReference.through(
      Mxrb::Forms::EntityPathStep.to('Sales.Order_Customer', 'Sales.Customer')
    )
    values = [
      Mxrb::Forms::Condition.when_value('$currentObject/Active', visible: true),
      Mxrb::Forms::TextTemplate.build('Order {1}', parameters: ['$currentObject/Name']),
      Mxrb::Forms::DataType.object('Sales.Order'), Mxrb::Forms::DataType.list('Sales.Order'),
      Mxrb::Forms::DataType.enumeration('Sales.Status'), Mxrb::Forms::DataType.build('String'),
      Mxrb::Forms::XPathConstraint.coerce([]),
      Mxrb::Forms::XPathConstraint.coerce(%w[[A] [B]]), direct, indirect,
      Mxrb::Forms::BinaryAsset.empty, Mxrb::Pluggable.decimal('1.50')
    ]
    source = values.map { emitter.send(:literal, _1) }.join("\n")
    expect(source).to include(
      'Condition.when_value', 'TextTemplate.build', 'DataType.object', 'DataType.list',
      'DataType.enumeration', 'XPathConstraint.coerce([])', 'EntityReference.through',
      'BinaryAsset.empty'
    )
    expect { emitter.send(:literal, Object.new) }.to raise_error(TypeError, /cannot emit Forms value/)
    asset = Mxrb::Forms::BinaryAsset.from_bytes('private')
    expect { emitter.send(:literal, asset) }.to raise_error(TypeError, /exported as files/)
  end

  it 'emits pluggable nils, empty collections, nested widgets, and sparse data sources' do # rubocop:disable Metrics/BlockLength
    registry = Mxrb::Pluggable::Catalog.new
    definition = Mxrb::Pluggable.widget_type('com.example.EmitterEdges', catalog: registry) do
      properties do
        property 'caption', :string
        property 'children', :widgets
      end
    end
    node = Mxrb::Pluggable::Node.new(definition, catalog: registry)
    node.object.set(:caption, nil)
    node.object.set(:children, [])
    source = emitter.emit(node)
    expect(source).to include('caption(nil)', 'set :children, []')
    expect(emitter.send(:pluggable_node_lines, node, 0).first)
      .to include('widget "com.example.EmitterEdges"')

    property = definition.object_type.fetch_property(:children)
    expect(emitter.send(:pluggable_collection_lines, property, [nil], 0))
      .to eq(['append :children, nil'])
    sparse = Mxrb::Pluggable::XPathSource.new(
      nil, nil, Mxrb::Forms.grid_sort_bar, nil, true
    )
    lines = emitter.send(:pluggable_data_source_lines, property, sparse, 0)
    expect(lines.join("\n")).to include('sort_bar', 'force_full_objects true')

    forms_property = Mxrb::Forms::Property.new(
      'Child', 'child', 'Wrapper', 'Widget', [].freeze, :one, true, nil, nil
    )
    assignment = Mxrb::Forms::Assignment.new(forms_property, node)
    expect(emitter.send(:assignment_lines, assignment, 0).join)
      .to include('child("com.example.EmitterEdges")')
    empty = Mxrb::Forms::Node.new(:action_button)
    expect(emitter.send(:node_lines, empty, 0)).to eq(['action_button do', 'end'])
  end
end
