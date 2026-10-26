# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'digest'
require 'mxrb/studio/data_explorer'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Studio::DataExplorer do
  def build_project(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Sales) do
        entity(:Customer) { string :Name }
        entity(:VipCustomer) { generalizes 'Sales.Customer' }
        entity(:Order) { association 'Logistics.Shipment', name: :Order_Shipment }
        entity(:OrderPayload) { non_persistent! }
        entity(:SpecialPayload) { generalizes 'Sales.OrderPayload' }
        entity(:OrderSummary) { oql_view query: 'SELECT Name FROM Sales.Customer' }
        entity(:Account) { generalizes 'System.User' }
      end
      self.module(:Logistics) do
        entity(:Shipment) { string :TrackingCode }
        entity(:PriorityCustomer) { generalizes 'Sales.Customer' }
      end
    end
  end

  let(:workspace) { instance_double(Mxrb::Runtime::DatabaseWorkspace) }

  def physical_tables # rubocop:disable Metrics/MethodLength
    [{ schema: 'public', name: 'line items', kind: 'table',
       columns: [{ name: 'tenant', ordinal: 1 }, { name: 'order', ordinal: 2 }],
       constraints: [
         { name: 'items_pk', type: 'p', columns: %w[tenant order], validated: true },
         { name: 'order_fk', type: 'f', columns: %w[tenant order],
           target_schema: 'other.schema', target_table: 'orders',
           target_columns: %w[tenant_id order_id], validated: false }
       ],
       indexes: [{ name: 'items_idx', key_count: 2,
                   columns: [{ ordinal: 1, name: 'order', included: false },
                             { ordinal: 2, name: nil, expression: 'lower(tenant)', included: false },
                             { ordinal: 3, name: 'note', included: true }] }] },
     { schema: 'public', name: 'sales$customer', kind: 'table',
       columns: [], constraints: [], indexes: [] }]
  end

  it 'projects global model relationships, inheritance, DTOs and views without claiming physical tables' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Shop.mpr')
      build_project(path)
      digest = Digest::SHA256.file(path).hexdigest
      allow(Mxrb::Runtime::DatabaseWorkspace).to receive(:new).and_raise('must remain offline')
      data = described_class.new(path).to_h

      expect(data.fetch(:physical)).to include(status: 'not_requested', confirmed: false, tables: [])
      logical = data.fetch(:logical)
      expect(logical.fetch(:modules).map { _1[:name] }).to contain_exactly('Sales', 'Logistics')
      expect(logical[:physical_schema_confirmed]).to be(false)
      expect(logical[:entities]).to include(
        include(qualified_name: 'Sales.OrderPayload', kind: 'dto',
                physical_mapping: { status: 'not_applicable' }),
        include(qualified_name: 'Sales.SpecialPayload', kind: 'dto', persistent: false,
                persistence_resolved: true, physical_mapping: { status: 'not_applicable' }),
        include(qualified_name: 'Sales.Account', persistent: nil, persistence_resolved: false),
        include(qualified_name: 'Sales.OrderSummary', kind: 'oql_view',
                physical_mapping: { status: 'not_applicable' }),
        include(qualified_name: 'Sales.Customer', physical_mapping: { status: 'unmapped' })
      )
      expect(logical[:relationships]).to include(
        include(kind: 'association', from: 'Sales.Order', to: 'Logistics.Shipment',
                cross_module: true, physical: false),
        include(kind: 'inheritance', from: 'Sales.VipCustomer', to: 'Sales.Customer',
                cross_module: false, target_resolved: true),
        include(kind: 'inheritance', from: 'Logistics.PriorityCustomer', to: 'Sales.Customer',
                cross_module: true, target_resolved: true),
        include(kind: 'inheritance', from: 'Sales.Account', to: 'System.User',
                target_resolved: false)
      )
      expect(logical[:external_entities]).to include('System.User')
      expect(Digest::SHA256.file(path).hexdigest).to eq(digest)

      filtered = described_class.new(path, modules: ['Sales']).logical
      expect(filtered[:modules].map { _1[:name] }).to eq(['Sales'])
      expect(filtered[:external_entities]).to contain_exactly('Logistics.Shipment', 'System.User')
      expect { described_class.new(path, modules: ['Missing']).logical }
        .to raise_error(ArgumentError, /unknown modules/)
    end
  end

  it 'uses a real catalog query, preserves composite order and index expressions, and never guesses entity mappings' do
    expect(workspace).to receive(:query_rows).with(described_class::SCHEMA_SQL)
                                             .and_return([{ 'tables_json' => JSON.generate(physical_tables) }])
    result = described_class.new('/not-opened.mpr', workspace:).physical

    expect(result).to include(status: 'available', confirmed: true, visibility: 'reader_accessible_relations')
    table = result[:tables].first
    expect(table[:primary_key]).to include(columns: %w[tenant order])
    expect(table[:foreign_key_count]).to eq(1)
    expect(table[:indexes].first[:columns]).to eq(physical_tables.first[:indexes].first[:columns])
    expect(result[:relationships]).to contain_exactly(
      include(name: 'order_fk', kind: 'foreign_key', confirmed: true, validated: false,
              from: '"public"."line items"', to: '"other.schema"."orders"',
              column_pairs: [{ from: 'tenant', to: 'tenant_id', ordinal: 1 },
                             { from: 'order', to: 'order_id', ordinal: 2 }])
    )
    expect(result[:tables].last).to include(logical_mapping: { status: 'unmapped' })
    expect(result[:tables].last).not_to have_key(:entity)
  end

  it 'does not replace an unavailable physical catalog with guessed model data' do
    allow(workspace).to receive(:query_rows).and_raise(Mxrb::ToolchainError, 'database unavailable')
    explorer = described_class.new('/not-opened.mpr', workspace:)
    expect(explorer.physical).to include(status: 'unavailable', confirmed: false, tables: [], relationships: [],
                                         error: include(code: 'physical_schema_unavailable'))
    allow(workspace).to receive(:query_rows).and_return([{ 'tables_json' => 'not-json' }])
    expect(explorer.physical).to include(status: 'unavailable', confirmed: false)
    allow(workspace).to receive(:query_rows).and_return([])
    expect(explorer.physical).to include(status: 'unavailable', confirmed: false)
  end

  it 'passes SQL and OQL parameter values through the read-only query service without interpolation' do
    allow(workspace).to receive(:query_rows).and_return([{ 'Name' => 'ação' }])
    explorer = described_class.new('/not-opened.mpr', workspace:)
    value = "ação' OR 1=1 --"
    expect(explorer.query('sql' => 'SELECT :Name', 'params' => { 'Name' => value }))
      .to include(ok: true, row_count: 1)
    expect(workspace).to have_received(:query_rows).with('SELECT :Name', params: { 'Name' => value })
    expect(explorer.query('oql' => 'SELECT * FROM Sales.Customer WHERE Name = $Name',
                          'params' => { 'Name' => value })).to include(ok: true)
    expect(workspace).to have_received(:query_rows)
      .with(include('"sales$customer"', ':Name'), params: { 'Name' => value })
    expect(explorer.query('oql' => 'DELETE FROM Sales.Customer')).to include(ok: false)
  end

  it 'explains parameterized SQL or OQL without executing ANALYZE unless explicitly requested' do
    report = Data.define(:engine, :findings).new(:postgresql, [])
    allow(workspace).to receive(:explain).and_return(report)
    explorer = described_class.new('/not-opened.mpr', workspace:)
    expect(explorer.explain('sql' => 'SELECT :Id', 'params' => { 'Id' => 42 }))
      .to include(ok: true, analyzed: false, plan: report.to_h)
    expect(workspace).to have_received(:explain).with('SELECT :Id', params: { 'Id' => 42 }, analyze: false)
    expect(explorer.explain('oql' => 'SELECT * FROM Sales.Customer WHERE Name = $Name',
                            'params' => { 'Name' => 'A' }, 'analyze' => true))
      .to include(ok: true, analyzed: true, warnings: include(/logical table/))
    expect(workspace).to have_received(:explain).with(include(':Name'), params: { 'Name' => 'A' }, analyze: true)
    expect(explorer.explain('sql' => 'SELECT 1', 'analyze' => 'false')).to include(ok: false)
    expect(explorer.explain([])).to include(ok: false)
    expect(explorer.explain('oql' => 'SELECT * FROM Sales.Customer WHERE Name = $Name'))
      .to include(ok: false, error: include(code: 'invalid_request'))
    allow(workspace).to receive(:explain).and_raise(Mxrb::ToolchainError, 'database unavailable')
    expect(explorer.explain('sql' => 'SELECT 1'))
      .to include(ok: false, error: include(code: 'explain_failed'))
  end

  it 'serializes planner findings as structured JSON instead of Ruby object descriptions' do
    report = Mxrb::Oql::PlanAnalyzer.new.analyze([{ 'Plan' => {
                                                   'Node Type' => 'Seq Scan', 'Schema' => 'public',
                                                   'Relation Name' => 'orders', 'Plan Rows' => 4_000,
                                                   'Total Cost' => 2_500
                                                 } }])
    allow(workspace).to receive(:explain).and_return(report)
    result = described_class.new('/not-opened.mpr', workspace:).explain('sql' => 'SELECT * FROM orders')
    response = JSON.parse(JSON.generate(result))
    expect(response.dig('plan', 'findings').first)
      .to include('node_type' => 'Seq Scan', 'rule' => 'sequential_scan', 'severity' => 'warning')
  end
  it 'includes the physical catalog on request and reports defensive failures as structured errors' do
    allow(workspace).to receive(:query_rows).and_return([{ 'tables_json' => '{}' }])
    explorer = described_class.new('/not-opened.mpr', workspace:)
    allow(explorer).to receive(:logical).and_return({})
    expect(explorer.to_h(include_physical: true)[:physical]).to include(status: 'unavailable')
    allow(Mxrb::Oql::Server).to receive(:new).and_raise(Mxrb::ToolchainError, 'no server')
    expect(explorer.query('sql' => 'SELECT 1')).to eq(ok: false, error: { code: 'query_failed', message: 'no server' })
    allow(Mxrb::Model::Project).to receive(:open).and_raise(Mxrb::NotMprError, 'not a model')
    expect { explorer.send(:entity_details) }.to raise_error(Mxrb::NotMprError)
    cyclic = { 'A.X' => { generalization: 'A.Y' }, 'A.Y' => { generalization: 'A.X' } }
    expect(explorer.send(:inherited_persistence, 'A.X', cyclic, [])).to be_nil
  end

  it 'validates explain requests before reaching the database' do
    explorer = described_class.new('/not-opened.mpr', workspace:)
    expect(explorer.explain('sql' => 'SELECT 1', 'oql' => 'SELECT 1'))
      .to include(ok: false, error: include(message: /exactly one/))
    expect(explorer.explain('sql' => 'SELECT 1', 'params' => []))
      .to include(ok: false, error: include(message: /JSON object/))
    expect(explorer.explain('oql' => 'DELETE FROM Sales.Customer')).to include(ok: false)
  end
end
# rubocop:enable Metrics/BlockLength
