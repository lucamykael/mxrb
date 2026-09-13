# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby application access member DSL' do
  it 'supports typed member blocks on records and DTOs alongside legacy members' do
    [Mxrb::RubyApp::Record, Mxrb::RubyApp::DTO].each do |base|
      implementation = Class.new(base)
      legacy = [{ name: 'Legacy', rights: :ReadOnly }]
      implementation.access_rule('Catalog.User', default_rights: :read_only, members: legacy) do |rule|
        rule.member 'Name', rights: :read_write, id: 'member-id', reference: 'Catalog.Base.Name'
        rule.member 'Child_Parent', rights: :none, kind: :association
      end

      rule = implementation.access_rules.first
      expect(rule.fetch(:default_rights)).to eq(:ReadOnly)
      expect(rule.fetch(:members).map { _1.fetch(:name) }).to eq(%w[Legacy Name Child_Parent])
      expect(rule.fetch(:members)[1]).to include(id: 'member-id', reference: 'Catalog.Base.Name', rights: :ReadWrite)
      expect(rule.fetch(:members).last).to include(kind: :association, rights: :None)
    end
  end

  it 'rejects malformed member blocks without installing a partial access rule' do
    implementation = Class.new(Mxrb::RubyApp::Record)
    expect do
      implementation.access_rule('Catalog.User') { member 'Name', rights: :unknown }
    end.to raise_error(ArgumentError, /access rights/)
    expect do
      implementation.access_rule('Catalog.User') { member 'Name', rights: :read_only, kind: :unknown }
    end.to raise_error(ArgumentError, /attribute or association/)
    expect do
      implementation.access_rule('Catalog.User') { member '', rights: :read_only }
    end.to raise_error(ArgumentError, /requires a name/)
    expect(implementation.access_rules).to be_nil
  end

  it 'exports member declarations and preserves ACL identities, references and order when editing rights' do
    Dir.mktmpdir('mxrb-access-member-dsl-') do |dir|
      original = File.join(dir, 'Original.mpr')
      target = File.join(dir, 'Rebuilt.mpr')
      exported = File.join(dir, 'ruby')
      define_source(original)
      before = access_documents(original)
      Mxrb::Exporter.new(original, exported, mode: :ruby).export!(parallel: false)
      child_path = File.join(exported, 'app', 'models', 'catalog', 'child.rb')
      child = File.read(child_path)
      dto = File.read(File.join(exported, 'app', 'dtos', 'catalog', 'search_dto.rb'))
      expect(child).to include('member "Name",', 'reference: "Catalog.Base.Name"', 'rights: :read_only')
      expect(dto).to include('member "Query",')
      expect(child).not_to include('members: [', '{ id:')
      expect(dto).not_to include('members: [', '{ id:')

      FileUtils.cp(original, target)
      Mxrb::RubyApp::Synchronizer.new(exported, target).synchronize!
      expect(access_documents(target)).to eq(before)

      File.write(child_path, child.sub('rights: :read_only', 'rights: :read_write'))
      Mxrb::RubyApp::Synchronizer.new(exported, target).synchronize!
      changed = access_documents(target)
      expected = Marshal.load(Marshal.dump(before))
      expected.fetch('Child')[1].fetch('MemberAccesses')[1]['AccessRights'] = 'ReadWrite'
      expect(changed).to eq(expected)
    end
  end

  def define_source(path) # rubocop:disable Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Catalog do
        module_role :User
        entity(:Base) { string :Name }
        entity :Child do
          generalizes 'Catalog.Base'
          string :Code
          access_rule 'Catalog.User', default_rights: :None, members: [
            { name: 'Name', reference: 'Catalog.Base.Name', rights: :ReadOnly, kind: :attribute },
            { name: 'Code', reference: 'Catalog.Child.Code', rights: :ReadWrite, kind: :attribute }
          ]
        end
        entity :Search do
          non_persistent!
          string :Query
          access_rule 'Catalog.User', members: [{ name: 'Query', rights: :ReadOnly, kind: :attribute }]
        end
      end
    end
  end

  def access_documents(path)
    Mxrb.open(path) do |project|
      project.all_units.flat_map do |unit|
        document = project.parse_bson(unit)
        next [] unless document['$Type'] == 'DomainModels$DomainModel'

        Mxrb::IO::BsonCodec.parse_array(document['Entities']).fetch(:items).map do |entity|
          [entity.fetch('Name'), entity.fetch('AccessRules')]
        end
      end.to_h
    end
  end
end
# rubocop:enable Metrics/BlockLength
