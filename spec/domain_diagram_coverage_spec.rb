# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

module DomainDiagramCoverageFixtures
  Request = Struct.new(:request_method, :path, :body, :headers) do
    def [](name) = headers[name]
  end
  Response = Struct.new(:status, :body, :headers) do
    def []=(name, value)
      headers[name] = value
    end
  end
end

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::DomainDiagram, 'complete main implementation paths' do
  def server_files(directory, external: false)
    source_directory = File.join(directory, 'source')
    target_directory = File.join(directory, 'target')
    FileUtils.mkdir_p(source_directory)
    FileUtils.mkdir_p(target_directory)
    source = File.join(source_directory, 'App.mpr')
    File.binwrite(source, 'mpr')
    if external
      FileUtils.mkdir_p(File.join(source_directory, 'mprcontents'))
      File.binwrite(File.join(source_directory, 'mprcontents', 'asset.bin'), 'asset')
    end
    [source, File.join(target_directory, 'App-layout.mpr')]
  end

  def dispatch(server, method, path, body: '', headers: {})
    response = DomainDiagramCoverageFixtures::Response.new(nil, nil, {})
    request = DomainDiagramCoverageFixtures::Request.new(method, path, body, headers)
    server.send(:dispatch, request, response)
    response
  end

  def stub_web_ui(directory) # rubocop:disable Metrics/AbcSize
    root = File.join(directory, 'web-ui')
    FileUtils.mkdir_p(File.join(root, 'assets'))
    File.binwrite(File.join(root, 'domain.html'), '<!doctype html><title>Domain bundle</title>')
    File.binwrite(File.join(root, 'uml.html'), '<!doctype html><title>UML bundle</title>')
    File.binwrite(File.join(root, 'assets', 'domain.js'), 'globalThis.mxrbDomain = true')
    File.binwrite(File.join(root, 'assets', 'domain.css'), 'body { color: #123; }')
    File.binwrite(File.join(root, 'assets', 'data.bin'), "\x00\x01")
    allow(Mxrb::WebUi).to receive(:root).and_return(root)
  end

  it 'closes defensively and skips modules or associations without model endpoints' do
    allow(Mxrb::Model::Project).to receive(:open).and_raise(Errno::ENOENT, 'missing')
    expect { described_class::Document.new('/missing').to_h }.to raise_error(Errno::ENOENT)
    allow(Mxrb::Model::Project).to receive(:open).and_return(nil)
    expect { described_class::Document.new('/missing').to_h }.to raise_error(NoMethodError)

    compiler = described_class::Document.new('/tmp/model.mpr')
    expect(compiler.send(:module_payload, double(domain_model: nil), {}, {})).to be_nil
    attribute = double(name: 'Name', type: :string, required: false, unique: false)
    entity = double(
      id: 'entity', name: 'Temporary', qualified_name: nil, persistable: false,
      location: nil, attributes: [attribute], oql_view?: false
    )
    expect(compiler.send(:entity_payload, entity, 'Demo')).to include(
      qualified_name: 'Demo.Temporary', kind: 'dto', x: 0, y: 0
    )
    association = double(
      from_entity_id: 'missing', to_entity_id: 'target', id: 'association', name: 'Missing',
      association_type: :Reference, owner: :Default
    )
    expect(compiler.send(:association_payload, association, {}, { 'target' => 'Demo.Target' }, {}))
      .to be_nil
  end

  it 'covers LayoutWriter validation and upper-case/hash legacy documents' do
    writer = described_class::LayoutWriter.new('/tmp/layout.mpr')
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise(Errno::ENOENT, 'missing')
    expect { writer.apply!('modules' => []) }.to raise_error(Errno::ENOENT)

    mpr = double
    allow(mpr).to receive(:transaction).and_yield
    allow(mpr).to receive(:units_by_containment).with('Modules').and_return([])
    allow(mpr).to receive(:close)
    allow(Mxrb::IO::MprFile).to receive(:open).and_return(mpr)
    expect do
      writer.apply!('modules' => [{ 'name' => 'Missing' }])
    end.to raise_error(Mxrb::ValidationError, /domain module Missing not found/)
    expect(mpr).to have_received(:close)

    module_unit = { 'UnitID' => 'module' }
    allow(mpr).to receive(:children_of).with('module').and_return([])
    expect do
      writer.send(:apply_module, mpr, module_unit, 'name' => 'NoDomain')
    end.to raise_error(Mxrb::ValidationError, /domain model NoDomain not found/)

    entity_doc = {
      'Entities' => [
        3,
        { '$ID' => 'one', 'Location' => { 'x' => 1, 'y' => 2 } },
        { '$ID' => 'two', 'Location' => { 'x' => 3, 'y' => 4 } }
      ]
    }
    expect(writer.send(:update_entities, entity_doc, [{ 'id' => 'one', 'x' => 10, 'y' => 20 }]))
      .to eq(1)
    expect(entity_doc['Entities'][1]['Location']).to eq('x' => 10, 'y' => 20)
    expect(writer.send(:update_entities, entity_doc, [{ 'id' => 'one', 'x' => 10, 'y' => 20 }]))
      .to eq(0)
    expect do
      writer.send(:update_entities, entity_doc, [{ 'id' => 'forged', 'x' => 0, 'y' => 0 }])
    end.to raise_error(Mxrb::ValidationError, /unknown domain entities/)

    lower_document = { 'entities' => [3, { '$ID' => 'lower', 'location' => '0;0' }] }
    expect(writer.send(:update_entities, lower_document, [{ 'id' => 'lower', 'x' => 5, 'y' => 6 }]))
      .to eq(1)
    expect(lower_document['entities'][1]['location']).to eq('5;6')
  end

  it 'updates native and metadata associations and rejects malformed layout values' do
    writer = described_class::LayoutWriter.new('/tmp/layout.mpr')
    document = {
      'Associations' => [
        3,
        { '$ID' => 'local', 'ParentConnection' => '50;0', 'ChildConnection' => '50;100' },
        { '$ID' => 'untouched', 'ParentConnection' => '50;0', 'ChildConnection' => '50;100' }
      ],
      'CrossAssociations' => [3, { '$ID' => 'cross' }, { '$ID' => 'unmapped' }]
    }
    count, metadata = writer.send(:update_associations, document, [
                                    { 'id' => 'local', 'source_anchor' => 'east', 'target_anchor' => 'west' },
                                    { 'id' => 'cross', 'source_anchor' => 'south', 'target_anchor' => 'north' }
                                  ])
    expect(count).to eq(1)
    expect(metadata).to eq([{ id: 'cross', source_anchor: 'south', target_anchor: 'north' }])
    expect(document['Associations'][1]).to include(
      'ParentConnection' => '100;50', 'ChildConnection' => '0;50'
    )
    expect do
      writer.send(:update_associations, document, [
                    { 'id' => 'forged', 'source_anchor' => 'north', 'target_anchor' => 'south' }
                  ])
    end.to raise_error(Mxrb::ValidationError, /unknown domain associations/)
    expect { writer.send(:bounded_integer, 100_001, 'x') }
      .to raise_error(Mxrb::ValidationError, /outside the diagram canvas/)
    expect { writer.send(:connection, 'diagonal') }
      .to raise_error(Mxrb::ValidationError, /unknown association anchor/)
  end

  it 'validates server inputs and copies external MPR contents safely' do
    Dir.mktmpdir do |directory|
      source, output = server_files(directory, external: true)
      expect { described_class::Server.new(File.join(directory, 'missing.mpr')) }
        .to raise_error(ArgumentError, /MPR not found/)
      expect { described_class::Server.new(source, output: File.dirname(output)) }
        .to raise_error(ArgumentError, /cannot be a directory/)
      symlink = File.join(directory, 'layout-link.mpr')
      File.symlink(File.join(directory, 'absent'), symlink)
      expect { described_class::Server.new(source, output: symlink) }
        .to raise_error(ArgumentError, /cannot be a symbolic link/)
      expect { described_class::Server.new(source, output:, host: '0.0.0.0') }
        .to raise_error(ArgumentError, /must bind to loopback/)

      server = described_class::Server.new(source, output:)
      copied = File.join(File.dirname(output), 'mprcontents', 'asset.bin')
      expect(File.binread(copied)).to eq('asset')
      expect(server.managed_paths).to include(File.join(File.dirname(output), 'mprcontents'))

      same_directory = File.join(File.dirname(source), 'default-output.mpr')
      same = described_class::Server.new(source, output: same_directory)
      expect(same.managed_paths).to eq([same_directory])
      default = described_class::Server.allocate
      default.instance_variable_set(:@source, source)
      expect(default.send(:default_output)).to end_with('/App.domain-layout.mpr')
    end
  end

  it 'starts, yields, and shuts down the WEBrick adapter' do
    Dir.mktmpdir do |directory|
      source, output = server_files(directory)
      adapter = double
      allow(adapter).to receive(:mount_proc)
      allow(adapter).to receive(:start)
      allow(adapter).to receive(:shutdown)
      allow(WEBrick::HTTPServer).to receive(:new).and_return(adapter)
      server = described_class::Server.new(source, output:)
      yielded = nil
      expect(server.shutdown).to be_nil
      server.start { |value| yielded = value }
      expect(yielded).to eq(adapter)
      expect(adapter).to have_received(:mount_proc).with('/')
      expect(adapter).to have_received(:start)
      server.shutdown
      expect(adapter).to have_received(:shutdown)

      other_source = File.join(directory, 'other.mpr')
      other_output = File.join(directory, 'other-layout.mpr')
      File.binwrite(other_source, 'mpr')
      described_class::Server.new(other_source, output: other_output).start
    end
  end

  it 'dispatches HTML, layout writes, fallback routes, and validation failures' do
    Dir.mktmpdir do |directory|
      source, output = server_files(directory)
      stub_web_ui(directory)
      server = described_class::Server.new(source, output:)
      root = dispatch(server, 'GET', '/')
      expect(root.status).to eq(200)
      expect(root.body).to include('Domain bundle')
      expect(root.headers).to include(
        'Content-Type' => 'text/html; charset=utf-8',
        'Cache-Control' => 'no-store', 'X-Content-Type-Options' => 'nosniff'
      )

      script = dispatch(server, 'GET', '/assets/domain.js')
      expect(script.status).to eq(200)
      expect(script.body).to eq('globalThis.mxrbDomain = true')
      expect(script.headers['Content-Type']).to eq('application/javascript; charset=utf-8')
      expect(dispatch(server, 'GET', '/assets/domain.css').headers['Content-Type'])
        .to eq('text/css; charset=utf-8')
      expect(dispatch(server, 'GET', '/assets/data.bin').headers['Content-Type'])
        .to eq('application/octet-stream')
      expect(dispatch(server, 'GET', '/assets/missing.js').status).to eq(404)
      expect(dispatch(server, 'GET', '/assets/../domain.html').status).to eq(404)
      expect(dispatch(server, 'GET', '/assets/%252e%252e/domain.html').status).to eq(404)
      expect(dispatch(server, 'GET', '/client/route').status).to eq(404)
      expect(dispatch(server, 'POST', '/client/route').status).to eq(404)

      writer = instance_double(described_class::LayoutWriter, apply!: 3)
      allow(described_class::LayoutWriter).to receive(:new).with(output).and_return(writer)
      token = server.instance_variable_get(:@token)
      expect(dispatch(server, 'POST', '/api/layout', body: '{}').status).to eq(422)
      saved = dispatch(
        server, 'POST', '/api/layout', body: '{"modules":[]}',
                                       headers: { 'X-MXRB-Token' => token }
      )
      expect(saved.status).to eq(200)
      expect(JSON.parse(saved.body)).to include('ok' => true, 'changed' => 3, 'output' => output)
      oversized = 'x' * (described_class::Server::MAX_BODY_BYTES + 1)
      expect(dispatch(
        server, 'POST', '/api/layout', body: oversized,
                                       headers: { 'X-MXRB-Token' => token }
      ).status).to eq(422)
      expect(dispatch(
        server, 'POST', '/api/layout', body: '{', headers: { 'X-MXRB-Token' => token }
      ).status).to eq(422)
      expect(dispatch(server, 'GET', '/api/missing').status).to eq(404)
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
