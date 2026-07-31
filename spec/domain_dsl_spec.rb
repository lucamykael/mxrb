# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'complete domain DSL' do
  def build(dir, &block)
    path = File.join(dir, 'domain.mpr')
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Clinic, &block)
    end
    path
  end

  it 'writes attribute options, validation rules, generalization, and system members' do
    Dir.mktmpdir do |dir|
      path = build(dir) do
        entity :Account do
          generalizes 'System.User'
          string :DisplayName, length: 120, required: true, unique: true
          datetime :Birthday, localize_date: false
        end
        entity :AuditRecord do
          system_members owner: true, created_date: true, changed_date: true, changed_by: true
        end
      end

      Mxrb.open(path) do |project|
        account, audit = project.modules.first.entities
        display_name, birthday = account.attributes
        expect(display_name).to have_attributes(length: 120, required: true, unique: true)
        expect(birthday.localize_date).to be(false)
        expect(account.generalization_target).to eq('System.User')
        expect(audit.system_members).to eq(
          owner: true, created_date: true, changed_date: true, changed_by: true
        )
      end
      expect(Mxrb.validate(path)).to be_valid
    end
  end

  it 'writes simple and compound indexes in declared order' do
    Dir.mktmpdir do |dir|
      path = build(dir) do
        entity :Animal do
          string :Name
          datetime :BirthDate
          index :Name
          index :Name, :BirthDate, ascending: [true, false], include_offline: true
        end
      end

      entity = Mxrb.open(path) { _1.modules.first.entities.first }
      expect(entity.indexes.size).to eq(2)
      compound = entity.indexes.last
      members = Mxrb::IO::BsonCodec.parse_array(
        compound['attributes'] || compound['Attributes'] || compound['IndexedAttributes']
      )[:items]
      expect(members.map { (_1['attribute'] || _1['Attribute']).split('.').last })
        .to eq(%w[Name BirthDate])
      expect(members.map { _1['ascending'].nil? ? _1['Ascending'] : _1['ascending'] })
        .to eq([true, false])
      expect(compound['includeInOffline'] || compound['IncludeInOffline']).to be(true)

      Mxrb::IO::MprFile.open(path) do |mpr|
        domain = mpr.parse_contents(mpr.units_by_containment('DomainModel').first)
        stored = Mxrb::IO::BsonCodec.parse_array(domain['Entities'])[:items].first
        index = Mxrb::IO::BsonCodec.parse_array(stored['Indexes'])[:items].last
        indexed = Mxrb::IO::BsonCodec.parse_array(index['Attributes'])
        expect(index['GUID']).to eq(index['$ID'])
        expect(indexed[:marker]).to eq(2)
        expect(indexed[:items]).to all(include('AttributePointer', 'AssociationPointer'))
        expect(indexed[:items]).not_to include(include('Attribute'))
      end
    end
  end

  it 'supports explicit cardinalities, documentation, and delete behavior' do
    Dir.mktmpdir do |dir|
      path = build(dir) do
        entity :Owner do
          association 'Clinic.Profile', name: 'Owner_Profile', cardinality: :one_to_one,
                                        documentation: 'Exclusive profile',
                                        parent_delete: :DeleteMeAndReferences,
                                        child_delete: :DeleteMeButKeepReferences
        end
        entity :Profile
        entity :Tag
        entity :Animal do
          association 'Clinic.Owner', name: 'Animal_Owner', cardinality: :many_to_one
          association 'Clinic.Tag', name: 'Animal_Tags', cardinality: :many_to_many
        end
      end

      associations = Mxrb.open(path) { _1.modules.first.associations }
      one = associations.find { _1.name == 'Owner_Profile' }
      expect(one).to have_attributes(
        association_type: :Reference, owner: :Both,
        documentation: 'Exclusive profile',
        parent_delete_behavior: :DeleteMeAndReferences,
        child_delete_behavior: :DeleteMeButKeepReferences
      )
      expect(associations.find { _1.name == 'Animal_Tags' }.association_type).to eq(:ReferenceSet)
    end
  end

  it 'exports the advanced declarations and rebuilds them' do
    Dir.mktmpdir do |dir|
      source = build(dir) do
        entity :Animal do
          string :Name, length: 80, required: true
          index :Name
        end
      end
      exported = File.join(dir, 'exported')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      Mxrb::Exporter.new(source, exported).export!
      entity_source = Dir[File.join(exported, '**', 'animal.rb')].fetch(0)
      expect(File.read(entity_source)).to include(
        'length: 80', 'required: true', 'index :Name'
      )

      begin
        ENV['MXRB_OUTPUT_PATH'] = rebuilt
        load File.join(exported, 'project.rb')
      ensure
        ENV.delete('MXRB_OUTPUT_PATH')
      end
      animal = Mxrb.open(rebuilt) { _1.modules.first.entities.first }
      expect(animal.attributes.first).to have_attributes(length: 80, required: true)
      expect(animal.indexes.size).to eq(1)
    end
  end

  it 'rejects invalid cardinalities and index declarations' do
    builder = Mxrb::Dsl::EntityBuilder.new(:Animal)
    expect { builder.association('Clinic.Owner', cardinality: :invalid) }
      .to raise_error(ArgumentError, /cardinality/)
    expect { builder.index }.to raise_error(ArgumentError, /at least one/)
    expect { builder.index(:Name, :Status, ascending: [true, false, true]) }
      .to raise_error(ArgumentError, /ascending/)
  end

  it 'normalizes both legacy and pointer-based index members defensively' do
    attribute = Struct.new(:id, :name).new('attribute-id', 'Name')
    indexes = [{ 'Attributes' => [2,
                                  { 'Attribute' => 'Clinic.Animal.Legacy' },
                                  { 'AttributePointer' => 'attribute-id' },
                                  { 'AttributePointer' => 'missing-id' }] }]
    normalized = Mxrb::Model::Entity.send(
      :normalize_indexes, indexes, [attribute], 'Clinic.Animal'
    )
    members = Mxrb::IO::BsonCodec.parse_array(normalized.first['Attributes'])[:items]
    expect(members.map { _1['Attribute'] }).to eq(
      ['Clinic.Animal.Legacy', 'Clinic.Animal.Name', nil]
    )
  end

  it 'writes native layouts and fully qualified create-object members' do
    Dir.mktmpdir do |dir|
      path = build(dir) do
        entity(:Animal) { string :Name }
        layout :ApplicationLayout
        page(:Overview) { layout 'Clinic.ApplicationLayout' }
        microflow(:CreateAnimal) do
          create_object 'Clinic.Animal', as: :Animal, set: { Name: "'Max'" }
        end
      end

      Mxrb.open(path) do |project|
        layout = project.semantic_index.find('Clinic.ApplicationLayout')
        expect(layout.kind).to eq(:layout)
        expect(project.analyze.errors).to be_empty
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
