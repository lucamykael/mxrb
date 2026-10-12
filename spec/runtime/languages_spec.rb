# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::Runtime::Languages do # rubocop:disable Metrics/BlockLength
  # The store calls synchronize makes, over in-memory System.Language objects.
  def language_store
    language = Data.define(:id, :members)
    Class.new do
      attr_reader :commits

      define_method(:initialize) { (@objects = []) && (@commits = 0) }
      define_method(:retrieve) { |_entity| @objects.dup }
      define_method(:create) { |_entity| language.new(@objects.size.to_s, {}).tap { @objects << _1 } }
      define_method(:commit) { |_object| @commits += 1 }
    end.new
  end

  it 'describes languages as the Runtime does' do
    expect(described_class.description('en_US')).to eq('English, United States')
    expect(described_class.description('pt_BR')).to eq('Portuguese, Brazil')
    expect(described_class.description('nl')).to eq('Dutch')
    expect(described_class.description('xx_QQ')).to eq('xx, QQ')
  end

  it 'reads the project languages from the model or the Ruby manifest' do
    settings = { '$Type' => 'Settings$LanguageSettings', 'DefaultLanguageCode' => 'nl_NL',
                 'Languages' => [2, { 'Code' => 'en_US' }, { 'Code' => 'nl_NL' }] }
    root = { '$Type' => 'Settings$ProjectSettings', 'Settings' => [2, settings] }
    project = double('project', all_units: [root, { '$Type' => 'Other' }])
    allow(project).to receive(:parse_bson) { _1 }
    expect(described_class.settings(project)).to eq('default' => 'nl_NL', 'codes' => %w[en_US nl_NL])
    empty = double('project', all_units: [])
    allow(empty).to receive(:parse_bson) { _1 }
    expect(described_class.settings(empty)).to eq({})
    expect(described_class.settings(Object.new)).to eq({})
    runtime = double('runtime', language_settings: { 'default' => 'en_US' })
    expect(described_class.settings(runtime)).to eq('default' => 'en_US')
  end

  it 'keeps one System.Language per project language' do
    store = language_store
    described_class.synchronize(store, 'codes' => %w[en_US pt_BR])
    expect(store.retrieve('System.Language').map(&:members))
      .to eq([{ 'Code' => 'en_US', 'Description' => 'English, United States' },
              { 'Code' => 'pt_BR', 'Description' => 'Portuguese, Brazil' }])
    commits = store.commits
    described_class.synchronize(store, 'codes' => %w[en_US])
    expect(store.commits).to eq(commits)
    described_class.synchronize(store, {})
    expect(store.retrieve('System.Language').size).to eq(2)
  end
end
