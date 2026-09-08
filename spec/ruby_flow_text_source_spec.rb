# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby flow text declarations' do
  after { Mxrb::RubyApp::Registry.reset! }

  def flow_builder
    Mxrb::Dsl::FlowBuilder.new('Text', runtime: nil, kind: :microflow, public: false)
  end

  it 'keeps legacy and block values equivalent including locale order, nil, false and empty text' do
    legacy = flow_builder
    typed = flow_builder
    translations = { 'pt_BR' => '', 'en_US' => nil, 'nl_NL' => false }
    parameters = [nil, false, 0, '$Item/Name']
    %i[show_message validation_feedback].each do |method|
      legacy.public_send(method, 'Item', translations:, parameters:)
      typed.public_send(method, 'Item') do |text|
        translations.each { |language, value| text.translation(language, value) }
        parameters.each { text.parameter(_1) }
      end
    end
    expect(typed.to_h.fetch(:body)).to eq(legacy.to_h.fetch(:body))
    expect(typed.to_h.fetch(:body).first.fetch(:translations).keys).to eq(%w[pt_BR en_US nl_NL])
  end

  it 'distinguishes default messages from explicit empty translations without adding en_US' do
    builder = flow_builder
    builder.show_message('Default')
    builder.show_message('Unused') { |_text| }
    builder.validation_feedback('Item') { |_text| }
    actions = builder.to_h.fetch(:body)
    expect(actions.map { _1[:translations] }).to eq([nil, {}, {}])
    expect(actions.first[:text]).to eq('Default')
  end

  it 'rejects mixed options, duplicate languages and unsupported text atomically' do
    builder = flow_builder
    %i[show_message validation_feedback].each do |method|
      expect { builder.public_send(method, 'Item', translations: {}) { translation 'en_US', 'A' } }
        .to raise_error(ArgumentError, /either/)
      expect do
        builder.public_send(method, 'Item') do
          translation 'en_US', 'A'
          translation :en_US, 'B'
        end
      end.to raise_error(ArgumentError, /duplicate/)
      expect { builder.public_send(method, 'Item') { translation 'en_US', { unknown: 'structure' } } }
        .to raise_error(TypeError, /scalar/)
    end
    expect(builder.to_h.fetch(:body)).to be_nil
  end

  it 'rolls back a reusable text builder after a failed block' do
    builder = Mxrb::Dsl::FlowTextBuilder.new
    builder.translation('pt_BR', 'Original')
    expect do
      builder.evaluate do
        parameter '$Value'
        translation 'en_US', 'Partial'
        raise 'stop'
      end
    end.to raise_error(RuntimeError, 'stop')
    expect(builder.translations).to eq('pt_BR' => 'Original')
    expect(builder.parameters).to eq([])
  end

  it 'preserves a sole non-English translation and rejects duplicate native locales explicitly' do
    emitter = Mxrb::Exporter.allocate
    action = { '$Type' => 'Microflows$ShowMessageAction', 'Type' => 'Information', 'Template' => {
      'Text' => { 'Items' => [3, { 'LanguageCode' => 'pt_BR', 'Text' => '' }] }, 'Parameters' => [2]
    } }
    source = emitter.send(:action_dsl_line, { 'Action' => action }, 0)
    expect(source).to include('translation "pt_BR", ""')
    expect(source).not_to include('en_US', '{', 'translations:')
    builder = flow_builder
    builder.instance_eval(source)
    expect(builder.to_h.fetch(:body).first[:translations]).to eq('pt_BR' => '')
    action['Template']['Text']['Items'] << { 'LanguageCode' => 'pt_BR', 'Text' => 'Duplicate' }
    expect { emitter.send(:action_dsl_line, { 'Action' => action }, 0) }
      .to raise_error(Mxrb::SerializationError, /unsupported flow text declaration/)
  end

  def flow_bytes(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true)
    mpr.all_units.filter_map do |unit|
      next unless mpr.parse_contents(unit)['$Type'] == 'Microflows$Microflow'

      [unit.fetch('UnitID'), mpr.content_bytes(unit)]
    end.to_h
  ensure
    mpr&.close
  end

  it 'roundtrips messages and feedback byte-exactly and persists authoritative translation edits' do
    Dir.mktmpdir('mxrb-flow-text-') do |directory|
      original = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      Mxrb.define(original) do
        mendix_version '11.12.1'
        self.module(:App) do
          entity(:Item) { string :Name }
          microflow(:Notify) do
            parameter :Item, type: 'App.Item'
            show_message 'Unused', translations: { 'pt_BR' => 'Somente português {1}' }, parameters: ['$Item/Name']
            show_message 'Unused', translations: {}
            validation_feedback :Item, attribute: 'App.Item.Name', translations: {
              'nl_NL' => '', 'pt_BR' => 'Obrigatório {1}', 'en_US' => 'Required {1}'
            }, parameters: ['$Item/Name']
          end
        end
      end
      before = flow_bytes(original)
      Mxrb::Exporter.new(original, output, mode: :ruby).export!
      source_path = File.join(output, 'app', 'services', 'app', 'notify.rb')
      source = File.read(source_path)
      expect(source).to include('translation "pt_BR", "Somente português {1}"', 'parameter "$Item/Name"')
      expect(source).not_to include('translations:', '=>')
      Mxrb::RubyApp.compile(output, rebuilt)
      expect(flow_bytes(rebuilt)).to eq(before)
      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      Mxrb::RubyApp.compile(restored, File.join(directory, 'Restored.mpr'))
      expect(flow_bytes(File.join(directory, 'Restored.mpr'))).to eq(before)

      File.write(source_path, source.sub('Obrigatório {1}', 'Atualizado {1}'))
      Mxrb::RubyApp.compile(output, rebuilt)
      edited = File.join(directory, 'edited')
      Mxrb::Exporter.new(rebuilt, edited, mode: :ruby).export!
      result = File.read(File.join(edited, 'app', 'services', 'app', 'notify.rb'))
      expect(result).to include('translation "pt_BR", "Atualizado {1}"', 'translation "nl_NL", ""',
                                'translation "en_US", "Required {1}"', 'parameter "$Item/Name"')
      expect(result).not_to include('Obrigatório {1}')
    end
  end
end
# rubocop:enable Metrics/BlockLength
