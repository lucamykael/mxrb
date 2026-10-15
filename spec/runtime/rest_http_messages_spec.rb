# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'published REST HTTP messages' do
  let(:fixture) { File.expand_path('../fixtures/native_rest_http', __dir__) }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))).fetch('results') }
  let(:requests) { JSON.parse(File.read(File.join(fixture, 'requests.json'))) }

  after { Mxrb::RubyApp::Registry.reset! }

  def call(server, step) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    path, query = step.fetch('path').split('?', 2)
    request = Mxrb::Http::Request.new(
      path: "/#{path}", request_method: step.fetch('method'), body: step.fetch('body', ''),
      query: URI.decode_www_form(query.to_s).to_h, headers: Mxrb::Http::Headers.new(step.fetch('headers', {}))
    )
    response = Mxrb::Http::Response.new
    server.send(:dispatch, request, response)
    headers = %w[content-type location set-cookie x-echo].to_h do |name|
      value = response.headers.find { _1.first.casecmp?(name) }&.last
      [name, value && Array(value).flat_map { _1.to_s.split("\n") }]
    end.compact
    { 'name' => step.fetch('name'), 'status' => response.status, 'headers' => headers, 'body' => response.body.to_s }
  end

  it 'answers like the native Mendix 11.12.1 Runtime' do
    Dir.mktmpdir('mxrb-rest-http-') do |directory|
      source = File.join(directory, 'Source.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.join(fixture, 'project.rb')
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!(parallel: false)
      server = Mxrb::RubyApp::Server.new(target)
      root = server.application.send(:bridge).interpreter.application_root_url.delete_suffix('/')
      results = requests.map { call(server, _1) }
      expect(results).to eq(expected.map { _1.except('reason').merge('body' => _1.fetch('body').gsub('{root}', root)) })
      json = call(server, 'name' => 'json', 'method' => 'POST', 'path' => 'rest/probe/v1/probe/body',
                          'headers' => { 'Content-Type' => 'application/json' }, 'body' => '{"a":1}')
      expect(json).to include('status' => 200, 'body' => "{\"a\":1}|#{root}/rest/probe/v1/probe/body")
    ensure
      server&.application&.close
    end
  end
end

RSpec.describe Mxrb::RubyApp::Application do
  it 'passes the HTTP messages to the controller actions that declare them' do
    controller = Class.new(Mxrb::RubyApp::Controller) do
      def run(httpResponse:) = httpResponse # rubocop:disable Naming/MethodParameterName, Naming/VariableName
      def other(id:) = id
    end
    services = { 'M.Run' => [controller, :run], 'M.Other' => [controller, :other], 'M.Lost' => ['M.Missing', :run] }
    allow(Mxrb::RubyApp::Registry).to receive(:fetch).and_call_original
    services.each do |name, (owner, action)|
      service = double(controller_definition: { controller: owner, action: })
      allow(Mxrb::RubyApp::Registry).to receive(:fetch).with(:service, name).and_return(service)
    end
    accepts = ->(name) { described_class.allocate.send(:accepts_argument?, name, 'httpResponse') }
    expect(%w[M.Run M.Other M.Lost M.Unknown].map(&accepts)).to eq([true, false, true, true])
  end
end

RSpec.describe Mxrb::Runtime::Native::Interpreter do
  it 'finds and filters a list by an expression over $currentObject' do
    interpreter = described_class.allocate
    interpreter.instance_variable_set(:@expression, Mxrb::Runtime::Native::Expression.new)
    rows = %w[a b a].each_with_index.map do |key, index|
      Mxrb::Runtime::Native::ObjectValue.new(entity: 'M.Row', id: index.to_s, members: { 'Key' => key })
    end
    filter, found = [%w[FilterByExpression a], %w[FindByExpression b]].map do |operation, key|
      interpreter.send(:list_operation, "Microflows$#{operation}", rows, nil, "$currentObject/Key = '#{key}'", {})
    end
    expect([filter.map(&:id), found.id]).to eq([%w[0 2], '1'])
  end
end
# rubocop:enable Metrics/BlockLength
