# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::Enumerations do
  around do |example|
    Dir.mktmpdir do |directory|
      Mxrb.define(File.join(directory, 'Enumerations.mpr')) do
        mendix_version '11.12.1'
        self.module :Views do
          enumeration :Mode do
            value :query, captions: { 'en_US' => 'Query', 'nl_NL' => 'Vraag' }
            value :form_post, captions: { 'nl_NL' => 'Formulier' }
          end
          entity(:Base) { enum :Mode, enumeration: 'Views.Mode' }
          entity(:Child) do
            generalizes 'Views.Base'
            string :Text
          end
        end
      end
      Mxrb.open(Mxrb.last_defined_path) do |project|
        @enumerations = described_class.new(project)
        example.run
      end
    end
  end

  it 'gives an enumeration attribute its key and enumeration, also through a generalization' do
    value = @enumerations.attribute_value('Views.Child', 'Mode', 'query')
    expect([value, value.enumeration]).to eq(%w[query Views.Mode])
    expect(@enumerations.attribute_value('Views.Base', 'Mode', 'Views.Mode.form_post')).to eq('form_post')
    expect(@enumerations.attribute_value('Views.Child', 'Text', 'query')).not_to be_a(described_class::Value)
    expect(@enumerations.attribute_value('Views.Missing', 'Mode', 'query')).not_to be_a(described_class::Value)
    expect(@enumerations.attribute_value('Views.Base', 'Mode', nil)).to be_nil
    expect(@enumerations.attribute_value('Views.Child', 'Other', 'x')).to eq('x')
  end

  it 'answers getCaption and getKey for literals, attribute values and other text' do
    stored = @enumerations.attribute_value('Views.Base', 'Mode', 'query')
    expect(@enumerations.text('getcaption', stored)).to eq('Query')
    expect(@enumerations.text('getcaption', 'Views.Mode.form_post')).to eq('Formulier')
    expect(@enumerations.text('getkey', 'Views.Mode.form_post')).to eq('form_post')
    expect(@enumerations.text('getcaption', 'System.ProxyConfiguration.Override')).to eq('Override')
    expect(@enumerations.text('getcaption', 'plain')).to eq('plain')
    expect([nil, ''].map { @enumerations.text('getcaption', _1) }).to eq(['', ''])
    expect(@enumerations.literal('Views.Mode.other')).to be_nil
    expect(@enumerations.literal('plain')).to be_nil
  end

  it 'reads a Ruby application, whose enumeration references may leave the module out' do
    attribute = Struct.new(:name, :enumeration)
    entity = Struct.new(:name, :attributes, :generalization_target)
    module_view = Struct.new(:name, :entities)
    project = Struct.new(:modules, :mendix_version) do
      def language_settings = { 'default' => 'en_US' }
      def enumeration_values(name) = name == 'Shop.Size' ? { 'S' => {}, 'M' => { 'de_DE' => 'Mittel' } } : nil
    end
    shop = module_view.new('Shop', [entity.new('Item', [attribute.new('Size', 'Size')], nil)])
    enumerations = described_class.new(project.new([shop], 'not a version'))
    small, medium = %w[S M].map { enumerations.attribute_value('Shop.Item', 'Size', _1) }
    expect([small.enumeration, enumerations.text('getcaption', small)]).to eq(%w[Shop.Size S])
    expect(enumerations.text('getcaption', medium)).to eq('Mittel')
    expect(enumerations.literal('Other.Kind.A')).to be_nil
    expect(Mxrb::RubyApp::RuntimeProject.allocate.enumeration_values('Nope.Nope')).to be_nil
  end

  it 'rejects getCaption without one value or without enumerations' do
    expression = Mxrb::Runtime::Native::Expression.new
    expect { expression.evaluate("getCaption('x')", {}) }.to raise_error(Mxrb::NativeRuntimeError)
    with = Mxrb::Runtime::Native::Expression.new(enumerations: @enumerations)
    expect { with.evaluate("getKey('a', 'b')", {}) }.to raise_error(Mxrb::NativeRuntimeError)
  end
end
# rubocop:enable Metrics/BlockLength
