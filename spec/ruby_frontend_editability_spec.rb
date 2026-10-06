# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Ruby frontend input editability' do # rubocop:disable Metrics/BlockLength
  def template(text)
    { '$Type' => 'Forms$ClientTemplate', 'Template' => {
      'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => text }]
    } }
  end

  def find_input(value)
    return value if value.is_a?(Hash) && value['$Type'] == 'Forms$TextBox'

    children = value.is_a?(Hash) ? value.values : Array(value)
    children.filter_map { find_input(_1) if _1.is_a?(Hash) || _1.is_a?(Array) }.first
  end

  it 'projects formerly baseline-only input properties into Ruby options' do
    page = Mxrb::Model::Page.allocate
    source = {
      'Editable' => 'Conditional', 'ReadOnlyStyle' => 'Text',
      'ConditionalEditabilitySettings' => { 'Expression' => '$currentObject/Active' },
      'PlaceholderTemplate' => template('Enter name'), 'ScreenReaderLabel' => template('Accessible name'),
      'IsPasswordBox' => true, 'MaxLengthCode' => 12, 'AriaRequired' => true,
      'TabIndex' => 3, 'Autocomplete' => true, 'AutocompletePurpose' => 'GivenName'
    }
    expect(page.send(:input_options, source)).to eq(
      editable: :conditional, read_only_style: :text,
      editability: { expression: '$currentObject/Active' },
      placeholder: 'Enter name', aria_label: 'Accessible name', password: true,
      max_length: 12, aria_required: true, tab_index: 3, autocomplete: 'given-name'
    )
    expect(page.send(:input_options, {})).to eq({})
    expect(page.send(:input_options, 'Autocomplete' => false)).to eq(autocomplete: 'off')
    expect(page.send(:input_options, 'Autocomplete' => true)).to eq(autocomplete: 'on')
    expect(page.send(:input_options, 'AutocompletePurpose' => 'Off')).to eq(autocomplete: 'off')
    expect(page.send(:input_options, 'AutocompletePurpose' => 'FullName')).to eq(autocomplete: 'name')
    expect(page.send(:input_options, 'AutocompletePurpose' => 'CreditCardNumber')).to eq(autocomplete: 'cc-number')
  end

  it 'keeps nested input options typed and rejects unknown presentation keywords' do
    expect { Mxrb::Dsl::WidgetSlotBuilder.new.text_box('Name', mystery: true) }
      .to raise_error(ArgumentError, /unknown input options: mystery/)
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    expect(builder.input_condition('$currentObject/Active')).to eq(expression: '$currentObject/Active')
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    expect(tree.input_condition('true')).to eq(expression: 'true')
    exporter = Mxrb::RubyApp::Exporter.allocate
    [nil, {}].each do |condition|
      widget = { 'type' => 'text_box', 'name' => 'Name', 'options' => { 'editability' => condition } }
      expect(exporter.send(:runtime_widget_call_source, widget, 0)).to include('editability:')
    end
  end

  it 'exports input settings as editable application source and serves Ruby changes without compiling Mendix' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir('mxrb-editable-input-') do |root| # rubocop:disable Metrics/BlockLength
      source = File.join(root, 'Source.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) do
          entity(:Item) { string :Name }
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
        field = find_input(document)
        field.merge!('Editable' => 'Never', 'ReadOnlyStyle' => 'Text',
                     'ConditionalEditabilitySettings' => { 'Expression' => '$currentObject/Active' },
                     'PlaceholderTemplate' => template('Original placeholder'), 'IsPasswordBox' => true)
        project.mpr.update_unit(page.id, document)
      end
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      path = File.join(target, 'app', 'pages', 'app', 'home_page.rb')
      code = File.read(path)
      expect(code).to include('editable: "never"', 'password: true', 'placeholder: "Original placeholder"')
      expect(code).to include('input_condition("$currentObject/Active")')
      expect(Mxrb::PublicSourceAudit.new(target)).to be_clean
      File.write(path, code.sub('editable: "never"', 'editable: "always"')
                           .sub('Original placeholder', 'Edited in Ruby'))
      application = Mxrb::RubyApp::Application.new(target)
      layout = application.page('App.Home').fetch(:widgets).first
      expect(layout.dig('options', 'class')).to include('mxrb-application-shell')
      content = layout.fetch('children').first.dig('regions', 'center')
      widget = content.first.fetch('body').first
      expect(widget.fetch('options')).to include(
        'editable' => 'always', 'placeholder' => 'Edited in Ruby', 'password' => true
      )
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end
end
