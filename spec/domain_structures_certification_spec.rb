# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Domain structure certification' do
  it 'keeps every valid index kind, system member, and generalization identity stable' do
    Dir.mktmpdir('mxrb-domain-structures-') do |dir|
      current = File.join(dir, 'DomainStructures.mpr')
      build_source(current)
      baseline = structure_snapshot(current)

      ruby_app = File.join(dir, 'ruby-app')
      ruby_rebuilt = File.join(dir, 'ruby-rebuilt.mpr')
      Mxrb::Exporter.new(current, ruby_app, mode: :ruby).export!
      ruby_source = File.read(File.join(ruby_app, 'app/models/app/audit.rb'))
      expect(ruby_source).to include(
        'type: :created_date', 'type: :changed_date'
      )
      Mxrb::RubyApp.compile(ruby_app, ruby_rebuilt)
      expect(Mxrb.compare(current, ruby_rebuilt)).to be_identical
      expect(structure_snapshot(ruby_rebuilt)).to eq(baseline)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = File.read(File.join(exported, 'modules/App/domain/entities/audit.rb'))
        expect(source).to include(
          'system_members owner: true, created_date: true, changed_date: true, changed_by: true',
          ':type => :CreatedDate', ':type => :ChangedDate', 'include_offline: true'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(structure_snapshot(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  it 'rejects enum values that Studio Pro stores but cannot use in an entity index' do
    %i[Association Owner ChangedBy].each do |type|
      expect do
        Mxrb::RubyApp::IndexBuilder.new.member(type, type:)
      end.to raise_error(ArgumentError, /unsupported index member type/)
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        page(:Home) { title 'Domain structures' }
        entity(:Account) { string :Name }
        entity(:Audit) do
          system_members owner: true, created_date: true, changed_date: true, changed_by: true
          string :Code
          index :Code, include_offline: true, ascending: false
          %i[CreatedDate ChangedDate].each do |system_member|
            index system_member, members: [
              { name: system_member, type: system_member, ascending: false }
            ]
          end
        end
        entity(:SpecialAudit) { generalizes 'App.Audit' }
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Domain structures'
      end
    end
  end

  def structure_snapshot(path)
    Mxrb.open(path) do |project|
      audit = project.entities.find { _1.name == 'Audit' }
      special = project.entities.find { _1.name == 'SpecialAudit' }
      indexes = audit.indexes.map do |index|
        members = Mxrb::IO::BsonCodec.parse_array(index.fetch('Attributes'))[:items]
        [Mxrb::IO::BsonCodec.extract_id(index.fetch('$ID')),
         Mxrb::IO::BsonCodec.extract_id(index.fetch('GUID')),
         members.map do |member|
           [Mxrb::IO::BsonCodec.extract_id(member.fetch('$ID')), member.fetch('Type'),
            Mxrb::IO::BsonCodec.extract_id(member.fetch('AttributePointer')),
            Mxrb::IO::BsonCodec.extract_id(member.fetch('AssociationPointer'))]
         end]
      end
      {
        system_members: audit.system_members,
        indexes: indexes.sort_by(&:first),
        generalization: [special.generalization_target,
                         Mxrb::IO::BsonCodec.extract_id(special.generalization.fetch('$ID'))]
      }
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
