# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'

RSpec.describe Mxrb::Forms::MprCodec do # rubocop:disable Metrics/BlockLength
  subject(:codec) { described_class.new }

  def text_document(text)
    {
      '$ID' => 'ignored', '$Type' => 'Texts$Text',
      'Items' => [3, { '$ID' => 'ignored', '$Type' => 'Texts$Translation',
                       'LanguageCode' => 'en_US', 'Text' => text }]
    }
  end

  def action_button_document # rubocop:disable Metrics/MethodLength
    {
      '$ID' => 'ignored', '$Type' => 'Forms$ActionButton',
      'Name' => 'save', 'TabIndex' => 0, 'ButtonStyle' => 'Primary',
      'RenderType' => 'Button', 'AriaRole' => 'Button',
      'ConditionalVisibilitySettings' => nil,
      'Appearance' => {
        '$ID' => 'ignored', '$Type' => 'Forms$Appearance',
        'Class' => 'btn-save', 'Style' => '', 'DynamicClasses' => '',
        'DesignProperties' => [3]
      },
      'CaptionTemplate' => {
        '$ID' => 'ignored', '$Type' => 'Forms$ClientTemplate',
        'Template' => text_document('Save'), 'Fallback' => text_document(''), 'Parameters' => [2]
      },
      'Tooltip' => text_document('Persist customer'),
      'Icon' => { '$ID' => 'ignored', '$Type' => 'Forms$GlyphIcon', 'Code' => 42 },
      'Action' => {
        '$ID' => 'ignored', '$Type' => 'Forms$NoAction',
        'DisabledDuringExecution' => true
      },
      'NativeAccessibilitySettings' => nil
    }
  end

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
              sample_external_or_primitive(property.type_name)
            end
    value = Mxrb::Forms::Node::EXTERNAL_VALUES[property.type_name].coerce(value) \
      if Mxrb::Forms::Node::EXTERNAL_VALUES.key?(property.type_name)
    property.many? ? [value] : value
  end

  def sample_external_or_primitive(type)
    {
      'string' => 'value', 'integer' => 1, 'boolean' => true,
      'size' => Mxrb::Forms::Size.new(100, 75), 'blob' => "\x00".b,
      'Text' => 'Text', 'Expression' => '$currentObject/Name',
      'AttributeReference' => 'MyModule.Entity.Name', 'EntityReference' => 'MyModule.Entity',
      'DataType' => 'String', 'Condition' => '$currentObject/Active',
      'TextTemplate' => 'Template', 'XPathConstraint' => '[Active = true()]'
    }.fetch(type)
  end

  it 'decodes a complete widget into typed Ruby and emits no physical noise' do
    node = codec.decode(action_button_document)
    source = Mxrb::Forms::SourceEmitter.new.emit(node)

    expect(node.schema_type.name).to eq('ActionButton')
    expect(node.caption.template.to_s).to eq('Save')
    expect(node.appearance.css_class).to eq('btn-save')
    expect(node.icon.schema_type.name).to eq('GlyphIcon')
    expect(source).not_to include('{', '}', '$ID', 'ignored', 'deep_structure', 'native_widget')
    expect { eval(source) }.not_to raise_error # rubocop:disable Security/Eval
  end

  it 'encodes and decodes the typed widget without relying on old identifiers' do
    original = codec.decode(action_button_document)
    encoded = codec.encode(original)
    decoded = codec.decode(encoded)

    expect(encoded.fetch('$ID')).not_to eq('ignored')
    expect(encoded.fetch('CaptionTemplate').fetch('$Type')).to eq('Forms$ClientTemplate')
    expect(encoded.fetch('Appearance').fetch('DesignProperties').first).to eq(3)
    expect(decoded.caption.template).to eq(original.caption.template)
    expect(decoded.button_style).to eq(original.button_style)
    expect(decoded.action.schema_type).to eq(original.action.schema_type)
  end

  it 'fails loudly for unmapped fields instead of preserving an opaque fragment' do
    document = action_button_document.merge('FutureProperty' => true)

    expect { codec.decode(document) }
      .to raise_error(Mxrb::Forms::UnsupportedStoragePropertyError, /FutureProperty/)
  end

  it 'normalizes legacy v9 physical values into the v11 typed schema' do
    editable = {
      '$ID' => 'ignored', '$Type' => 'Forms$DataView', 'Name' => 'customer',
      'Appearance' => { '$ID' => 'ignored', '$Type' => 'Forms$Appearance' },
      'TabIndex' => 0, 'ConditionalVisibilitySettings' => nil,
      'DataSource' => {
        '$ID' => 'ignored', '$Type' => 'Forms$DataViewSource',
        'EntityRef' => nil, 'PageParameter' => 'MyModule.Customer'
      },
      'Widgets' => [2], 'FooterWidgets' => [2], 'Editable' => true,
      'ShowFooter' => true, 'NoEntityMessage' => text_document('None'),
      'LabelWidth' => 3, 'ReadOnlyStyle' => 'Control'
    }

    node = codec.decode(editable)
    rebuilt = codec.encode(node)

    expect(node.editability.to_sym).to eq(:always)
    expect(node.data_source.source_variable.page_parameter.target).to eq('MyModule.Customer')
    expect(rebuilt.fetch('Editability')).to eq('Always')
    expect(rebuilt).not_to have_key('Editable')
  end

  it 'round-trips conditional DataView editability without reducing it to a boolean' do
    view = Mxrb::Forms.data_view do
      name 'customer'
      editability :conditional
    end

    encoded = codec.encode(view)
    decoded = codec.decode(encoded)

    expect(encoded.fetch('Editability')).to eq('Conditional')
    expect(encoded).not_to have_key('Editable')
    expect(decoded.editability.to_sym).to eq(:conditional)
  end

  it 'preserves qualified object, list and enumeration data types in Ruby' do
    values = [
      { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'Sales.Order' },
      { '$Type' => 'DataTypes$ListType', 'Entity' => 'Sales.Line' },
      { '$Type' => 'DataTypes$EnumerationType', 'Enumeration' => 'Sales.Status' }
    ].map do |parameter_type|
      document = {
        '$ID' => 'parameter', '$Type' => 'Forms$PageParameter', 'Name' => 'Value',
        'ParameterType' => { '$ID' => 'type', **parameter_type },
        'IsRequired' => true, 'DefaultValue' => ''
      }
      node = codec.decode(document)
      source = Mxrb::Forms::SourceEmitter.new.emit(node)
      rebuilt = codec.encode(eval(source)) # rubocop:disable Security/Eval
      [node.parameter_type, source, rebuilt.fetch('ParameterType')]
    end

    expect(values.map { _1.first.target }).to eq(%w[Sales.Order Sales.Line Sales.Status])
    expect(values.map { _1.last.values.last }).to eq(%w[Sales.Order Sales.Line Sales.Status])
    expect(values.map { _1[1] }).to all(include('Mxrb::Forms::DataType.'))
  end

  it 'round-trips native Mendix 11 compound design properties as typed Ruby' do
    document = {
      '$ID' => 'outer', '$Type' => 'Forms$DesignPropertyValue', 'Key' => 'Spacing',
      'Value' => {
        '$ID' => 'compound', '$Type' => 'Forms$CompoundDesignPropertyValue',
        'Properties' => [2,
                         { '$ID' => 'top', '$Type' => 'Forms$DesignPropertyValue', 'Key' => 'margin-top',
                           'Value' => { '$ID' => 'option', '$Type' => 'Forms$OptionDesignPropertyValue',
                                        'Option' => 'L' } },
                         { '$ID' => 'striped', '$Type' => 'Forms$DesignPropertyValue', 'Key' => 'striped',
                           'Value' => { '$ID' => 'toggle', '$Type' => 'Forms$ToggleDesignPropertyValue' } }]
      }
    }

    node = codec.decode(document)
    ruby = Mxrb::Forms::SourceEmitter.new.emit(node)
    rebuilt = codec.encode(eval(ruby)) # rubocop:disable Security/Eval
    decoded = codec.decode(rebuilt)

    expect(node.value.schema_type.name).to eq('CompoundDesignPropertyValue')
    expect(node.value.properties.map(&:key)).to eq(%w[margin-top striped])
    expect(rebuilt.dig('Value', '$Type')).to eq('Forms$CompoundDesignPropertyValue')
    expect(rebuilt.dig('Value', 'Properties').first).to eq(2)
    expect(decoded.value.properties.first.value.option).to eq('L')
    expect(ruby).not_to include('{', '$ID', '$Type', 'native', 'opaque')
  end

  it 'upgrades flattened legacy design properties to native Mendix 11 values' do
    legacy = {
      '$ID' => 'legacy', '$Type' => 'Forms$DesignPropertyValue', 'Key' => 'Size',
      'Type' => 'DropDown', 'BooleanValue' => false, 'StringValue' => 'Large'
    }

    node = codec.decode(legacy)
    rebuilt = codec.encode(node)

    expect(node.value.option).to eq('Large')
    expect(rebuilt.dig('Value', '$Type')).to eq('Forms$OptionDesignPropertyValue')
    expect(rebuilt.dig('Value', 'Option')).to eq('Large')
    expect(rebuilt).not_to include('Type' => 'DropDown')
    expect(rebuilt).not_to have_key('BooleanValue')
    expect(rebuilt).not_to have_key('StringValue')
  end

  it 'uses the Studio collection contract for page parameters' do
    page = Mxrb::Forms.page do
      name 'Edit'
      set :parameters, []
    end

    expect(codec.encode(page).fetch('Parameters')).to eq([3])
  end

  it 'represents internal by-id pointers as semantic names and rebuilds fresh ids' do
    tabs = Mxrb::Forms.tab_container do
      name 'details'
      tab_pages(:tab_page) { name 'overview' }
      tab_pages(:tab_page) { name 'history' }
      default_page 'history'
    end

    encoded = codec.encode(tabs)
    decoded = codec.decode(encoded)
    rebuilt = codec.encode(decoded)
    pages = Mxrb::IO::BsonCodec.parse_array(rebuilt.fetch('TabPages')).fetch(:items)

    expect(decoded.default_page.target).to eq('history')
    expect(rebuilt.fetch('DefaultPagePointer')).to eq(pages.last.fetch('$ID'))
    expect(rebuilt.fetch('DefaultPagePointer')).not_to eq(encoded.fetch('DefaultPagePointer'))
  end

  it 'migrates legacy database constraints to the canonical Mendix 11 XPath source storage' do
    source = {
      '$ID' => 'ignored', '$Type' => 'Forms$NewGridDatabaseSource',
      'EntityRef' => nil, 'DatabaseConstraints' => [2, '[Active]', '[Visible]'],
      'SourceVariable' => nil
    }

    node = codec.decode(source)
    rebuilt = codec.encode(node)

    expect(node.x_path_constraint.clauses).to eq(%w[[Active] [Visible]])
    expect(rebuilt.fetch('$Type')).to eq('Forms$GridXPathSource')
    expect(rebuilt.fetch('XPathConstraint')).to eq('[Active][Visible]')
    expect(rebuilt).not_to have_key('DatabaseConstraints')
  end

  it 'keeps an empty legacy database constraint list empty through Ruby source' do
    source = {
      '$ID' => 'ignored', '$Type' => 'Forms$NewListViewDatabaseSource',
      'EntityRef' => nil, 'DatabaseConstraints' => [2], 'SourceVariable' => nil
    }
    node = codec.decode(source)
    ruby = Mxrb::Forms::SourceEmitter.new.emit(node)
    rebuilt = codec.encode(eval(ruby)) # rubocop:disable Security/Eval

    expect(ruby).to include('Mxrb::Forms::XPathConstraint.coerce([])')
    expect(ruby).not_to include('database_source!')
    expect(rebuilt.fetch('$Type')).to eq('Forms$ListViewXPathSource')
    expect(rebuilt.fetch('XPathConstraint')).to eq('')
    expect(rebuilt).not_to have_key('DatabaseConstraints')
  end

  it 'fails explicitly instead of erasing structured pre-10.5 database constraints' do
    source = {
      '$ID' => 'ignored', '$Type' => 'Forms$NewGridDatabaseSource',
      'EntityRef' => nil,
      'DatabaseConstraints' => [2, {
        '$ID' => 'constraint', '$Type' => 'Forms$DatabaseConstraint',
        'Attribute' => 'MyModule.Customer.Name', 'Operator' => 'Contains', 'Value' => 'Ada'
      }],
      'SourceVariable' => nil
    }

    expect { codec.decode(source) }
      .to raise_error(Mxrb::Forms::MprCodecError, /cannot be converted to XPath.*type context/)
  end

  it 'round-trips attribute and indirect entity references as typed values' do
    source = {
      '$ID' => 'ignored', '$Type' => 'Forms$GridSortItem', 'SortOrder' => 'Ascending',
      'AttributeRef' => {
        '$ID' => 'attribute', '$Type' => 'DomainModels$AttributeRef',
        'Attribute' => 'System.User.Name',
        'EntityRef' => {
          '$ID' => 'entity', '$Type' => 'DomainModels$IndirectEntityRef',
          'Steps' => [2, {
            '$ID' => 'step', '$Type' => 'DomainModels$EntityRefStep',
            'Association' => 'System.Session_User', 'DestinationEntity' => 'System.User'
          }]
        }
      }
    }

    node = codec.decode(source)
    rebuilt = codec.encode(node)
    reference = node.attribute_ref

    expect(reference.attribute).to eq('System.User.Name')
    expect(reference.entity_reference.steps.first.association).to eq('System.Session_User')
    expect(rebuilt.dig('AttributeRef', '$Type')).to eq('DomainModels$AttributeRef')
    expect(rebuilt.dig('AttributeRef', 'EntityRef', '$Type')).to eq('DomainModels$IndirectEntityRef')
  end

  it 'transcodes all 455 concrete widget property occurrences through typed storage' do
    catalog = Mxrb::Forms::Catalog.for('11.12.1')
    resolving_codec = described_class.new(
      reference_decoder: ->(value, _path) { value.to_s },
      reference_encoder: ->(target, _path) { target.to_s }
    )
    documents = catalog.concrete_widgets.flat_map do |widget|
      widget.all_properties.map do |property|
        node = Mxrb::Forms::Node.new(widget.name, catalog:)
        node.set(property.name, sample_value(property, catalog))
        encoded = resolving_codec.encode(node)
        resolving_codec.decode(encoded)
        encoded
      end
    end

    expect(documents.size).to eq(455)
    expect(documents).to all(include('$ID', '$Type'))
  end
end
