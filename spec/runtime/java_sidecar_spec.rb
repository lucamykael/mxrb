# frozen_string_literal: true

require 'spec_helper'
require 'socket'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::JavaSidecar do
  let(:store) { Mxrb::Runtime::Native::Store.new(defaults: { 'Mod.Order' => { 'Name' => nil, 'Quantity' => nil } }) }
  let(:kinds) { { 'Name' => :attribute, 'Quantity' => :integer, 'Tags' => :reference_set, 'Customer' => :reference } }
  let(:context) do
    instance_double(Mxrb::Runtime::JavaActionContext, store:).tap do |context|
      allow(context).to receive(:member_kind) { |_entity, name| kinds[name] }
    end
  end

  # A sidecar that reads the invocation, then plays the Java side: each step is a
  # message to send, and a reply to read unless it is the final one.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def sidecar(steps, &block)
    server = TCPServer.new('127.0.0.1', 0)
    received = []
    thread = Thread.new do
      client = server.accept
      line = client.gets
      received << JSON.parse(line) if line
      steps.each do |step|
        next step.call(client) if step.respond_to?(:call)

        client.write("#{step.is_a?(String) ? step : JSON.generate(step)}\n")
        received << JSON.parse(client.gets) if step.is_a?(Hash) && step.key?('method')
      end
    rescue IOError, SystemCallError
      nil
    ensure
      client&.close
    end
    block.call("tcp://127.0.0.1:#{server.addr[1]}")
    received
  ensure
    thread&.join
    server&.close
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def callback(id, method, params = {}) = { 'id' => id, 'method' => method, 'params' => params }

  it 'is enabled by a tcp URL with an optional token and timeout' do
    expect(described_class.configured({})).to be_nil
    expect(described_class.configured({ 'MXRB_JAVA_ACTIONS_URL' => '' })).to be_nil
    sidecar = described_class.configured({ 'MXRB_JAVA_ACTIONS_URL' => 'java:7911', 'MXRB_JAVA_ACTIONS_TIMEOUT' => '5' })
    expect([sidecar.host, sidecar.port]).to eq(['java', 7911])
    expect(described_class.new('tcp://127.0.0.1:1', token: '').port).to eq(1)
    %w[http://java:7911 tcp://java tcp://:7911].each do |url|
      expect { described_class.new(url) }.to raise_error(ArgumentError, %r{must be tcp://host:port})
    end
  end

  it 'passes the parameters, answers the callbacks and returns the result' do
    order = store.create('Mod.Order')
    order.members.merge!('Name' => 'first', 'Quantity' => 3)
    when_at = Time.utc(2026, 1, 2, 3, 4, 5)
    calls = { log: [], retrieve: [], flow: [] }
    allow(context).to receive(:log) do |*arguments|
      calls[:log] << arguments
      nil
    end
    allow(context).to receive(:retrieve) do |*arguments, **options|
      calls[:retrieve] << [arguments, options]
      [order]
    end
    allow(context).to receive(:call_flow) do |*arguments, **options|
      calls[:flow] << [*arguments, options]
      'FLOW'
    end
    allow(context).to receive_messages(constant: 'hi', end_transaction: true, changed?: false,
                                       session: { 'id' => nil, 'user' => nil, 'name' => nil, 'anonymous' => false },
                                       application_root_url: 'http://app/', runtime_version: '11.12.1',
                                       model_version: 'unversioned')
    object = { '$object' => 0 }
    steps = [
      callback(1, 'get', 'object' => object, 'member' => 'Quantity'),
      callback(2, 'get', 'object' => object, 'member' => 'Mod.Tags'),
      callback(3, 'get', 'object' => object, 'member' => 'Name'),
      callback(4, 'set', 'object' => object, 'member' => 'Name', 'value' => 'second'),
      callback(5, 'set', 'object' => object, 'member' => 'Missing', 'value' => 1),
      callback(6, 'member', 'object' => object, 'member' => 'Mod.Customer'),
      callback(7, 'member', 'object' => object, 'member' => 'Missing'),
      callback(8, 'instantiate', 'entity' => 'Mod.Order', 'events' => false),
      callback(9, 'commit', 'objects' => [object, { '$object' => 1 }], 'events' => true),
      callback(10, 'related', 'object' => object, 'association' => 'Mod.Tags'),
      callback(11, 'rollback', 'objects' => [{ '$object' => 1 }]),
      callback(12, 'delete', 'objects' => [{ '$object' => 1 }], 'events' => false),
      callback(13, 'retrieve', 'xpath' => '//Mod.Order', 'variables' => { 'q' => { '$decimal' => '1.5' } },
                               'offset' => 1, 'amount' => 2, 'sort' => [['Name', true], ['Quantity', false]]),
      callback(14, 'retrieve', 'xpath' => '//Mod.Order'),
      callback(15, 'microflow', 'name' => 'Mod.Flow', 'arguments' => { 'When' => { '$datetime' => 0 } },
                                'user' => 'bob', 'sudo' => true),
      callback(16, 'log', 'node' => 'Node', 'level' => 'INFO', 'message' => 'hello'),
      callback(17, 'log', 'node' => 'Node', 'level' => 'LOUD', 'message' => 'x'),
      callback(18, 'constant', 'name' => 'Mod.C'),
      callback(19, 'end_transaction'),
      callback(20, 'changed', 'object' => object),
      callback(21, 'session'),
      callback(22, 'application_root_url'),
      callback(23, 'runtime_version'),
      callback(24, 'model_version'),
      { 'id' => 25, 'method' => 'unknown' },
      callback(26, 'changed', 'object' => 'nope'),
      callback(27, 'changed', 'object' => { '$object' => 99 }),
      callback(28, 'changed', 'object' => { '$other' => 1 }),
      callback(29, 'changed', 'object' => { '$object' => -1 }),
      { 'id' => 0, 'result' => [{ '$decimal' => '2.5' }, { '$datetime' => 1_767_323_045_000 }, object, nil] }
    ]
    result = nil
    received = sidecar(steps) do |url|
      result = described_class.new(url, token: 'secret').invoke(
        'Mod.Action', [%w[text hi], ['count', 7], ['price', BigDecimal('2.50')], ['ratio', 0.5],
                       ['flag', true], ['when', when_at], ['order', order], ['list', [order]], ['kind', :Red],
                       ['none', nil]], context:
      )
    end

    expect(result).to eq([BigDecimal('2.5'), when_at, order, nil])
    expect(received.first).to eq(
      'id' => 0, 'method' => 'invoke',
      'params' => {
        'action' => 'Mod.Action', 'token' => 'secret',
        'arguments' => [
          %w[text hi], ['count', 7], ['price', { '$decimal' => '2.5' }], ['ratio', { '$decimal' => '0.5' }],
          ['flag', true], ['when', { '$datetime' => 1_767_323_045_000 }],
          ['order', { '$object' => 0, 'entity' => 'Mod.Order', 'id' => order.id }],
          ['list', [{ '$object' => 0, 'entity' => 'Mod.Order', 'id' => order.id }]], %w[kind Red], ['none', nil]
        ]
      }
    )
    answers = received.drop(1).to_h { [_1['id'], _1.key?('error') ? _1['error'] : _1['result']] }
    expect(answers.values_at(1, 2, 3, 4)).to eq([{ '$integer' => 3 }, [], 'first', nil])
    expect(answers[5]).to eq('type' => 'com.mendix.core.CoreException', 'message' => 'Mod.Order has no member Missing')
    expect(answers.values_at(6, 7)).to eq(['reference', nil])
    expect(answers[8]).to include('$object' => 1, 'entity' => 'Mod.Order')
    expect(answers.values_at(9, 10, 11, 12)).to eq([nil, [], nil, nil])
    expect(answers[13]).to eq([{ '$object' => 0, 'entity' => 'Mod.Order', 'id' => order.id }])
    expect(answers.values_at(15, 16, 18, 19, 20, 21, 22, 23, 24))
      .to eq(['FLOW', nil, 'hi', true, false, { 'id' => nil, 'user' => nil, 'name' => nil, 'anonymous' => false },
              'http://app/', '11.12.1', 'unversioned'])
    expect(answers[17]).to eq('type' => 'com.mendix.core.CoreException', 'message' => 'unknown log level LOUD')
    expect(answers[25]['message']).to eq('unknown Java action callback "unknown"')
    expect(answers[26]['message']).to eq('expected an object, got "nope"')
    expect(answers[27]['message']).to eq('unknown object handle 99')
    expect(answers[28]['message']).to eq('Java action sent an unknown value ["$other"]')
    expect(answers[29]['message']).to eq('unknown object handle -1')
    expect(order.members['Name']).to eq('second')
    expect(store.retrieve('Mod.Order')).to eq([order])
    expect(calls[:log]).to eq([%w[Node Info hello]])
    expect(calls[:retrieve]).to eq([
                                     [['//Mod.Order', { 'q' => BigDecimal('1.5') }],
                                      { offset: 1, amount: 2, sort: [['Name', true], ['Quantity', false]] }],
                                     [['//Mod.Order', {}], { offset: 0, amount: -1, sort: [] }]
                                   ])
    expect(calls[:flow]).to eq([['Mod.Flow', { 'When' => Time.at(0).utc }, { username: 'bob', sudo: true }]])
  end

  it 'reads members without change tracking and reads empty integers' do
    plain = Mxrb::Runtime::Native::Store.new
    allow(context).to receive(:store).and_return(Struct.new(:created) { def create(*) = created }.new(nil))
    order = plain.create('Mod.Order')
    steps = [callback(1, 'get', 'object' => { '$object' => 0 }, 'member' => 'Quantity'),
             callback(2, 'set', 'object' => { '$object' => 0 }, 'member' => 'Quantity', 'value' => 4),
             { 'id' => 0, 'result' => nil }]
    received = sidecar(steps) { described_class.new(_1).invoke('Mod.Action', [['order', order]], context:) }
    expect(received.first['params']).not_to have_key('token')
    expect(received.drop(1).map { _1['result'] }).to eq([nil, nil])
    expect(order.members['Quantity']).to eq(4)
  end

  it 'answers the Runtime services: originals, metamodel, captions, files and messages' do
    order = store.create('Mod.Order')
    order.members.merge!('Name' => 'a', 'Quantity' => 2, 'Tags' => nil)
    allow(context).to receive(:file_content).with(order).and_return("\x00\xFFbytes".b)
    allow(context).to receive(:show_message)
    services = instance_double(Mxrb::RubyApp::SidecarServices, metamodel: { 'objects' => [], 'count' => 1 })
    allow(services).to receive(:caption).with('Mod.Kind', 'Big', nil).and_return('Large')
    allow(services).to receive(:store_file)
    object = { '$object' => 0 }
    steps = [
      callback(1, 'original', 'object' => object),
      ->(_client) { store.commit(order) },
      callback(2, 'original', 'object' => object),
      callback(3, 'metamodel'),
      callback(4, 'caption', 'enumeration' => 'Mod.Kind', 'value' => 'Big', 'language' => nil),
      callback(5, 'file', 'object' => object),
      callback(6, 'store_file', 'object' => object, 'name' => 'a.txt', 'content' => { '$binary' => 'aGk=' }),
      callback(7, 'message', 'type' => 'ERROR', 'message' => 'bad', 'blocking' => true),
      { 'id' => 0, 'result' => { 'nested' => [{ '$binary' => 'AP8=' }] } }
    ]
    result = nil
    received = sidecar(steps) do |url|
      result = described_class.new(url, services:).invoke('Mod.Action', [['order', order], ['map', { 'a' => 1 }]],
                                                          context:)
    end

    expect(result).to eq('nested' => ["\x00\xFF".b])
    expect(received.first.dig('params', 'arguments').last).to eq(['map', { 'a' => 1 }])
    answers = received.drop(1).map { _1['result'] }
    expect(answers[0]).to be_nil
    expect(answers[1]).to eq('Name' => 'a', 'Quantity' => { '$integer' => 2 }, 'Tags' => [])
    expect(answers[2..]).to eq([{ 'objects' => [], 'count' => 1 }, 'Large',
                                { '$binary' => Base64.strict_encode64("\x00\xFFbytes".b) }, nil, nil])
    expect(services).to have_received(:store_file).with(store, order, 'a.txt', 'hi')
    expect(context).to have_received(:show_message).with('ERROR', 'bad', blocking: true)

    steps = [callback(1, 'metamodel'), { 'id' => 0, 'result' => nil }]
    received = sidecar(steps) { described_class.new(_1).invoke('Mod.Action', [], context:) }
    expect(received.last['error']['message']).to eq('the application offers no Runtime services')
    expect(described_class.configured({ 'MXRB_JAVA_ACTIONS_URL' => 'java:1' }, services:)).to be_a(described_class)
  end

  it 'runs OQL in the application database, with object IDs as objects' do
    customer = store.create('Mod.Customer')
    columns = { 'Name' => :string, 'Id' => :identifier, 'Count' => :integer }
              .map { Mxrb::Runtime::OqlTable::Column.new(_1, _2) }
    rows = [{ 'Name' => 'a', 'Id' => 'c1', 'Count' => 2 }, { 'Name' => 'b', 'Id' => nil, 'Count' => nil },
            { 'Name' => 'c', 'Id' => 'gone', 'Count' => 1 }]
    table = Struct.new(:definition, :rows).new(Struct.new(:columns).new(columns), rows)
    database = Struct.new(:table, :customer, :queries) do
      def oql_table(statement, parameters:)
        queries << [statement, parameters]
        table
      end

      def locate(id) = id == 'c1' ? customer : nil
    end.new(table, customer, [])
    allow(context).to receive(:store).and_return(database)
    steps = [
      callback(1, 'oql', 'query' => 'SELECT', 'parameters' => { 'p' => { '$decimal' => '1' } }, 'offset' => 1,
                         'amount' => 1),
      callback(2, 'oql', 'query' => 'Mod.Dataset'),
      { 'id' => 0, 'result' => nil }
    ]
    received = sidecar(steps) { described_class.new(_1).invoke('Mod.Action', [], context:) }
    answers = received.drop(1).map { _1['result'] }
    expect(answers[0]).to eq('columns' => [%w[Name string], %w[Id identifier], %w[Count integer]],
                             'rows' => [['b', nil, nil]])
    expect(answers[1]['rows'].map(&:first)).to eq(%w[a b c])
    expect(answers[1]['rows'].first).to eq(['a', { '$object' => 0, 'entity' => 'Mod.Customer', 'id' => customer.id },
                                            { '$integer' => 2 }])
    expect(answers[1]['rows'].last).to eq(['c', nil, { '$integer' => 1 }])
    expect(database.queries).to eq([['SELECT', { 'p' => BigDecimal('1') }], ['Mod.Dataset', {}]])

    allow(context).to receive(:store).and_return(store)
    steps = [callback(1, 'oql', 'query' => 'SELECT'), { 'id' => 0, 'result' => nil }]
    received = sidecar(steps) { described_class.new(_1).invoke('Mod.Action', [], context:) }
    expect(received.last['error']['message']).to eq('OQL needs the application database')
  end

  it 'forwards requests to handlers and answers their session and number callbacks' do
    customer = store.create('Mod.Customer')
    numbers = Struct.new(:customer) do
      def long_id(_object) = 7
      def object_for_long(number) = number == 7 ? customer : nil
    end.new(customer)
    allow(context).to receive_messages(store: numbers, default_language: { 'code' => 'en_US', 'language' => nil },
                                       session: { 'id' => 's1', 'user' => customer, 'name' => 'ann',
                                                  'anonymous' => false })
    services = instance_double(Mxrb::RubyApp::SidecarServices, guest_login_enabled?: true,
                                                               guest_session: { 'id' => 'g1', 'anonymous' => true })
    allow(services).to receive(:register_request_handler).and_return(['link'])
    steps = [
      callback(1, 'session'),
      callback(2, 'request_handler', 'path' => 'link'),
      callback(3, 'guest_session'),
      callback(4, 'guest_login_enabled'),
      callback(5, 'long_id', 'object' => { '$object' => 0 }),
      callback(6, 'object_for_long', 'id' => 7),
      callback(7, 'object_for_long', 'id' => 8),
      callback(8, 'default_language'),
      { 'id' => 0, 'result' => { 'status' => 303, 'body' => { '$binary' => 'aGk=' } } }
    ]
    result = nil
    received = sidecar(steps) do |url|
      result = described_class.new(url, services:).request(
        'link', { 'method' => 'GET', 'path' => '/link/x', 'body' => "\xFF".b },
        session: { 'id' => 's1', 'user' => customer }, context:
      )
    end

    expect(result).to eq('status' => 303, 'body' => 'hi')
    expect(received.first).to include('method' => 'request')
    expect(received.first.fetch('params')).to eq(
      'handler' => 'link',
      'request' => { 'method' => 'GET', 'path' => '/link/x', 'body' => { '$binary' => '/w==' } },
      'session' => { 'id' => 's1', 'user' => { '$object' => 0, 'entity' => 'Mod.Customer', 'id' => customer.id } }
    )
    answers = received.drop(1).map { _1['result'] }
    handle = { '$object' => 0, 'entity' => 'Mod.Customer', 'id' => customer.id }
    expect(answers).to eq([{ 'id' => 's1', 'user' => handle, 'name' => 'ann', 'anonymous' => false },
                           nil, { 'id' => 'g1', 'anonymous' => true }, true, 7, handle, nil,
                           { 'code' => 'en_US', 'language' => nil }])
    expect(services).to have_received(:register_request_handler).with('link')

    allow(context).to receive(:store).and_return(store)
    steps = [callback(1, 'long_id', 'object' => { '$object' => 0 }), { 'id' => 0, 'result' => nil }]
    received = sidecar(steps) { described_class.new(_1).invoke('Mod.Action', [['c', customer]], context:) }
    expect(received.last['error']['message']).to eq('numeric object ids need the application database')
    expect { sidecar([]) { described_class.new(_1).request('x', {}, session: nil, context:) } }
      .to raise_error(Mxrb::NativeRuntimeError, /did not answer/)
  end

  it 'listens for background work and serves each callback on a connection of its own' do
    tickets = []
    pause = ->(_client) { sleep 0.7 }
    steps = [JSON.generate('id' => 0, 'method' => 'attach', 'params' => { 'ticket' => 't1' }),
             JSON.generate('id' => 0, 'method' => 'ping'), pause,
             JSON.generate('id' => 0, 'method' => 'attach', 'params' => { 'ticket' => 't2' })]
    received = sidecar(steps) do |url|
      described_class.new(url, token: 'secret').listen(running: -> { tickets.size < 2 }) { tickets << _1 }
    end
    expect(tickets).to eq(%w[t1 t2])
    expect(received.first).to eq('id' => 0, 'method' => 'listen', 'params' => { 'token' => 'secret' })
  end

  it 'reconnects to listen' do
    tickets = %w[t1 t2]
    calls = 0
    sidecar([JSON.generate('id' => 0, 'method' => 'attach', 'params' => { 'ticket' => 't3' })]) do |url|
      described_class.new(url).listen(running: -> { (calls += 1) < 6 }, retry_after: 0) { tickets << _1 }
    end
    expect(tickets).to eq(%w[t1 t2 t3])
  end

  it 'attaches background work' do
    steps = [callback(1, 'constant', 'name' => 'Mod.C'), { 'id' => 0, 'result' => nil }]
    allow(context).to receive(:constant).and_return('c')
    received = sidecar(steps) { described_class.new(_1).attach('t4', context:) }
    expect(received.first).to eq('id' => 0, 'method' => 'attach', 'params' => { 'ticket' => 't4' })
    expect(received.last).to eq('id' => 1, 'result' => 'c')
  end

  it 'raises the exception a Java action throws with its class' do
    steps = [{ 'id' => 0, 'error' => { 'type' => 'java.lang.IllegalStateException', 'message' => 'bad' } }]
    expect { sidecar(steps) { described_class.new(_1).invoke('Mod.Action', [], context:) } }
      .to raise_error(an_instance_of(Mxrb::Runtime::JavaActionError)
        .and(having_attributes(java_class: 'java.lang.IllegalStateException', message: 'bad')))
    expect { sidecar([{ 'id' => 0, 'error' => 'odd' }]) { described_class.new(_1).invoke('Mod.Action', [], context:) } }
      .to raise_error(an_instance_of(Mxrb::Runtime::JavaActionError).and(having_attributes(java_class: '')))
  end

  it 'answers a callback error with the Java class of a Java action error' do
    allow(context).to receive(:call_flow).and_raise(Mxrb::Runtime::JavaActionError.new('views.Failure', 'nested'))
    steps = [callback(1, 'microflow', 'name' => 'Mod.Flow'), { 'id' => 0, 'result' => true }]
    received = sidecar(steps) { described_class.new(_1).invoke('Mod.Action', [], context:) }
    expect(received.last['error']).to eq('type' => 'views.Failure', 'message' => 'nested')
  end

  it 'fails closed when the sidecar is unavailable, silent or malformed' do
    port = TCPServer.new('127.0.0.1', 0).then { |server| server.addr[1].tap { server.close } }
    expect { described_class.new("tcp://127.0.0.1:#{port}").invoke('Mod.Action', [], context:) }
      .to raise_error(Mxrb::NativeRuntimeError, /sidecar at 127.0.0.1:#{port} is unavailable/)
    expect { sidecar([]) { described_class.new(_1).invoke('Mod.Action', [], context:) } }
      .to raise_error(Mxrb::NativeRuntimeError, /did not answer/)
    wait = ->(_client) { sleep 0.3 }
    expect { sidecar([wait]) { described_class.new(_1, timeout: 0.05).invoke('Mod.Action', [], context:) } }
      .to raise_error(Mxrb::NativeRuntimeError, /did not answer/)
    ['{', '[1]', '{"id":"0"}'].each do |line|
      expect { sidecar([line]) { described_class.new(_1).invoke('Mod.Action', [], context:) } }
        .to raise_error(Mxrb::NativeRuntimeError, 'Java action sidecar sent a malformed message')
    end
    expect { described_class.new('tcp://127.0.0.1:1').invoke('Mod.Action', [['thing', Object.new]], context:) }
      .to raise_error(Mxrb::NativeRuntimeError, 'cannot pass Object to a Java action')
  end
end
# rubocop:enable Metrics/BlockLength
