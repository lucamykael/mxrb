# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../lib/mxrb/studio_schema_catalog'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'remaining defensive branch contracts' do
  it 'normalizes record rename signatures and non-native array markers' do
    identity = Mxrb::RubyApp::RecordIdentity.allocate
    expect(identity.send(:rename_signature, :associations, 'App.Order_Customer', nil))
      .to eq('Order_Customer')
    expect(identity.send(:rename_signature, :lifecycle, :before_commit, nil)).to eq('before_commit')

    compatibility = Mxrb::StudioCompatibility.allocate
    expect(compatibility.send(:array_marker, ['value'])).to be_nil
  end

  it 'rejects scalar native fragments and cleans failed temporary writes' do
    Dir.mktmpdir('mxrb-fragment-branches-') do |dir|
      store = Mxrb::NativeFragmentStore.new(dir)
      payload = Mxrb::IO::BsonCodec.serialize('value' => 'scalar')
      digest = Digest::SHA256.hexdigest(payload)
      File.binwrite(File.join(dir, "#{digest}.bson"), payload)
      allow(Mxrb::IO::BsonCodec).to receive(:parse).with(payload).and_return('scalar')
      expect { store.fetch(digest) }
        .to raise_error(Mxrb::ValidationError, /is not a document/)

      allow(File).to receive(:rename).and_raise(IOError, 'blocked')
      expect { store.put('Future' => true) }.to raise_error(IOError, /blocked/)
      expect(Dir.glob(File.join(dir, '*.tmp-*'))).to be_empty
    end
  end

  it 'rejects duplicate page identities and restores only applicable design properties' do
    duplicate_manifest = double(modules: [{ 'pages' => [{ 'id' => 'same' }, { 'id' => 'same' }] }])
    expect { Mxrb::RubyApp::PageDesignIdentity.new(duplicate_manifest) }
      .to raise_error(Mxrb::ValidationError, /duplicate private page identity/)

    manifest = double(modules: [{ 'pages' => [{
      'id' => 'page-id', 'widgets' => [{
        'type' => 'data_view', 'name' => 'Details',
        'options' => { 'design_properties' => [{
          'key' => 'Color', 'option' => 'Red', 'id' => 'old-id', 'value_id' => 'old-value'
        }] }
      }]
    }] }])
    identity = Mxrb::RubyApp::PageDesignIdentity.new(manifest)
    untouched = [{ 'type' => 'data_view', 'name' => 'Details', 'options' => {} }]
    expect(identity.restore('missing', untouched)).to equal(untouched)
    expect(identity.restore('page-id', untouched)).to eq(untouched)

    declarations = [
      { 'future' => true },
      { 'key' => 'Color', 'option' => 'Blue' },
      { 'key' => 'RenamedColor', 'option' => 'Green', 'id' => 'old-id' }
    ]
    expect do
      identity.send(
        :resolve_properties,
        [{ 'key' => 'Color', 'option' => 'Red', 'id' => 'old-id', 'value_id' => 'old-value' }],
        declarations
      )
    end.to raise_error(Mxrb::ValidationError, /duplicate design property identity claim/)
  end

  it 'classifies schema references and rejects cycles and malformed fields' do
    catalog = Mxrb::StudioSchemaCatalog.allocate
    expect(catalog.send(:reference_kind, 'x.localByNameReference(y)')).to eq('by_name')
    expect(catalog.send(:reference_kind, 'x.byNameReference(y)')).to eq('by_name')
    expect(catalog.send(:reference_kind, 'x.byIdReference(y)')).to eq('by_id')
    expect(catalog.send(:reference_kind, 'x.Reference(y)')).to eq('reference')
    expect(catalog.send(:reference_kind, 'x.string()')).to be_nil
    types = {
      'A' => { base: 'B', properties: [] },
      'B' => { base: 'A', properties: [] }
    }
    expect { catalog.send(:inherited_properties, 'A', types) }
      .to raise_error(ArgumentError, /cyclic Studio schema inheritance/)
    expect { catalog.send(:split_key_value, 'missing-separator') }
      .to raise_error(ArgumentError, /invalid Studio schema field/)
  end

  it 'reconstructs data-source expressions with expression arguments and optional flags' do
    sources = Mxrb::RubyApp::PageDataSources
    variable = { 'kind' => 'widget', 'name' => 'Grid', 'sub_key' => 'row', 'use_all_pages' => true }
    association = {
      'kind' => 'association', 'entity' => 'App.Customer',
      'steps' => [{ 'association' => 'App.Order_Customer', 'entity' => 'App.Customer' }],
      'variable' => variable, 'force_full_objects' => false
    }
    expect(sources.send(:association_expression, association).source).to include('from: page_variable(')
    expect(sources.send(:association_expression,
                        association.merge('variable' => { 'kind' => 1 }))).to be_nil

    flow = {
      'kind' => 'microflow', 'name' => 'App.Load',
      'mappings' => [{ 'parameter' => 'Input', 'variable' => variable }],
      'settings_native' => { 'UseAllPages' => true }, 'force_full_objects' => true
    }
    expect(sources.send(:flow_expression, flow).source)
      .to include('microflow_source(', 'force_full_objects: true')
    expect(sources.send(:flow_expression, flow.merge('name' => ''))).to be_nil
  end
end
# rubocop:enable Metrics/BlockLength
