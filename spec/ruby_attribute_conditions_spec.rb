# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Ruby attribute-based widget conditions' do # rubocop:disable Metrics/BlockLength
  let(:condition_values) { [%w[true true], %w[false false]].map { |value, on| [value, on == 'true'] } }

  def model_condition(value, matches)
    { '$ID' => SecureRandom.uuid, '$Type' => 'Enumerations$Condition', 'AttributeValue' => value,
      'EditableVisible' => matches }
  end

  def find_input(value)
    return value if value.is_a?(Hash) && value['$Type'] == 'Forms$TextBox'

    children = value.is_a?(Hash) ? value.values : Array(value)
    children.filter_map { find_input(_1) if _1.is_a?(Hash) || _1.is_a?(Array) }.first
  end

  it 'declares attribute values as pairs of value and match' do
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    source = builder.page_variable('Details', kind: :widget)
    expect(builder.input_condition(attribute: 'App.Item.Unlocked', conditions: condition_values, source:)).to eq(
      attribute: 'App.Item.Unlocked', source_variable: { kind: :widget, name: 'Details' },
      conditions: [{ 'AttributeValue' => 'true', 'EditableVisible' => true },
                   { 'AttributeValue' => 'false', 'EditableVisible' => false }]
    )
    expect(builder.input_condition('$currentObject/Unlocked')).to eq(expression: '$currentObject/Unlocked')
    expect(builder.input_condition('$currentObject/Unlocked', source:))
      .to eq(expression: '$currentObject/Unlocked', source_variable: { kind: :widget, name: 'Details' })
    expect(builder.input_condition(conditions: [['true', true]]))
      .to eq(conditions: [{ 'AttributeValue' => 'true', 'EditableVisible' => true }])
    expect { builder.input_condition(attribute: 'App.Item.Unlocked', conditions: [%w[true yes]]) }
      .to raise_error(ArgumentError, /\[value, true\|false\]/)
    document = model_condition('Draft', true)
    expect(Mxrb::Dsl.attribute_conditions([document, ['(empty)', false]]))
      .to eq([document, { 'AttributeValue' => '(empty)', 'EditableVisible' => false }])
  end

  it 'exports input conditions without model identities' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    identity = { '$binary' => 'AAAAAAAAAAAAAAAAAAAAAA==', '$subtype' => 'generic' }
    conditions = [{ '$ID' => identity, '$Type' => 'Enumerations$Condition', 'AttributeValue' => 'true',
                    'EditableVisible' => true }, { 'AttributeValue' => '(empty)', 'EditableVisible' => false }]
    expect(exporter.send(:runtime_input_condition_source,
                         'attribute' => 'App.Item.Unlocked', 'conditions' => conditions,
                         'source_variable' => { 'kind' => 'widget', 'name' => 'Details' }))
      .to eq('input_condition(attribute: "App.Item.Unlocked", conditions: [["true", true], ["(empty)", false]], ' \
             'source: page_variable("Details", kind: :widget))')
    expect(exporter.send(:runtime_input_condition_source, 'attribute' => 'App.Item.Unlocked',
                                                          'conditions' => conditions))
      .to eq('input_condition(attribute: "App.Item.Unlocked", conditions: [["true", true], ["(empty)", false]])')
    expect(exporter.send(:runtime_input_condition_source, 'expression' => 'true', 'source_variable' => {
      'kind' => 'current'
    }))
      .to eq('input_condition("true", source: page_variable(nil, kind: :current))')
  end

  it 'keeps unsupported condition shapes generic and types data view conditions' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    conditions = [{ 'AttributeValue' => 'true', 'EditableVisible' => true },
                  { 'AttributeValue' => '(empty)', 'EditableVisible' => false }]
    [nil, {}, { 'roles' => ['App.User'] }, { 'expression' => 1 },
     { 'attribute' => 'A.B.C', 'conditions' => [{ 'AttributeValue' => 'x' }] },
     { 'attribute' => 'A.B.C', 'conditions' => [{ '$Type' => 'Other', 'AttributeValue' => 'x',
                                                  'EditableVisible' => true }] },
     { 'expression' => 'true', 'source_variable' => { 'kind' => 'mystery' } }].each do |condition|
      expect(exporter.send(:runtime_input_condition_source, condition)).to be_nil
    end
    expect(exporter.send(:runtime_data_view_condition_source, 'editable_when',
                         { 'attribute' => 'App.Item.Stage', 'conditions' => conditions,
                           'source_variable' => { 'kind' => 'widget', 'name' => 'Details' } }, 0))
      .to eq(<<~RUBY.chomp)
        editable_when(
          attribute: "App.Item.Stage",
          conditions: [["true", true], ["(empty)", false]],
          source: page_variable("Details", kind: :widget)
        )
      RUBY
  end

  it 'writes DSL pairs as model conditions' do
    Dir.mktmpdir('mxrb-attribute-conditions-') do |root|
      source = File.join(root, 'Conditions.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) do
          entity(:Item) { boolean :Unlocked }
          page(:Home) do
            data_view :Details, from: context(entity: 'App.Item'), editable: :conditional do
              editable_when attribute: 'App.Item.Unlocked', conditions: [['true', true], ['false', false]]
              body { text :Heading, caption: 'Item' }
            end
          end
        end
      end
      Mxrb.open(source) do |project|
        view = project.modules.first.pages.first.widgets.find { _1[:type] == :data_view }
        expect(view.dig(:options, :editability, :conditions).map { _1.slice('AttributeValue', 'EditableVisible') })
          .to eq([{ 'AttributeValue' => 'true', 'EditableVisible' => true },
                  { 'AttributeValue' => 'false', 'EditableVisible' => false }])
      end
    end
  end

  it 'exports attribute-based input editability as clean application source' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir('mxrb-attribute-conditions-') do |root| # rubocop:disable Metrics/BlockLength
      source = File.join(root, 'Source.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) do
          entity(:Item) do
            string :Name
            boolean :Unlocked
          end
          page(:Home) do
            data_view :Details, from: context(entity: 'App.Item') do
              body { text_box :Name, attribute: 'App.Item.Name', caption: 'Name' }
            end
          end
        end
      end
      Mxrb.open(source, readonly: false) do |project|
        page = project.modules.first.pages.first
        document = page.raw_document
        find_input(document).merge!(
          'Editable' => 'Conditional',
          'ConditionalEditabilitySettings' => {
            '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ConditionalEditabilitySettings',
            'Attribute' => 'App.Item.Unlocked', 'Expression' => '', 'IgnoreSecurity' => false,
            'Conditions' => Mxrb::IO::BsonCodec.build_array(
              [model_condition('true', true), model_condition('false', false)], marker: 2
            ),
            'ModuleRoles' => Mxrb::IO::BsonCodec.build_array([], marker: 1),
            'SourceVariable' => { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$PageVariable',
                                  'Widget' => 'Details', 'UseAllPages' => false }
          }
        )
        project.mpr.update_unit(page.id, document)
      end
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      code = File.read(File.join(target, 'app', 'pages', 'app', 'home_page.rb'))
      expect(code).to include('editability: input_condition(attribute: "App.Item.Unlocked", ' \
                              'conditions: [["true", true], ["false", false]], ' \
                              'source: page_variable("Details", kind: :widget))')
      expect(Mxrb::PublicSourceAudit.new(target)).to be_clean
      application = Mxrb::RubyApp::Application.new(target)
      layout = application.page('App.Home').fetch(:widgets).first
      widget = layout.fetch('children').first.dig('regions', 'center').first.fetch('body').first
      expect(widget.dig('options', 'editability')).to eq(
        'attribute' => 'App.Item.Unlocked', 'source_variable' => { 'kind' => 'widget', 'name' => 'Details' },
        'conditions' => [{ 'AttributeValue' => 'true', 'EditableVisible' => true },
                         { 'AttributeValue' => 'false', 'EditableVisible' => false }]
      )
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end
end
