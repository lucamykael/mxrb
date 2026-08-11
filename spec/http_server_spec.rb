# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Http::Server do
  it 'requires a dispatcher and validates numeric configuration' do
    expect { described_class.new(host: '127.0.0.1', port: 9292) }
      .to raise_error(ArgumentError, /dispatcher/)
    expect do
      described_class.new(host: '127.0.0.1', port: 'invalid') { nil }
    end.to raise_error(ArgumentError)
  end

  it 'adapts Rack requests and mutable responses with case-insensitive headers' do
    received = nil
    server = described_class.new(host: '127.0.0.1', port: 9292) do |request, response|
      received = request
      response.status = 201
      response['Content-Type'] = 'application/json'
      response.body = '{"ok":true}'
    end
    input = StringIO.new('request body')

    status, headers, body = server.call(
      'rack.input' => input,
      'SCRIPT_NAME' => '/mounted',
      'PATH_INFO' => '/items',
      'REQUEST_METHOD' => 'POST',
      'QUERY_STRING' => 'page=2&name=Order',
      'HTTP_AUTHORIZATION' => 'Bearer secret',
      'HTTP_X_MXRB_TOKEN' => 'csrf'
    )

    expect([status, headers, body]).to eq(
      [201, { 'Content-Type' => 'application/json' }, ['{"ok":true}']]
    )
    expect(received.path).to eq('/mounted/items')
    expect(received.request_method).to eq('POST')
    expect(received.body).to eq('request body')
    expect(received.query).to eq('page' => '2', 'name' => 'Order')
    expect(received['authorization']).to eq('Bearer secret')
    expect(received['X-MXRB-Token']).to eq('csrf')
    expect(input.pos).to be_zero
  end

  it 'supports missing Rack input and default request values' do
    request = nil
    server = described_class.new(host: 'localhost', port: 0) do |incoming, response|
      request = incoming
      response.body = nil
    end

    expect(server.call('QUERY_STRING' => '')).to eq([200, {}, ['']])
    expect(request.path).to eq('/')
    expect(request.request_method).to eq('GET')
    expect(request.body).to eq('')
  end

  it 'starts and gracefully stops an embedded Puma instance' do
    thread = instance_double(Thread, join: nil)
    puma = instance_double(Puma::Server, add_tcp_listener: nil, run: thread, stop: nil)
    logger = Puma::LogWriter.null
    allow(Puma::Server).to receive(:new).and_return(puma)
    server = described_class.new(host: '127.0.0.1', port: 4568, logger:, max_threads: 3) { nil }

    expect(server.shutdown).to be_nil
    expect { |block| server.start(&block) }.to yield_with_args(puma)
    expect(Puma::Server).to have_received(:new).with(
      an_instance_of(Method), nil,
      include(min_threads: 0, max_threads: 3, environment: 'production', log_writer: logger)
    )
    expect(puma).to have_received(:add_tcp_listener).with('127.0.0.1', 4568)
    expect(thread).to have_received(:join)
    server.shutdown
    expect(puma).to have_received(:stop)
  end

  it 'uses a silent Puma logger by default and starts without a callback' do
    thread = instance_double(Thread, join: nil)
    puma = instance_double(Puma::Server, add_tcp_listener: nil, run: thread)
    allow(Puma::Server).to receive(:new).and_return(puma)

    described_class.new(host: '::1', port: 0) { nil }.start

    expect(Puma::Server).to have_received(:new).with(
      an_instance_of(Method), nil, include(log_writer: an_instance_of(Puma::LogWriter))
    )
  end
end
# rubocop:enable Metrics/BlockLength
