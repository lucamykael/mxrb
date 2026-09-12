# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Pluggable schema storage aliases' do
  let(:registry) { Mxrb::Pluggable::Catalog.new }
  let(:codec) { Mxrb::Forms::MprCodec.new(pluggable_catalog: registry) }
  let(:widget_id) { 'com.example.LegacySchema' }

  before do
    Mxrb::Pluggable.widget_type(widget_id, catalog: registry) do
      name 'Legacy name'
      description 'Legacy description'
      needs_context!
      plugin!
      properties do
        property 'caption', :string
        property 'status', :enumeration do
          choice 'open', 'Open'
          choice 'closed', 'Closed'
        end
        property 'onClick', :action do
          action_variable 'currentObject', :object, 'Current object'
        end
        property 'columns', :object do
          list!
          properties do
            property 'attribute', :attribute do
              attribute_type :string
              attribute_type :integer
            end
          end
        end
      end
    end
  end

  def bytes(document) = Mxrb::IO::BsonCodec.serialize(document)

  def walk(value, &block)
    case value
    when Hash
      yield value
      value.each_value { walk(_1, &block) }
    when Array
      value.each { walk(_1, &block) }
    end
  end

  def move_field(document, from, to)
    document[to] = document.delete(from)
  end

  def legacy_schema!(schema, property_key) # rubocop:disable Metrics/MethodLength
    walk(schema) do |document|
      case document['$Type']
      when 'CustomWidgets$CustomWidgetType'
        move_field(document, 'WidgetName', 'Name')
        move_field(document, 'WidgetDescription', 'Description')
        move_field(document, 'WidgetNeedsEntityContext', 'NeedsEntityContext')
        move_field(document, 'WidgetPluginWidget', 'PluginWidget')
      when 'CustomWidgets$WidgetPropertyType'
        move_field(document, 'PropertyKey', property_key)
      when 'CustomWidgets$WidgetValueType'
        move_field(document, 'AllowedTypes', 'AttributeTypes')
      when 'CustomWidgets$WidgetEnumerationValue'
        move_field(document, '_Key', 'Key')
      when 'CustomWidgets$WidgetActionVariable'
        move_field(document, 'Key', '_Key')
      end
    end
  end

  %w[_Key Key].each do |property_key|
    it "preserves legacy aliases including #{property_key}, BSON order, and edited values" do
      node = Mxrb::Pluggable.widget(widget_id, catalog: registry) do
        identifier 'legacy'
        properties do
          caption 'Before'
          status 'open'
          columns { attribute 'Sales.Order.Name' }
        end
      end
      baseline = codec.encode(node)
      legacy_schema!(baseline.fetch('Type'), property_key)
      original_bytes = bytes(baseline.fetch('Type'))
      decoded = codec.decode(baseline)
      decoded.object.set(:caption, 'After')
      rebuilt = codec.encode(decoded, baseline:)

      expect(bytes(rebuilt.fetch('Type'))).to eq(original_bytes)
      expect(bytes(baseline.fetch('Type'))).to eq(original_bytes)
      expect(codec.decode(rebuilt).object.fetch(:caption)).to eq('After')
      expected_aliases = {
        'Name' => 'Legacy name', 'Description' => 'Legacy description',
        'NeedsEntityContext' => true, 'PluginWidget' => true
      }
      expect(rebuilt.fetch('Type')).to include(expected_aliases)
      expected_pointers = []
      actual_pointers = []
      walk(baseline.fetch('Object')) { expected_pointers << _1['TypePointer'] if _1.key?('TypePointer') }
      walk(rebuilt.fetch('Object')) { actual_pointers << _1['TypePointer'] if _1.key?('TypePointer') }
      expect(actual_pointers.sort).to eq(expected_pointers.sort)
    end
  end

  it 'keeps modern field order and absent options while encoding edited values' do
    node = Mxrb::Pluggable.widget(widget_id, catalog: registry)
    node.object.set(:caption, 'Before')
    baseline = codec.encode(node)
    walk(baseline.fetch('Type')) do |document|
      document.delete('Prompt')
      document.replace(document.sort.to_h)
    end
    original_bytes = bytes(baseline.fetch('Type'))
    decoded = codec.decode(baseline)
    decoded.object.set(:caption, 'After')
    rebuilt = codec.encode(decoded, baseline:)

    expect(bytes(rebuilt.fetch('Type'))).to eq(original_bytes)
    expect(codec.decode(rebuilt).object.fetch(:caption)).to eq('After')
  end

  it 'rejects the unrepresented PhoneGap field rather than silently dropping it' do
    node = Mxrb::Pluggable.widget(widget_id, catalog: registry)
    baseline = codec.encode(node)

    [true, false].each do |enabled|
      baseline.fetch('Type')['WidgetPhoneGapEnabled'] = enabled
      expect { codec.decode(baseline) }
        .to raise_error(Mxrb::Pluggable::UnsupportedStoragePropertyError, /WidgetPhoneGapEnabled/)
      expect { codec.encode(node, baseline:) }
        .to raise_error(Mxrb::Pluggable::UnsupportedStoragePropertyError, /WidgetPhoneGapEnabled/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
