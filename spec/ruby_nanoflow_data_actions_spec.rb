# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby app nanoflow data actions' do
  let(:fixture) { 'spec/fixtures/native_nanoflow_data' }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      @source = File.join(directory, 'Nanoflows.mpr')
      ENV['MXRB_OUTPUT_PATH'] = @source
      load File.join(fixture, 'project.rb')
      @target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(@source, @target, mode: :ruby).export!
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def nanoflow(name)
    File.read(File.join(@target, 'frontend', 'src', 'generated', 'nanoflows', 'probe', "#{name}.ts"))
  end

  it 'exports every verified case without unsupported actions' do
    sources = Dir[File.join(@target, 'frontend', 'src', 'generated', 'nanoflows', 'probe', '*.ts')].map do
      File.read(_1)
    end
    expect(sources.size).to eq(JSON.parse(File.read(File.join(fixture, 'cases.json'))).size)
    expect(sources.join).not_to include('runtime.unsupported(')
    expect(nanoflow('case_retrieve_x_path')).to include('await runtime.retrieve("rows", {"source":"database"')
    expect(nanoflow('case_association')).to include('"from":"Probe.Row","to":"Probe.Item","kind":"Reference"')
    expect(nanoflow('case_commit_delete')).to include('await runtime.commit("new")', 'await runtime.delete("new")')
    expect(nanoflow('case_rollback')).to include('await runtime.rollback("first")')
    expect(nanoflow('case_list_ops')).to include('runtime.listOperation({"operation":"Sort"')
    expect(nanoflow('case_aggregates')).to include('runtime.aggregate({"list":"rows","function":"Sum"')
    loops = nanoflow('case_loops')
    expect(loops).to include('for (const item of runtime.loop({"kind":"iterable"', "return 'continue';",
                             "return 'break';", 'runtime.loop({"kind":"while"', 'void item;')
    expect(nanoflow('case_aggregates'))
      .to include('runtime.log("ORACLE Aggregates={1}|{2}|{3}|{4}|{5}", ["toString($count)"')
  end

  it 'filters entity requests with XPath variables, refusing unknown objects' do
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(@target, process: {})
    item = @application.call_service('Probe.Load')
    rows = ->(xpath, variables) { @application.records('Probe.Row', xpath:, xpath_variables: variables) }
    expect(rows.call('[Rank >= $minimum]', { 'minimum' => 2 }).map { _1[:attributes]['Name'] })
      .to contain_exactly('North', 'Middle', 'alpha')
    expect(rows.call('[Probe.Row_Item = $item]',
                     { 'item' => { 'type' => 'Probe.Item', 'id' => item[:id] } }).size).to eq(4)
    expect(rows.call('[Amount > $limit]', { 'limit' => { '__mxrb_decimal' => '2.5' } }).map { _1[:attributes]['Name'] })
      .to eq(['south'])
    expect { rows.call('[Probe.Row_Item = $item]', { 'item' => { 'type' => 'Probe.Item', 'id' => '0' } }) }
      .to raise_error(ArgumentError, /not found/)
    expect { rows.call('[Rank > 1]', []) }.to raise_error(ArgumentError, /must be an object/)
  end

  it 'reads XPath variables from the entity route and rejects unknown associations' do
    server = Mxrb::RubyApp::Server.new(@target, port: 0)
    @application = server.instance_variable_get(:@application)
    @application.call_service('Probe.Load')
    request = Struct.new(:path, :request_method, :body, :query, :headers) { def [](name) = headers[name] }
    response = Struct.new(:status, :body, :headers) do
      def []=(name, value)
        headers[name] = value
      end
    end.new(nil, nil, {})
    query = { 'xpath' => '[Rank >= $minimum]', 'xpath_variables' => '{"minimum":3}' }
    server.send(:dispatch, request.new('/api/entities/Probe.Row', 'GET', '', query, {}), response)
    expect(JSON.parse(response.body).fetch('records').map { _1.dig('attributes', 'Name') }).to eq(['North'])

    exporter = Mxrb::RubyApp::Exporter.new(@source, @target, mendix_sidecar: @directory)
    Mxrb.open(@source) do |project|
      exporter.instance_variable_set(:@project, project)
      expect { exporter.send(:nanoflow_association_retrieve, 'AssociationId' => 'Probe.Missing') }
        .to raise_error(Mxrb::SerializationError, /unknown nanoflow association Probe.Missing/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
