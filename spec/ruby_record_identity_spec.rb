# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/ruby_app/record_identity'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::RecordIdentity do
  after { Mxrb::RubyApp::Registry.reset! }

  def uuid(number) = format('00000000-0000-4000-8000-%012d', number)

  def baseline
    {
      'id' => uuid(1), 'name' => 'App.Item',
      'associations' => [{ 'id' => uuid(2), 'name' => 'App.Item_Owner' }],
      'access_rules' => [{ 'id' => uuid(3), 'roles' => ['App.User'], 'xpath' => '', 'members' => [
        { 'id' => uuid(4), 'name' => 'Name', 'kind' => 'attribute', 'reference' => 'App.Item.Name' }
      ] }],
      'indexes' => [{ 'id' => uuid(5), 'guid' => uuid(6), 'members' => [
        { 'id' => uuid(7), 'name' => 'Name', 'type' => 'Normal' }
      ] }],
      'lifecycle' => [{ 'id' => uuid(8), 'event' => 'before_commit' }],
      'validation_rules' => [{ 'id' => uuid(9), 'attribute' => 'Name', 'kind' => 'required',
                              'message_id' => uuid(10), 'rule_info_id' => uuid(11), 'translations' => [
                                { 'id' => uuid(12), 'language_code' => 'pt_BR', 'text' => 'Baseline' }
                              ] }],
      'generalization' => { 'id' => uuid(13), 'target' => 'App.Base' },
      'oql_view' => { 'source_id' => uuid(14), 'document_id' => uuid(15), 'query' => 'Baseline' }
    }
  end

  def resolver(previous = baseline)
    manifest = Mxrb::RubyApp::Manifest.new('/tmp/record-identities', 'mode' => 'ruby', 'modules' => [
      { 'models' => [previous], 'dtos' => [] }
    ])
    described_class.new(manifest)
  end

  def declarations
    {
      associations: [{ name: 'Item_Owner', target: 'App.Other' }],
      access_rules: [{ roles: ['App.User'], xpath: '', create: false, members: [
        { name: 'Name', kind: :attribute, rights: :ReadWrite }
      ] }],
      indexes: [{ include_offline: true, members: [{ name: 'Name', type: :Normal, ascending: false }] }],
      lifecycle: [{ event: :before_commit, handler: 'App.Changed', pass_event_object: false }],
      validation_rules: [{ attribute: 'Name', kind: :required, rule_info: {}, translations: [
        { language_code: 'pt_BR', text: 'Edited' }
      ] }],
      generalization: { target: 'App.OtherBase' }, oql_view: { query: 'Changed query' }
    }
  end

  it 'restores nested identities but never baseline values or source collection order' do
    declaration = declarations
    original = Marshal.load(Marshal.dump(declaration))
    result = resolver.resolve(id: uuid(1), name: 'App.Item', **declaration)
    expect(result[:associations].first).to eq(original[:associations].first.merge(id: uuid(2)))
    expect(result[:access_rules].first[:members].first).to include(id: uuid(4), rights: :ReadWrite)
    expect(result[:indexes].first).to include(id: uuid(5), guid: uuid(6), include_offline: true)
    expect(result[:indexes].first[:members].first).to include(id: uuid(7), ascending: false)
    expect(result[:lifecycle].first).to include(id: uuid(8), handler: 'App.Changed', pass_event_object: false)
    expect(result[:validation_rules].first).to include(id: uuid(9), message_id: uuid(10), rule_info_id: uuid(11), rule_info: {})
    expect(result[:validation_rules].first[:translations]).to eq([{ id: uuid(12), language_code: 'pt_BR', text: 'Edited' }])
    expect(result[:generalization]).to eq(id: uuid(13), target: 'App.OtherBase')
    expect(result[:oql_view]).to eq(source_id: uuid(14), document_id: uuid(15), query: 'Changed query')
    expect(declaration).to eq(original)
  end

  it 'rejects ambiguous association replacement and accepts explicit rename or remove-and-insert' do
    declaration = declarations
    declaration[:associations].first[:name] = 'Item_Account'
    expect { resolver.resolve(id: uuid(1), name: 'App.Item', **declaration) }
      .to raise_error(Mxrb::ValidationError, /renamed_from/)
    removed = resolver.resolve(id: uuid(1), name: 'App.Item', removed: { associations: ['Item_Owner'] }, **declaration)
    expect(removed[:associations].first[:id]).to be_nil
    declaration[:associations].first[:renamed_from] = 'Item_Owner'
    renamed = resolver.resolve(id: uuid(1), name: 'App.Item', **declaration)
    expect(renamed[:associations].first[:id]).to eq(uuid(2))
  end

  it 'requires an explicit rename when an anonymous collection key changes' do
    declaration = declarations
    declaration[:access_rules].first[:xpath] = '[Active = true()]'
    expect { resolver.resolve(id: uuid(1), name: 'App.Item', **declaration) }
      .to raise_error(Mxrb::ValidationError, /renamed_from/)
    declaration[:access_rules].first[:renamed_from] = [['App.User'], '']
    result = resolver.resolve(id: uuid(1), name: 'App.Item', **declaration)
    expect(result[:access_rules].first).to include(id: uuid(3), xpath: '[Active = true()]')
  end

  it 'retains explicit legacy IDs for duplicate ACL signatures and refuses to guess their ordering' do
    previous = baseline
    previous['access_rules'] << previous['access_rules'].first.merge('id' => uuid(30), 'members' => [])
    declaration = declarations
    expect { resolver(previous).resolve(id: uuid(1), name: 'App.Item', **declaration) }
      .to raise_error(Mxrb::ValidationError, /explicit legacy id/)
    declaration[:access_rules].first[:id] = uuid(3)
    declaration[:access_rules].unshift(roles: ['App.User'], xpath: '', id: uuid(30), members: [])
    result = resolver(previous).resolve(id: uuid(1), name: 'App.Item', **declaration)
    expect(result[:access_rules].map { _1[:id] }).to eq([uuid(30), uuid(3)])
  end

  it 'emits only legacy top-level IDs for duplicate ACLs and hides their member IDs' do
    rule = {
      'id' => uuid(3), 'roles' => ['App.User'], 'xpath' => '', 'documentation' => '',
      'create' => false, 'delete' => false, 'default_rights' => 'None', 'members' => [
        { 'id' => uuid(4), 'name' => 'Name', 'kind' => 'attribute',
          'reference' => 'App.Item.Name', 'rights' => 'ReadOnly' }
      ]
    }
    emitter = Mxrb::RubyApp::Exporter.allocate
    source = emitter.send(:entity_source, 'App', 'Item', 'App.Item', uuid(1), [], [],
                          dto: false, persistable: true,
                          access_rules: [rule, rule.merge('id' => uuid(30), 'members' => [])])
    expect(source.scan(Mxrb::PublicSourceAudit::UUID)).to eq([uuid(3), uuid(30)])
  end

  it 'uses explicit removal for index replacement and refuses conflicting private GUIDs' do
    declaration = declarations
    declaration[:indexes].first[:members].first[:name] = 'Code'
    expect { resolver.resolve(id: uuid(1), name: 'App.Item', **declaration) }
      .to raise_error(Mxrb::ValidationError, /renamed_from/)
    result = resolver.resolve(id: uuid(1), name: 'App.Item', removed: { indexes: [['Name']] }, **declaration)
    expect(result[:indexes].first[:id]).to be_nil
    expect(result[:indexes].first[:guid]).to be_nil
    expect(result[:indexes].first[:members].first[:id]).to be_nil
    declaration = declarations
    declaration[:indexes].first[:guid] = uuid(90)
    expect { resolver.resolve(id: uuid(1), name: 'App.Item', **declaration) }
      .to raise_error(Mxrb::ValidationError, /identity mismatch/)
  end

  it 'rejects missing baselines and conflicts while preserving nil versus empty collections' do
    previous = baseline.reject { |key, _| key == 'indexes' }
    expect { resolver(previous).resolve(id: uuid(1), name: 'App.Item', **declarations) }
      .to raise_error(Mxrb::ValidationError, /indexes identity baseline/)
    expect(resolver.resolve(id: uuid(1), name: 'App.Item', indexes: nil)).to eq(indexes: nil)
    expect(resolver.resolve(id: uuid(1), name: 'App.Item', indexes: [])).to eq(indexes: [])
    expect { resolver.resolve(id: uuid(1), name: 'App.Item', generalization: { id: uuid(90), target: 'App.Base' }) }
      .to raise_error(Mxrb::ValidationError, /identity mismatch/)
  end

  it 'does not partially assign the Record when later domain reconciliation fails' do
    record = Class.new(Mxrb::RubyApp::Record)
    record.mendix_name('App.Item', id: uuid(1))
    record.association('App.Other', name: 'Item_Owner')
    record.index(:Different)
    expect { record.resolve_record_identities!(resolver) }.to raise_error(Mxrb::ValidationError, /renamed_from/)
    expect(record.associations.first[:id]).to be_nil
    expect(record.indexes.first[:id]).to eq('')
  end

  def define_domain_fixture(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) do
        module_role :User
        entity(:Owner) { string :Name }
        entity(:Item) do
          string :Name
          association 'App.Owner', name: :Item_Owner, cardinality: :many_to_one
        end
        microflow(:Validate)
      end
    end
    writer = Mxrb::Writer.new(path, version: '11.12.1', modules: [])
    mpr = Mxrb::IO::MprFile.open(path)
    writer.synchronize_ruby_entity_structures!(mpr, module_name: 'App', entities: [{
      name: 'Item', indexes: [{ members: [{ name: 'Name', ascending: true }], include_offline: true }]
    }])
    writer.synchronize_ruby_entity_behaviors!(mpr, module_name: 'App', entities: [{
      name: 'Item', lifecycle: [{ event: :before_commit, handler: 'App.Validate' }],
      validation_rules: [{ attribute: 'Name', kind: :required, translations: [
        { language_code: 'pt_BR', text: 'Obrigatório' }, { language_code: 'en_US', text: 'Required' }
      ] }]
    }])
    writer.synchronize_ruby_entity_access!(mpr, module_name: 'App', entities: [{
      name: 'Item', access_rules: [{ roles: ['App.User'], create: true, members: [
        { name: 'Name', rights: :ReadOnly }, { name: 'Item_Owner', rights: :ReadWrite, kind: :association }
      ] }]
    }])
  ensure
    mpr&.close
  end

  def exported_item(root)
    Mxrb::RubyApp::Manifest.load(root).modules.flat_map { _1.fetch('models') }.find { _1['name'] == 'App.Item' }
  end

  it 'exports and recompiles identity-free domain Ruby with nested edits and stable private identities' do
    Dir.mktmpdir('mxrb-record-identity-') do |directory|
      source = File.join(directory, 'Source.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      define_domain_fixture(source)
      Mxrb::Exporter.new(source, output, mode: :ruby).export!
      before = exported_item(output)
      path = File.join(output, 'app', 'models', 'app', 'item.rb')
      ruby = File.read(path)
      expect(ruby).not_to match(/\bid:|\bguid:|\bmessage_id:|\brule_info_id:|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i)
      Mxrb::RubyApp.compile(output, rebuilt)
      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      expect(exported_item(restored)).to eq(before)

      changed = ruby.sub('ascending: true', 'ascending: false')
                    .sub('rights: :read_only', 'rights: :read_write')
                    .sub('translation "pt_BR", "Obrigatório"', 'translation "pt_BR", "Editado"')
      File.write(path, changed)
      Mxrb::RubyApp.compile(output, rebuilt)
      edited = File.join(directory, 'edited')
      Mxrb::Exporter.new(rebuilt, edited, mode: :ruby).export!
      expected = Marshal.load(Marshal.dump(before))
      expected['indexes'].first['members'].first['ascending'] = false
      expected['access_rules'].first['members'].first['rights'] = 'ReadWrite'
      expected['validation_rules'].first['translations'].first['text'] = 'Editado'
      expect(exported_item(edited)).to eq(expected)
      Mxrb::RubyApp.compile(edited, File.join(directory, 'Final.mpr'))
      final = File.join(directory, 'final')
      Mxrb::Exporter.new(File.join(directory, 'Final.mpr'), final, mode: :ruby).export!
      expect(exported_item(final)).to eq(expected)
    end
  end
end
# rubocop:enable Metrics/BlockLength
