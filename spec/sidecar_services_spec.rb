# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::SidecarServices do
  around do |example|
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'project', 'Runtime.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = source
      load 'spec/fixtures/java_action_sidecar/project.rb'
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      @application = Mxrb::RubyApp::Application.new(
        target, process: { 'MXRB_DATABASE_PATH' => File.join(directory, 'runtime.sqlite3') }
      )
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  let(:bridge) { @application.send(:bridge) }
  let(:services) { described_class.new(bridge.project) }

  it 'reports the metamodel of the application and its System module' do
    model = services.metamodel
    expect(model.keys).to eq(%w[objects associations microflows])
    order = model.fetch('objects').find { _1.fetch('name') == 'Views.Order' }
    expect(order.fetch('primitives').map { _1.fetch('name') }).to eq(%w[Name Quantity Status])
    expect(model.fetch('objects').map { _1.fetch('name') }).to include('System.User', 'Views.Document')
    expect(model.fetch('microflows').map { _1.fetch('name') }).to include('Views.Upper')
  end

  it 'captions enumeration values in a language, as the Runtime does' do
    expect(services.caption('Views.Status', 'Open', 'pt_BR')).to eq('Aberto')
    expect(services.caption('Views.Status', 'Open', 'de_DE')).to eq('')
    expect(services.caption('Views.Status', 'Closed', nil)).to eq('Closed')
    expect(services.caption('Views.Status', 'Missing', 'en_US')).to eq('')
    expect(services.caption('System.ProxyConfiguration', 'Override', 'en_US')).to eq('Override')
    expect(services.caption('System.ProxyConfiguration', 'Missing', 'en_US')).to eq('')
    expect(services.caption('Views.Missing', 'Open', 'en_US')).to eq('')
  end

  it 'stores file contents and tells committed objects from new ones' do
    store = bridge.store
    document = store.create('Views.Document')
    expect(store.original(document)).to be_nil
    services.store_file(store, document, 'dir/note.txt', 'hello')
    expect(document.members.values_at('Name', 'HasContents', 'Size')).to eq(['note.txt', true, 5])
    expect(store.changed?(document)).to be(true)
    stored = Mxrb::RubyApp::FileContent.new(store.database).read('Views.Document', document.id)
    expect(stored.fetch('content')).to eq('hello')
    store.commit(document)
    expect(store.original(document)).to include('Name' => 'note.txt')

    draft = store.create('Views.Draft')
    expect(store.original(draft)).to be_nil
    store.commit(draft)
    expect(store.original(draft)).to eq(draft.members)

    memory = Mxrb::Runtime::Native::Store.new
    item = memory.create('Views.Draft').tap { _1.members['Note'] = 'a' }
    expect(memory.original(item)).to be_nil
    memory.commit(item)
    expect(memory.original(item)).to eq('Note' => 'a')
  end
end
# rubocop:enable Metrics/BlockLength
