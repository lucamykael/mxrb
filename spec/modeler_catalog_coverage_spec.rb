# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Modeler::Catalog do
  subject(:catalog) { described_class.new('/tmp/App.mpr') }

  it 'projects pages, nanoflows, integrations, configurations, and nested widgets' do
    page = Struct.new(
      :id, :name, :title, :url, :layout_id, :excluded, :allowed_module_roles, :widgets
    ).new(
      'page', 'Dashboard', 'Dashboard title', '/dashboard', 'layout', true, ['role'],
      [nil, { type: :button, children: [{ type: nil }] }, { 'children' => [] }]
    )
    flow = Struct.new(
      :id, :name, :documentation, :allowed_module_roles, :parameters, :objects, :flows
    ).new('nano', 'Refresh', 'Refresh client state', ['role'], [{}], [{}, {}], [{}])
    mod = Struct.new(
      :id, :name, :from_app_store, :app_store_guid, :app_store_version,
      :entities, :pages, :microflows, :nanoflows, :module_roles,
      :infrastructure_documents, :application_documents, :domain_documents
    ).new(
      'module', 'Sales', true, 'marketplace-guid', '1.2.3', [], [page], [], [flow],
      [{ name: 'User', description: '' }],
      [
        { id: 'rest', name: 'Public API', type: 'Rest$PublishedRestService', route: 'endpoints' },
        { id: 'mapping', name: 'Payload', type: 'ExportMappings$ExportMapping', route: 'mappings/exports' }
      ],
      [{ id: 'job', name: 'Cleanup', type: 'ScheduledEvents$ScheduledEvent', route: 'jobs/scheduled_events' }],
      [{ id: 'constant', name: 'Limit', type: 'Constants$Constant', route: 'constants' }]
    )

    payload = catalog.send(:module_payload, mod)

    expect(payload).to include(
      marketplace: true, marketplace_guid: 'marketplace-guid', marketplace_version: '1.2.3'
    )
    expect(payload.fetch(:pages).first).to include(
      qualified_name: 'Sales.Dashboard', excluded: true, widget_count: 3,
      widget_types: { 'button' => 1 }
    )
    expect(payload.fetch(:nanoflows).first).to include(
      qualified_name: 'Sales.Refresh', kind: 'nanoflow', parameter_count: 1,
      object_count: 2, flow_count: 1
    )
    expect(payload.fetch(:integrations).map { _1.fetch(:id) }).to eq(%w[rest mapping])
    expect(payload.fetch(:configurations).map { _1.fetch(:id) }).to contain_exactly('job', 'constant')
  end

  it 'covers empty security, settings scalars, blank types, and failed project opening' do
    expect(catalog.send(:security_payload, [])).to eq(
      configured: false, level: nil, user_roles: []
    )
    documents = [
      {
        id: 'settings', type: 'Settings$Configuration',
        document: {
          '$Type' => 'Settings$Configuration', 'Name' => 'Runtime',
          'Enabled' => true, 'Retries' => 3, 'Nested' => {}, 'Items' => []
        }
      },
      { id: 'page', type: 'Pages$Page', document: { 'Name' => 'Home' } }
    ]
    expect(catalog.send(:settings_payload, documents).first).to include(
      name: 'Runtime', values: { 'Name' => 'Runtime', 'Enabled' => true, 'Retries' => 3 }
    )

    project = Struct.new(:all_units) do
      def parse_bson(unit) = unit.fetch('document')
    end.new(
      [
        { 'UnitID' => 'blank', 'document' => {} },
        { 'UnitID' => 'typed', 'document' => { '$Type' => 'Settings$Configuration' } }
      ]
    )
    expect(catalog.send(:project_documents, project).map { _1.fetch(:id) }).to eq(['typed'])

    allow(Mxrb::Model::Project).to receive(:open).and_raise(Mxrb::Error, 'broken MPR')
    expect { catalog.to_h }.to raise_error(Mxrb::Error, /broken MPR/)
  end
end
# rubocop:enable Metrics/BlockLength
