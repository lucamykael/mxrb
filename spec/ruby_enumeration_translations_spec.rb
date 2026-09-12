# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby enumeration translation blocks' do
  after { Mxrb::RubyApp::Registry.reset! }

  def enumeration_document(path)
    Mxrb.open(path) { _1.modules.find { |mod| mod.name == 'Catalog' }.enumerations.first }
  end

  it 'keeps the legacy caption options and typed blocks semantically equivalent' do
    legacy = Class.new(Mxrb::RubyApp::Enumeration)
    typed = Class.new(Mxrb::RubyApp::Enumeration)
    legacy.value('Ready', captions: { 'pt_BR' => 'Pronto', 'en_US' => '', 'nl_NL' => 'Gereed' })
    typed.value('Ready') do
      translation 'pt_BR', 'Pronto'
      translation 'en_US', ''
      translation 'nl_NL', 'Gereed'
    end

    expect(typed.values).to eq(legacy.values)
    expect(typed.values.first[:captions].keys).to eq(%w[pt_BR en_US nl_NL])
    typed.value('Empty') { |_captions| }
    typed.value('Default')
    typed.value('Short', caption: 'Short caption')
    expected = [{}, { 'en_US' => 'Default' }, { 'en_US' => 'Short caption' }]
    expect(typed.values.last(3).map { _1[:captions] }).to eq(expected)
  end

  it 'supports a block argument and rejects conflicting caption sources atomically' do
    enum = Class.new(Mxrb::RubyApp::Enumeration)
    enum.value('Ready') { |value| value.translation('pt_BR', 'Pronto') }

    expect(enum.values.first[:captions]).to eq('pt_BR' => 'Pronto')
    expect { enum.value('Invalid', caption: 'Caption') { translation 'pt_BR', 'Outro' } }
      .to raise_error(ArgumentError, /either caption options or a translation block/)
    expect(enum.values.size).to eq(1)
  end

  it 'exports hash-free captions and persists edits while retaining native identities and languages' do
    Dir.mktmpdir('mxrb-enum-translations-') do |directory|
      source = File.join(directory, 'Source.mpr')
      exported = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:Catalog) do
          enumeration :State do
            value :Ready, captions: { 'pt_BR' => 'Pronto', 'en_US' => '', 'nl_NL' => 'Gereed' }
            value :Untranslated, captions: {}
          end
        end
      end
      original = enumeration_document(source)
      Mxrb::Exporter.new(source, exported, mode: :ruby).export!
      path = File.join(exported, 'app', 'enumerations', 'catalog', 'state.rb')
      ruby = File.read(path)

      expect(ruby).to include('translation "pt_BR", "Pronto"', 'translation "en_US", ""')
      expect(ruby).not_to include('captions:', '{', '=>')
      Mxrb::RubyApp.compile(exported, rebuilt)
      expect(enumeration_document(rebuilt)).to eq(original)

      File.write(path, ruby.sub('translation "pt_BR", "Pronto"', 'translation "pt_BR", "Atualizado"'))
      Mxrb::RubyApp.compile(exported, rebuilt)
      changed = enumeration_document(rebuilt)
      expected = Marshal.load(Marshal.dump(original))
      ready = expected.fetch('Values').drop(1).find { _1['Name'] == 'Ready' }
      translation = ready.fetch('Caption').fetch('Items').drop(1).find { _1['LanguageCode'] == 'pt_BR' }
      translation['Text'] = 'Atualizado'
      expect(changed).to eq(expected)

      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      Mxrb::RubyApp.compile(restored, File.join(directory, 'Restored.mpr'))
      expect(enumeration_document(File.join(directory, 'Restored.mpr'))).to eq(expected)
    end
  end
end
# rubocop:enable Metrics/BlockLength
