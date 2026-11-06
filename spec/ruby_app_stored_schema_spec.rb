# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The Ruby application projects onto the schema of its version only what its sources
# wrote, and keeps a unit they left alone as stored.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::Synchronizer do
  def build(path, version)
    Mxrb.define(path) do
      mendix_version version
      self.module(:App) do
        enumeration(:Kept) { value :One }
        enumeration(:Edited) { value :One }
      end
    end
  end

  def enumerations(mpr)
    mpr.all_units.filter_map do |unit|
      document = mpr.parse_contents(unit)
      [document['Name'], [unit.fetch('UnitID'), document]] if document['$Type'] == 'Enumerations$Enumeration'
    end.to_h
  end

  # Gives each value a field the 9.6.1 schema does not have, as a generator might.
  def store_value_field(mpr)
    enumerations(mpr).each_value do |id, document|
      document['Values'].drop(1).each { _1['ExportLevel'] = 'Hidden' }
      mpr.write_unit_as_stored(id, document)
    end
  end

  def finalize(version)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'App.mpr')
      build(path, version)
      project = Mxrb::Model::Project.open(path, readonly: false)
      synchronize_one_edit(described_class.new(dir, path, manifest: nil), project)
      enumerations(project.mpr).transform_values { _1.last.dig('Values', 1).key?('ExportLevel') }
    ensure
      project&.close
    end
  end

  # Snapshots the stored units, edits one enumeration as synchronization would, and
  # finalizes the schema.
  def synchronize_one_edit(synchronizer, project)
    store_value_field(project.mpr)
    synchronizer.instance_variable_set(:@stored_units, synchronizer.send(:stored_units, project.mpr))
    id, edited = enumerations(project.mpr).fetch('Edited')
    project.mpr.write_unit_as_stored(id, edited.merge('Documentation' => 'Edited'))
    synchronizer.send(:finalize_studio_schema!, project)
  end

  it 'projects only what synchronization changed onto the schema of the version' do
    expect(finalize('9.6.1.29396')).to eq('Kept' => true, 'Edited' => false)
  end

  it 'keeps every stored field where the version has no schema projection' do
    expect(finalize('7.5.0')).to eq('Kept' => true, 'Edited' => true)
  end

  it 'counts a rewrite whose only change is the schema projection as no change' do
    synchronizer = described_class.new('/tmp', '/tmp/App.mpr', manifest: nil)
    stored = { '$Type' => 'Enumerations$EnumerationValue', 'ExportLevel' => 'Hidden' }
    synchronizer.instance_variable_set(:@stored_units, { 'a' => stored })
    compatibility = Mxrb::StudioCompatibility.new('9.6.1.29396')

    expect(synchronizer.send(:schema_only_change?, compatibility, 'a', { '$Type' => 'Enumerations$EnumerationValue' }))
      .to be(true)
    expect(synchronizer.send(:schema_only_change?, compatibility, 'a', stored.merge('Other' => 1))).to be(false)
    expect(synchronizer.send(:schema_only_change?, compatibility, 'new', stored)).to be(false)
  end

  it 'gives a new Ruby enumeration the defaults and keeps the fields a stored one has' do
    writer = Mxrb::Writer.allocate
    declaration = { name: 'Color', values: [] }

    expect(writer.send(:ruby_enumeration_doc, declaration)).to include('Excluded' => false, 'ExportLevel' => 'Hidden')
    expect(writer.send(:ruby_enumeration_doc, declaration, previous: { 'Values' => [3] }))
      .not_to include('Excluded', 'ExportLevel')
  end
end
# rubocop:enable Metrics/BlockLength
