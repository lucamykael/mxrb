# frozen_string_literal: true

require 'json'
require 'open3'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'MXRB UML diagrams' do
  def build_project(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Sales) do
        entity(:Customer) { string :Name }
        entity(:Order) do
          decimal :Total
          association 'Sales.Customer', name: :Order_Customer
          association 'Sales.Tag', name: :Order_Tags, type: :ReferenceSet
        end
        entity(:Tag) { string :Label }
        entity(:Payload) { non_persistent! }
        entity(:Summary) { oql_view query: 'SELECT Total FROM Sales.Order' }
        microflow(:CreateOrder) { call_microflow 'Sales.ValidateOrder' }
        microflow(:ValidateOrder) { call_microflow 'Sales.PersistOrder' }
        microflow(:PersistOrder)
      end
      self.module(:Billing) { microflow(:Charge) }
    end
  end

  def stub_web_ui(directory) # rubocop:disable Metrics/AbcSize
    root = File.join(directory, 'web-ui')
    FileUtils.mkdir_p(File.join(root, 'assets'))
    File.binwrite(File.join(root, 'domain.html'), '<!doctype html><title>Domain bundle</title>')
    File.binwrite(File.join(root, 'modeler.html'), '<!doctype html><title>Modeler bundle</title>')
    File.binwrite(File.join(root, 'uml.html'), '<!doctype html><title>UML bundle</title>')
    File.binwrite(File.join(root, 'assets', 'uml.js'), 'globalThis.mxrbUml = true')
    File.binwrite(File.join(root, 'assets', 'mark.svg'), '<svg xmlns="http://www.w3.org/2000/svg"/>')
    allow(Mxrb::WebUi).to receive(:root).and_return(root)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, 'Shop.mpr')
      build_project(@path)
      Mxrb.open(@path) do |project|
        @project = project
        example.run
      end
    end
  end

  it 'renders typed class diagrams with stereotypes and multiplicities' do
    diagram = Mxrb::Uml::ClassDiagram.new(@project.modules)
    mermaid = diagram.to_mermaid
    plantuml = diagram.to_plantuml

    expect(mermaid).to include(
      'classDiagram', 'Sales.Order', '+Decimal Total', '<<DTO>>', '<<OQL View>>',
      '"1" --> "N"', '"*" --> "*"'
    )
    expect(plantuml).to include('@startuml', 'Sales.Order', 'Order_Customer', '@enduml')
  end

  it 'projects the complete project catalog for the React modeler' do
    payload = Mxrb::Modeler::Catalog.new(@path).to_h

    expect(payload.fetch(:project)).to include(name: 'Shop', mendix_version: '11.12.1')
    expect(payload.fetch(:summary)).to include(
      modules: 2, entities: 5, microflows: 4, nanoflows: 0
    )
    sales = payload.fetch(:modules).find { _1.fetch(:name) == 'Sales' }
    expect(sales).to include(marketplace: false)
    expect(sales.fetch(:entities).map { _1.fetch(:qualified_name) }).to include('Sales.Order')
    expect(sales.fetch(:microflows).map { _1.fetch(:qualified_name) }).to include('Sales.CreateOrder')
    expect(payload).to include(:navigation, :security, :settings)
    expect { JSON.generate(payload) }.not_to raise_error
  end

  it 'renders native microflow objects and sequence-flow edges as activities' do
    flow = @project.modules.find { _1.name == 'Sales' }.microflows.find { _1.name == 'CreateOrder' }
    diagram = Mxrb::Uml::ActivityDiagram.new(flow)

    expect(diagram.to_mermaid).to include('flowchart TD', 'Start', 'Call Sales.ValidateOrder', '-->')
    expect(diagram.to_plantuml).to include('@startuml', 'CreateOrder', 'Call Sales.ValidateOrder', '@enduml')
  end

  it 'renders decisions, fallback action names, and hash or scalar branch labels' do
    objects = [
      { '$ID' => 'decision', '$Type' => 'Microflows$DecisionMergeActivity' },
      {
        '$ID' => 'action', '$Type' => 'Microflows$ActionActivity',
        'Caption' => 'Activity', 'AutoGenerateCaption' => true,
        'Action' => { '$Type' => 'Microflows$ChangeObjectAction' }
      },
      {
        '$ID' => 'captioned', '$Type' => 'Microflows$ActionActivity',
        'Caption' => 'Custom caption', 'AutoGenerateCaption' => false
      },
      { '$ID' => 'end', '$Type' => 'Microflows$EndEvent' }
    ]
    flows = [
      {
        'Origin' => 'decision', 'Destination' => 'action',
        'CaseValue' => { '$Type' => 'Microflows$EnumerationCase', 'StringRepresentation' => 'Approved' }
      },
      { 'Origin' => 'action', 'Destination' => 'end', 'caseValue' => 7 },
      { 'Origin' => 'decision', 'Destination' => 'captioned', 'Caption' => 'Direct' },
      { 'Origin' => 'captioned', 'Destination' => 'end' },
      { 'Origin' => 'missing', 'Destination' => 'end' }
    ]
    microflow = Struct.new(:name, :objects, :flows).new('Branching', objects, flows)
    diagram = Mxrb::Uml::ActivityDiagram.new(microflow)

    expect(diagram.to_mermaid).to include(
      '{"Decision Merge Activity"}', 'Change Object', 'Custom caption', 'Approved', 'Direct', '7'
    )
    expect(diagram.to_plantuml).to include(
      'choice "Decision Merge Activity"', 'Change Object', 'Custom caption', 'Approved', 'Direct', '7'
    )
  end

  it 'expands sequence call chains by depth and supports module mode' do
    shallow = Mxrb::Uml::SequenceDiagram.new(@project.semantic_index, root: 'Sales.CreateOrder', depth: 1)
    deep = Mxrb::Uml::SequenceDiagram.new(@project.semantic_index, root: 'Sales.CreateOrder', depth: 2)
    by_module = Mxrb::Uml::SequenceDiagram.new(@project.semantic_index, module_name: 'Sales')

    expect(shallow.to_mermaid).to include('Sales.CreateOrder', 'Sales.ValidateOrder')
    expect(shallow.to_mermaid).not_to include('Sales.PersistOrder')
    expect(deep.to_mermaid).to include('Sales.PersistOrder', '->>')
    expect(by_module.to_plantuml).to include('Sales.CreateOrder', 'Sales.PersistOrder', '@enduml')
  end

  it 'ignores non-call references and calls leaving module mode' do
    artifact = Mxrb::Semantic::Artifact
    reference = Mxrb::Semantic::Reference
    source = artifact.new('source', 'Local.Run', :microflow, 'Local', 'Run', nil, [], {})
    external = artifact.new('external', 'Remote.Run', :microflow, 'Remote', 'Run', nil, [], {})
    entity = artifact.new('entity', 'Local.Item', :entity, 'Local', 'Item', nil, [], {})
    index = Struct.new(:artifacts, :references) do
      def references_from(_source) = references
    end.new(
      [source, external, entity],
      [
        reference.new(source, entity, :uses_entity, [], 'Local.Item'),
        reference.new(source, external, :calls, [], 'Remote.Run')
      ]
    )

    diagram = Mxrb::Uml::SequenceDiagram.new(index, module_name: 'Local')
    expect(diagram.to_mermaid).to include('Local.Run', 'No call relationships found')
    expect(diagram.to_mermaid).not_to include('Remote.Run')
  end

  it 'validates sequence selection and renders an empty zero-depth chain' do
    index = @project.semantic_index
    expect { Mxrb::Uml::SequenceDiagram.new(index) }.to raise_error(ArgumentError, /required/)
    expect { Mxrb::Uml::SequenceDiagram.new(index, root: 'A', module_name: 'B') }
      .to raise_error(ArgumentError, /either/)
    expect { Mxrb::Uml::SequenceDiagram.new(index, root: 'Missing.Flow') }
      .to raise_error(ArgumentError, /not found/)
    expect { Mxrb::Uml::SequenceDiagram.new(index, module_name: 'Missing') }
      .to raise_error(ArgumentError, /module not found/)
    expect { Mxrb::Uml::SequenceDiagram.new(index, root: 'Sales.CreateOrder', depth: -1) }
      .to raise_error(ArgumentError, /zero or greater/)
    expect { Mxrb::Uml::SequenceDiagram.new(index, root: 'Sales.CreateOrder', depth: 101) }
      .to raise_error(ArgumentError, /cannot exceed/)

    empty = Mxrb::Uml::SequenceDiagram.new(index, root: 'Sales.CreateOrder', depth: 0)
    expect(empty.to_mermaid).to include('Sales.CreateOrder', 'No call relationships found')
    expect(empty.to_plantuml).to include('No call relationships found')

    no_calls = Mxrb::Uml::SequenceDiagram.new(index, module_name: 'Billing')
    expect(no_calls.to_mermaid).to include('Billing.Charge', 'No call relationships found')

    defensive = Mxrb::Uml::SequenceDiagram.allocate
    defensive.instance_variable_set(:@participants, [])
    lines = []
    defensive.send(:append_mermaid_empty_note, lines)
    expect(lines).to eq(['  Note over MXRB: No call relationships found'])
  end

  it 'produces collision-resistant identifiers and escapes diagram text' do
    dotted = Mxrb::Uml::Support.identifier('Sales.Order')
    underscored = Mxrb::Uml::Support.identifier('Sales_Order')

    expect(dotted).not_to eq(underscored)
    expect(Mxrb::Uml::Support.identifier('', prefix: 'empty')).to eq('empty_e3b0c442')
    expect(Mxrb::Uml::Support.mermaid_text(%(<tag> & "name"\nnext)))
      .to eq('&lt;tag&gt; &amp; &quot;name&quot; next')
    expect(Mxrb::Uml::Support.plantuml_text("path\\name\nnext"))
      .to eq('path\\\\name next')
  end

  it 'renders enumeration attributes, explicit names, and skips dangling associations' do
    attribute = Struct.new(:name, :type, :enumeration)
    entity = Struct.new(:id, :name, :qualified_name, :attributes, :persistable) do
      def oql_view? = false
    end
    association = Struct.new(:from_entity_id, :to_entity_id, :association_type, :name)
    mod = Struct.new(:name, :entities, :associations)
    order = entity.new('order', 'Order', 'Canonical.Order', [
                         attribute.new('Status', :enum, 'Demo.OrderStatus')
                       ], true)
    customer = entity.new('customer', 'Customer', '', [], true)
    fixture = mod.new('Demo', [order, customer], [
                        association.new('order', 'customer', :Reference, 'Order_Customer'),
                        association.new('order', 'missing', :Reference, 'Dangling')
                      ])

    diagram = Mxrb::Uml::ClassDiagram.new([fixture])
    expect(diagram.to_mermaid).to include('Canonical.Order', '+Order Status Status', 'Order_Customer')
    expect(diagram.to_mermaid).not_to include('Dangling')
    expect(diagram.to_plantuml).to include('Canonical.Order', 'Status : Order Status')
  end

  it 'serves all UML endpoints through the loopback-only viewer' do
    stub_web_ui(File.dirname(@path))
    server = Mxrb::Uml::Server.new(@path)
    request_class = Struct.new(:request_method, :path, :query)
    response_class = Struct.new(:status, :body, :headers) do
      def []=(name, value)
        headers[name] = value
      end
    end
    dispatch = lambda do |method, path, query = {}|
      response = response_class.new(nil, nil, {})
      server.send(:dispatch, request_class.new(method, path, query), response)
      response
    end

    root = dispatch.call('GET', '/')
    expect(root.body).to include('UML bundle')
    expect(dispatch.call('GET', '/modeler').body).to include('Modeler bundle')
    expect(root.headers).to include(
      'Content-Type' => 'text/html; charset=utf-8',
      'Cache-Control' => 'no-store', 'X-Content-Type-Options' => 'nosniff'
    )
    script = dispatch.call('GET', '/assets/uml.js')
    expect(script.body).to eq('globalThis.mxrbUml = true')
    expect(script.headers['Content-Type']).to eq('application/javascript; charset=utf-8')
    expect(dispatch.call('GET', '/assets/mark.svg').headers['Content-Type'])
      .to eq('image/svg+xml; charset=utf-8')
    expect(dispatch.call('GET', '/assets/missing.js').status).to eq(404)
    expect(dispatch.call('GET', '/assets/%2e%2e/uml.html').status).to eq(404)
    expect(JSON.parse(dispatch.call('GET', '/api/catalog').body)).to include('modules', 'microflows')
    expect(JSON.parse(dispatch.call('GET', '/api/project').body)).to include(
      'project', 'summary', 'modules', 'navigation', 'security', 'settings'
    )
    expect(JSON.parse(dispatch.call('GET', '/api/class', 'modules' => 'Sales').body))
      .to include('mermaid', 'plantuml')
    expect(JSON.parse(dispatch.call('GET', '/api/class').body))
      .to include('mermaid', 'plantuml')
    expect(JSON.parse(dispatch.call('GET', '/api/activity', 'microflow' => 'Sales.CreateOrder').body))
      .to include('mermaid', 'plantuml')
    expect(JSON.parse(dispatch.call('GET', '/api/sequence', 'root' => 'Sales.CreateOrder').body))
      .to include('mermaid', 'plantuml')
    expect(JSON.parse(dispatch.call('GET', '/api/sequence', 'module' => 'Sales').body))
      .to include('mermaid', 'plantuml')
    expect(dispatch.call('GET', '/missing').status).to eq(404)
    expect(dispatch.call('POST', '/api/class').status).to eq(405)
    expect(dispatch.call('GET', '/api/class', 'modules' => 'Missing').status).to eq(422)
    expect(dispatch.call('GET', '/api/activity', {}).status).to eq(422)
    expect(dispatch.call(
      'GET', '/api/activity', 'microflow' => 'Missing.Flow'
    ).status).to eq(422)
    expect(dispatch.call('GET', '/api/activity', 'microflow' => 'Invalid').status).to eq(422)
    expect(dispatch.call('GET', '/api/sequence', {}).status).to eq(422)
    expect(dispatch.call(
      'GET', '/api/sequence', 'root' => 'Sales.CreateOrder', 'module' => 'Sales'
    ).status).to eq(422)
    expect(dispatch.call(
      'GET', '/api/sequence', 'root' => 'Sales.CreateOrder', 'depth' => '101'
    ).status).to eq(422)
  end

  it 'validates server source and binding and exposes start/shutdown hooks' do
    expect { Mxrb::Uml::Server.new('/missing.mpr') }.to raise_error(ArgumentError, /not found/)
    expect { Mxrb::Uml::Server.new(@path, host: '0.0.0.0') }.to raise_error(ArgumentError, /loopback/)

    server = Mxrb::Uml::Server.new(@path)
    expect(server.shutdown).to be_nil
    http = instance_double(Mxrb::Http::Server)
    puma = instance_double(Puma::Server)
    allow(http).to receive(:start).and_yield(puma)
    allow(http).to receive(:shutdown)
    allow(Mxrb::Http::Server).to receive(:new).and_return(http)
    expect { |block| server.start(&block) }.to yield_with_args(puma)
    server.shutdown

    server_without_block = Mxrb::Uml::Server.new(@path)
    server_without_block.start
    expect(http).to have_received(:start).twice

    allow(Mxrb::Model::Project).to receive(:open).and_raise(Mxrb::Error, 'invalid project')
    expect { server.send(:with_project) { nil } }.to raise_error(Mxrb::Error, /invalid project/)
  end

  it 'exports UML through the CLI without affecting the ER command' do
    executable = File.expand_path('../../bin/mxrb', __dir__)
    class_stdout, class_stderr, class_status = Open3.capture3(
      RbConfig.ruby, executable, 'uml', @path, '--export=class'
    )
    sequence_stdout, sequence_stderr, sequence_status = Open3.capture3(
      RbConfig.ruby, executable, 'uml', @path, '--export=sequence', '--module=Sales',
      '--format=plantuml'
    )

    expect([class_status.success?, class_stderr, class_stdout])
      .to match([true, '', include('classDiagram', 'Sales.Order')])
    expect([sequence_status.success?, sequence_stderr, sequence_stdout])
      .to match([true, '', include('@startuml', 'Sales.CreateOrder', '@enduml')])
  end
end
# rubocop:enable Metrics/BlockLength
