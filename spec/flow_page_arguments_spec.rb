# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'typed flow page arguments' do # rubocop:disable Metrics/BlockLength
  def builder
    Mxrb::Dsl::FlowBuilder.new(:Open, runtime: :server, kind: :microflow, public: false)
  end

  it 'matches the legacy declaration while preserving argument and translation order' do
    legacy = builder
    legacy.show_page('App.Detail', object: :Item, location: :popup, close_pages: 0,
                                   pass: { 'App.Detail.Item' => '$Item', 'App.Detail.Enabled' => false },
                                   title: { 'pt_BR' => '', 'en_US' => 'Details' })
    typed = builder
    typed.show_page('App.Detail', object: :Item, location: :popup, close_pages: 0) do
      argument 'App.Detail.Item', '$Item'
      argument 'App.Detail.Enabled', false
      title do
        translation 'pt_BR', ''
        translation 'en_US', 'Details'
      end
    end

    expect(typed.to_h.fetch(:body)).to eq(legacy.to_h.fetch(:body))
  end

  it 'preserves duplicate mappings and distinguishes an absent title from an empty one' do
    flow = builder
    flow.show_page('App.Detail') do |page|
      page.argument('Value', nil)
      page.argument('Value', '')
    end
    flow.show_page('App.Detail') { title {} }

    absent, empty = flow.to_h.fetch(:body)
    expect(absent.fetch(:mappings)).to eq([{ parameter: 'Value', value: nil }, { parameter: 'Value', value: '' }])
    expect(absent.fetch(:title)).to be_nil
    expect(empty.fetch(:title)).to eq({})
  end

  it 'snapshots captured builders and retains legacy scalar title values' do
    flow = builder
    captured = nil
    argument = +'$Item'
    flow.show_page('App.Detail') do |page|
      captured = page
      page.argument('Item', argument)
      page.title do
        translation 'pt_BR', nil
        translation 'en_US', false
      end
    end
    captured.argument('Later', 1)
    argument.replace('$Other')
    activity = flow.to_h.fetch(:body).first

    expect(activity.fetch(:mappings)).to eq([{ parameter: 'Item', value: '$Item' }])
    expect(activity.fetch(:title)).to eq('pt_BR' => nil, 'en_US' => false)
    expect(activity.fetch(:mappings)).to be_frozen
    expect(activity.fetch(:mappings).first).to be_frozen
    expect(activity.fetch(:title)).to be_frozen
  end

  it 'rejects mixed notation and failing or duplicate title blocks without adding partial activities' do
    flow = builder
    expect { flow.show_page('App.Detail', pass: {}) { argument 'Value', 1 } }
      .to raise_error(ArgumentError, /either pass:/)
    expect { flow.show_page('App.Detail', title: {}) { title {} } }
      .to raise_error(ArgumentError, /either pass:/)
    expect do
      flow.show_page('App.Detail') do
        argument 'Value', 1
        title do
          translation 'en_US', 'First'
          translation 'en_US', 'Second'
        end
      end
    end.to raise_error(ArgumentError, /duplicate page title language/)
    expect do
      flow.show_page('App.Detail') do
        title {}
        title {}
      end
    end.to raise_error(ArgumentError, /already declared/)
    expect(Array(flow.to_h.fetch(:body))).to be_empty
  end

  it 'emits an explicitly empty native title and refuses to collapse duplicate native languages' do
    title = { '$Type' => 'Texts$Text', 'Items' => [3] }
    action = { 'FormSettings' => { 'Form' => 'App.Detail', 'TitleOverride' => title } }
    emitter = Mxrb::Exporter.allocate
    source = emitter.send(:show_page_action_line, action, 0)
    flow = builder
    flow.instance_eval(source)
    expect(flow.to_h.dig(:body, 0, :title)).to eq({})

    title.fetch('Items').concat([
                                  { 'LanguageCode' => 'en_US', 'Text' => 'First' },
                                  { 'LanguageCode' => 'en_US', 'Text' => 'Second' }
                                ])
    expect { emitter.send(:show_page_action_line, action, 0) }
      .to raise_error(Mxrb::SerializationError, /duplicate page title language/)
  end

  it 'exports, recompiles and edits a localized page action through the public Ruby source' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir('mxrb-flow-page-arguments-') do |directory| # rubocop:disable Metrics/BlockLength
      source = File.join(directory, 'Source.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) do
          entity(:Item) { string :Name }
          page(:Detail) { title 'Detail' }
          microflow(:Open) do
            parameter :Item, type: 'App.Item'
            show_page 'App.Detail', pass: { 'App.Detail.Item' => '$Item' },
                                    title: { 'pt_BR' => '', 'en_US' => 'Original' }, close_pages: 0
          end
        end
      end
      root = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, root, mode: :ruby).export!
      file = Dir.glob(File.join(root, 'app', 'services', '**', '*.rb')).first
      text = File.read(file)
      expect(text).to include('show_page "App.Detail", close_pages: 0 do',
                              'argument "App.Detail.Item", "$Item"', 'translation "pt_BR", ""')
      expect(text).not_to include('pass:', 'title: {')
      expect(Ripper.sexp(text)).not_to be_nil
      rebuilt = Mxrb::RubyApp.compile(root, File.join(directory, 'Rebuilt.mpr'))
      expect(flow_document(rebuilt)).to eq(flow_document(source))

      File.write(file, text.sub('translation "en_US", "Original"', 'translation "en_US", "Edited"'))
      edited = Mxrb::RubyApp.compile(root, File.join(directory, 'Edited.mpr'))
      document = flow_document(edited)
      expect(document.fetch('$ID')).to eq(flow_document(source).fetch('$ID'))
      action = document.fetch('ObjectCollection').fetch('Objects').find do |object|
        object.is_a?(Hash) && object.dig('Action', '$Type') == 'Microflows$ShowFormAction'
      end.fetch('Action')
      title = action.dig('FormSettings', 'TitleOverride', 'Text', 'Items')
      expect(title.grep(Hash).map { _1.values_at('LanguageCode', 'Text') })
        .to eq([['pt_BR', ''], ['en_US', 'Edited']])
    end
  end

  def flow_document(path)
    Mxrb.open(path) do |project|
      flow = project.modules.find { _1.name == 'App' }.microflows.find { _1.name == 'Open' }
      project.mpr.parse_contents(project.mpr.unit(flow.id))
    end
  end
end
