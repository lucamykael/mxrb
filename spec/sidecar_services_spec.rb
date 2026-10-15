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

  it 'registers request handler paths outside the API' do
    expect(services.register_request_handler('/link/')).to eq(['link'])
    services.register_request_handler('link/deep')
    expect(services.request_handlers).to eq(%w[link link/deep])
    expect(services.request_handler('/link/deep/x')).to eq('link/deep')
    expect(services.request_handler('/link')).to eq('link')
    expect(services.request_handler('/linked')).to be_nil
    ['', '/', 'api', '/api/x/'].each do |path|
      expect { services.register_request_handler(path) }.to raise_error(ArgumentError, /is reserved/)
    end
  end

  it 'starts guest sessions with their own id when guests are let in' do
    sessions = @application.session_manager
    guests = described_class.new(bridge.project, sessions: -> { sessions })
    expect(guests.guest_login_enabled?).to be(true)
    expect(guests.project_security).to eq('admin_user_name' => 'MxAdmin', 'admin_user_role' => 'Administrator')
    session = guests.guest_session
    expect(session.fetch('id')).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    expect(session.except('id')).to eq('user' => nil, 'name' => "Anonymous_#{session.fetch('id')}", 'anonymous' => true)
    context = sessions.authenticate("Bearer #{session.fetch('id')}")
    expect(context.attributes.values_at('session_id', 'anonymous')).to eq([session.fetch('id'), true])
    expect(context.user_roles).to eq(['Guest'])
    expect(sessions.csrf_token("Bearer #{session.fetch('id')}")).not_to be_empty
    expect(Mxrb::RubyApp::SessionManager.session_id('abc'))
      .to eq(Digest::SHA256.hexdigest('abc')[0, 32].unpack('a8a4a4a4a12').join('-'))

    allow(Mxrb::RubyApp::Registry).to receive(:all).and_call_original
    allow(Mxrb::RubyApp::Registry).to receive(:all).with(:project_security).and_return({})
    expect(guests.guest_login_enabled?).to be(false)
    expect(guests.project_security).to eq('admin_user_name' => '', 'admin_user_role' => '')
    expect { guests.guest_session }.to raise_error(Mxrb::NativeRuntimeError, 'guest access is disabled')
  end

  it 'keeps numbers for objects that turn back into them' do
    store = bridge.store
    customer = store.create('Views.Customer')
    store.commit(customer)
    number = store.long_id(customer)
    expect(store.long_id(customer)).to eq(number)
    expect(store.object_for_long(number)).to eq(customer)
    expect(store.object_for_long(number + 1000)).to be_nil
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

    customer = store.create('Views.Customer').tap { _1.members['Name'] = 'Ada' }
    store.commit(customer)
    table = store.oql_table('SELECT c.Name AS Name, c.ID AS Id FROM Views.Customer c WHERE c.Name = $name',
                            parameters: { 'name' => 'Ada' })
    expect(table.rows).to eq([{ 'Name' => 'Ada', 'Id' => customer.id }])
    expect(store.oql_table('Views.CustomerNames', parameters: { 'Prefix' => 'A%' }).rows).to eq([{ 'Name' => 'Ada' }])
    expect(store.locate(customer.id)).to eq(customer)
    expect(store.locate('missing')).to be_nil

    memory = Mxrb::Runtime::Native::Store.new
    item = memory.create('Views.Draft').tap { _1.members['Note'] = 'a' }
    expect(memory.original(item)).to be_nil
    memory.commit(item)
    expect(memory.original(item)).to eq('Note' => 'a')
  end
end
# rubocop:enable Metrics/BlockLength
