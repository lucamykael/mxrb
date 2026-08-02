# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::TranslationMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:App) do
          enumeration(:State) { value :Open, caption: "Open:=#!\nitem" }
        end
      end
      prepare_catalog
      example.run
    end
  end

  def prepare_catalog
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    value = Mxrb::IO::BsonCodec.parse_array(
      source.documents('Enumerations$Enumeration').first['Values']
    )[:items].first
    @text_id = Mxrb::IO::BsonCodec.extract_id(value.dig('Caption', '$ID'))
    directory = File.join(@deployment, 'model', 'i18n')
    FileUtils.mkdir_p(directory)
    content = "# existing Runtime strings\n#{@text_id}=stale\n"
    File.write(File.join(directory, 'translations_en_US.properties'), content)
    File.write(File.join(directory, 'translations.properties'), content)
  end

  it 'updates source strings while preserving unrelated Runtime catalog lines' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    localized = File.read(File.join(result.directory, 'translations_en_US.properties'))
    default = File.read(File.join(result.directory, 'translations.properties'))

    expect(result.languages).to include('en_US')
    expect(result.files).to eq(result.languages.length + 1)
    expect(result.strings).to be_positive
    expect(localized).to include('# existing Runtime strings')
    expect(localized).to include("#{@text_id}=Open\\:\\=\\#\\!\\nitem")
    expect(default).to include("#{@text_id}=Open\\:\\=\\#\\!\\nitem")
  end

  it 'ignores malformed texts and selects a non-English default when needed' do
    materializer = described_class.new(@mpr, deployment: @deployment)
    result = Hash.new { |hash, language| hash[language] = {} }
    materializer.send(:collect_text, { '$Type' => 'Texts$Text' }, result)
    materializer.send(
      :collect_text,
      { '$ID' => @text_id, '$Type' => 'Texts$Text',
        'Items' => [{ '$Type' => 'Texts$Translation', 'LanguageCode' => '', 'Text' => 'ignored' }] },
      result
    )
    expect(result).to be_empty

    materializer.send(:write_default, File.join(@deployment, 'model', 'i18n'),
                      'de_DE' => { @text_id => 'Deutsch' })
    expect(File.read(File.join(@deployment, 'model', 'i18n', 'translations.properties')))
      .to include("#{@text_id}=Deutsch")
  end
end
# rubocop:enable Metrics/BlockLength
