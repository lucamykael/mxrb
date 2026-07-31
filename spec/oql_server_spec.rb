# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Oql::Server do
  def response
    Struct.new(:status, :body) do
      def initialize = super(nil, nil).tap { @headers = {} }

      def []=(name, value)
        @headers[name] = value
      end

      def [](name) = @headers[name]
    end.new
  end

  def request(method, body) = Struct.new(:request_method, :body).new(method, body)

  let(:workspace) do
    instance_double(
      Mxrb::Runtime::DatabaseWorkspace,
      up: nil,
      query_rows: [{ 'name' => 'Widget' }]
    )
  end
  let(:server) { described_class.new('/tmp/App.mpr', workspace:) }

  it 'executes SQL and translated OQL with rows, timing, and warnings' do
    sql = server.execute('sql' => 'SELECT name FROM products')
    expect(sql).to include(ok: true, row_count: 1, rows: [{ 'name' => 'Widget' }])
    expect(sql[:elapsed_ms]).to be_a(Float)
    expect(sql[:warnings]).to be_empty

    oql = server.execute('oql' => 'SELECT Product.Name FROM Shop.Product Product')
    expect(oql[:ok]).to be true
    expect(oql[:warnings]).to include(/logical table/)
    expect(workspace).to have_received(:query_rows).with(include('"shop$product"'))
  end

  it 'returns structured client and query errors' do
    expect(server.execute([])).to include(
      ok: false, error: include(code: 'invalid_request', message: /object/)
    )
    expect(server.execute('sql' => 'SELECT 1', 'oql' => 'SELECT 1')).to include(
      ok: false, error: include(code: 'invalid_request', message: /exactly one/)
    )
    expect(server.execute('oql' => 'DELETE FROM Shop.Product')).to include(
      ok: false, error: include(code: 'invalid_request', message: /read-only/)
    )
    expect(server.execute('oql' => 'SELECT * FROM Shop.Product WHERE Name = $name')).to include(
      ok: false, error: include(code: 'invalid_request', message: /parameterized/)
    )

    allow(workspace).to receive(:query_rows).and_raise(Mxrb::ToolchainError, 'database unavailable')
    expect(server.execute('sql' => 'SELECT 1')).to include(
      ok: false, error: include(code: 'query_failed', message: 'database unavailable')
    )
  end

  it 'enforces loopback binding' do
    expect do
      described_class.new('/tmp/App.mpr', host: '0.0.0.0', workspace:)
    end.to raise_error(ArgumentError, /loopback/)
  end

  it 'builds the default database workspace and accepts a custom logger' do
    logger = instance_double(WEBrick::Log)
    allow(Mxrb::Runtime::DatabaseWorkspace).to receive(:new).and_return(workspace)
    described_class.new('/tmp/App.mpr', database_port: 55_999, logger:)
    expect(Mxrb::Runtime::DatabaseWorkspace).to have_received(:new)
      .with('/tmp/App.mpr', port: 55_999)
  end

  it 'dispatches HTTP status, JSON, size, and method policies' do
    result = response
    server.send(:dispatch, request('GET', ''), result)
    expect(result.status).to eq(405)
    expect(JSON.parse(result.body).dig('error', 'code')).to eq('method_not_allowed')

    result = response
    server.send(:dispatch, request('POST', 'x' * (described_class::MAX_BODY_BYTES + 1)), result)
    expect(result.status).to eq(413)

    result = response
    server.send(:dispatch, request('POST', '{broken'), result)
    expect(result.status).to eq(400)
    expect(JSON.parse(result.body).dig('error', 'code')).to eq('invalid_json')

    result = response
    server.send(:dispatch, request('POST', JSON.generate('sql' => 'SELECT 1')), result)
    expect(result.status).to eq(200)
    expect(result['Content-Type']).to eq('application/json; charset=utf-8')

    result = response
    invalid = JSON.generate('sql' => 'SELECT 1', 'oql' => 'SELECT 1')
    server.send(:dispatch, request('POST', invalid), result)
    expect(result.status).to eq(400)

    allow(workspace).to receive(:query_rows).and_raise(StandardError, 'bad query')
    result = response
    server.send(:dispatch, request('POST', JSON.generate('sql' => 'SELECT 1')), result)
    expect(result.status).to eq(422)
  end

  it 'prepares and starts a quiet WEBrick server' do
    http = instance_double(WEBrick::HTTPServer, mount_proc: nil, start: nil, shutdown: nil)
    allow(WEBrick::HTTPServer).to receive(:new).and_return(http)
    yielded = nil
    expect(server.shutdown).to be_nil
    server.start { yielded = _1 }
    expect(workspace).to have_received(:up)
    expect(http).to have_received(:mount_proc).with('/query')
    expect(http).to have_received(:start)
    expect(yielded).to equal(http)
    server.shutdown
    expect(http).to have_received(:shutdown)

    server.start(prepare: false)
    expect(workspace).to have_received(:up).once
  end
end
# rubocop:enable Metrics/BlockLength
