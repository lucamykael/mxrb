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
end
