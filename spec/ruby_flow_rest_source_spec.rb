# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby REST header declarations' do
  after { Mxrb::RubyApp::Registry.reset! }

  def builder
    Mxrb::Dsl::FlowBuilder.new('Request', runtime: nil, kind: :microflow, public: false)
  end

  def options
    { method: :post, location: 'https://example.invalid/{1}', location_parameters: ['$Path'],
      request_body: '{1}', request_parameters: ['$Body'], result_handling: :http_response,
      as: :response, result_entity: 'System.HttpResponse', timeout: '30', error: :continue }
  end

  it 'preserves the legacy hash contract, header order and scalar values with a block' do
    legacy = builder
    typed = builder
    headers = { 'X-Empty' => '', 'X-Nil' => nil, 'X-False' => false, 'X-Number' => '001', 'X-Expr' => '$Token' }
    legacy.call_rest(**options, headers:)
    typed.call_rest(**options) { |request| headers.each { |name, value| request.header(name, value) } }
    expect(typed.to_h.fetch(:body)).to eq(legacy.to_h.fetch(:body))
    expect(typed.to_h.fetch(:body).first[:headers].keys).to eq(headers.keys)
  end

  it 'preserves repeated names and order all the way into native header entries' do
    flow = builder
    flow.call_rest(**options) do
      header 'X-Multi', "'one'"
      header 'X-Other', '$Value'
      header 'X-Multi', "'two'"
    end
    activity = flow.to_h.fetch(:body).first
    writer = Mxrb::Writer.new('/tmp/rest-headers.mpr', version: '11.12.1', modules: [])
    document = writer.send(:rest_call_action_doc, activity)
    headers = Mxrb::IO::BsonCodec.parse_array(document.dig('HttpConfiguration', 'HttpHeaderEntries')).fetch(:items)
    expect(headers.map { [_1['Key'], _1['Value']] }).to eq([
      ['X-Multi', "'one'"], ['X-Other', '$Value'], ['X-Multi', "'two'"]
    ])
    source = Mxrb::Exporter.allocate.send(:rest_call_line, '', document)
    decoded = builder
    decoded.instance_eval(source)
    expect(decoded.to_h.fetch(:body).first[:headers]).to eq(activity[:headers])
    expect(source).not_to include('headers:', '=>')
  end

  it 'rejects mixing and invalid blocks without installing a partial REST activity' do
    flow = builder
    expect { flow.call_rest(**options, headers: {}) { header 'Name', 'Value' } }
      .to raise_error(ArgumentError, /either headers:/)
    expect do
      flow.call_rest(**options) do
        header 'First', 'Value'
        header 'Invalid', { unsupported: 'value' }
      end
    end.to raise_error(TypeError, /scalar/)
    expect { flow.call_rest(**options, result_handling: :invalid) { header 'Name', 'Value' } }
      .to raise_error(ArgumentError, /unsupported REST/)
    expect(flow.to_h.fetch(:body)).to be_nil
  end

  it 'keeps empty headers and all non-header request/result options unchanged' do
    flow = builder
    flow.call_rest(**options) { |_request| }
    activity = flow.to_h.fetch(:body).first
    expect(activity[:headers]).to eq({})
    writer = Mxrb::Writer.new('/tmp/rest-options.mpr', version: '11.12.1', modules: [])
    document = writer.send(:rest_call_action_doc, activity)
    source = Mxrb::Exporter.allocate.send(:rest_call_line, '', document)
    expect(source).not_to include(' do', 'header ')
    decoded = builder
    decoded.instance_eval(source)
    expect(decoded.to_h.fetch(:body).first).to eq(activity)
  end

  def flow_bytes(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true)
    mpr.all_units.filter_map do |unit|
      next unless mpr.parse_contents(unit)['$Type'] == 'Microflows$Microflow'

      [unit.fetch('UnitID'), mpr.content_bytes(unit)]
    end.to_h
  ensure
    mpr&.close
  end

  it 'roundtrips REST headers byte-exactly and preserves authoritative header edits' do
    Dir.mktmpdir('mxrb-rest-headers-') do |directory|
      original = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      Mxrb.define(original) do
        mendix_version '11.12.1'
        self.module(:App) do
          microflow(:Request) do
            call_rest method: :get, location: 'https://example.invalid', result_handling: :http_response,
                      as: :response, result_entity: 'System.HttpResponse', timeout: '30', request_body: '' do
              header 'X-Test', "'original'"
              header 'X-Multi', "'one'"
              header 'X-Multi', "'two'"
            end
          end
        end
      end
      before = flow_bytes(original)
      Mxrb::Exporter.new(original, output, mode: :ruby).export!
      source_path = File.join(output, 'app', 'services', 'app', 'request.rb')
      source = File.read(source_path)
      expect(source).not_to include('headers:', '=>')
      expect(source.scan('header "X-Multi"').size).to eq(2), source
      Mxrb::RubyApp.compile(output, rebuilt)
      expect(flow_bytes(rebuilt)).to eq(before)
      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      Mxrb::RubyApp.compile(restored, File.join(directory, 'Restored.mpr'))
      expect(flow_bytes(File.join(directory, 'Restored.mpr'))).to eq(before)

      File.write(source_path, source.sub("'original'", "'edited'"))
      Mxrb::RubyApp.compile(output, rebuilt)
      edited = File.join(directory, 'edited')
      Mxrb::Exporter.new(rebuilt, edited, mode: :ruby).export!
      result = File.read(File.join(edited, 'app', 'services', 'app', 'request.rb'))
      expect(result).to include("header \"X-Test\", \"'edited'\"", 'timeout: "30"')
      expect(result.scan('header "X-Multi"').size).to eq(2)
    end
  end
end
# rubocop:enable Metrics/BlockLength
