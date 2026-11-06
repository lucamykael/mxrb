# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::StoredFields do
  let(:stored) do
    [{ '$Type' => 'DomainModels$DomainModel', 'Entities' => [3, {
      '$ID' => 'e', '$Type' => 'DomainModels$EntityImpl', 'Name' => 'Item', 'Documentation' => ''
    }], 'Associations' => [3] }]
  end

  def fields(documents = stored, version: '7.5.0', template_root: Dir.mktmpdir)
    described_class.from(documents, version:, template_root:)
  end

  it 'removes the fields a type never stores, at any depth' do
    rebuilt = { '$Type' => 'DomainModels$DomainModel', 'Entities' => [3, {
      '$ID' => 'e', '$Type' => 'DomainModels$EntityImpl', 'Name' => 'Item', 'Documentation' => '',
      'IsRemote' => false, 'RemoteSource' => ''
    }], 'Associations' => [3], 'StorageFormat' => 'Column' }

    expect(fields.project!(rebuilt)).to be(true)
    expect(rebuilt).to eq(stored.first)
  end

  it 'stores a list under the marker the project always uses for that field' do
    pages = [{ '$Type' => 'Forms$Page', 'Variables' => [3] }, { '$Type' => 'Forms$Page', 'Variables' => [3] },
             { '$Type' => 'Forms$Snippet', 'Variables' => [3] }, { '$Type' => 'Forms$Snippet', 'Variables' => [2] }]
    page = { '$Type' => 'Forms$Page', 'Variables' => [2] }
    snippet = { '$Type' => 'Forms$Snippet', 'Variables' => [2, { '$Type' => 'Forms$PageVariable' }] }

    expect(fields(pages).project!(page)).to be(true)
    expect(page).to eq('$Type' => 'Forms$Page', 'Variables' => [3])
    expect(fields(pages).project!(snippet)).to be(false)
    expect(fields(pages).project!({ '$Type' => 'Forms$Page', 'Variables' => [3] })).to be(false)
  end

  it 'leaves types it has not seen and documents without a change alone' do
    unseen = { '$ID' => 'x', '$Type' => 'Microflows$Rule', 'ExportLevel' => 'Hidden' }
    same = Marshal.load(Marshal.dump(stored.first))

    expect(fields.project!(unseen)).to be(false)
    expect(unseen).to include('ExportLevel' => 'Hidden')
    expect(fields.project!(same)).to be(false)
    expect(fields.project!([1, 'text', nil])).to be(false)
  end

  it 'also learns the fields of the Studio Pro template of the version' do
    Dir.mktmpdir do |root|
      template = { '$Type' => 'Security$ProjectSecurity', 'StrictMode' => false }
      units = [{ 'contents' => Base64.strict_encode64(Mxrb::IO::BsonCodec.serialize(template)) }]
      File.write(File.join(root, '7.5.0.json'), JSON.generate('units' => units))
      rebuilt = { '$Type' => 'Security$ProjectSecurity', 'StrictMode' => true, 'StrictPageUrlCheck' => true }

      fields(template_root: root).project!(rebuilt)
      expect(rebuilt).to eq('$Type' => 'Security$ProjectSecurity', 'StrictMode' => true)
    end
  end

  it 'does not apply to the schemas the writer follows' do
    expect(%w[11.12.1 10.24.0.73019].map { described_class.applies_to?(_1) }).to eq([false, false])
    expect(%w[5.21.4 7.17.0-rc5 9.6.1.29396 11.6.4].map { described_class.applies_to?(_1) }).to all(be(true))
  end

  describe 'a project.rb rebuild of the same version' do
    def rebuild(version)
      Dir.mktmpdir('mxrb-stored-fields-') do |dir|
        source = File.join(dir, 'Source.mpr')
        Mxrb.define(source) do
          mendix_version version
          self.module(:App) { entity(:Item) { string :Name } }
        end
        strip_entity_field(source, 'IsRemote')
        entity_fields(export_and_generate(source, File.join(dir, 'ruby'), File.join(dir, 'rebuilt', 'Source.mpr')))
      end
    end

    def export_and_generate(source, exported, rebuilt)
      Mxrb::Exporter.new(source, exported).export!
      FileUtils.mkdir_p(File.dirname(rebuilt))
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = rebuilt
      load File.join(exported, 'project.rb')
      rebuilt
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
    end

    def strip_entity_field(path, field)
      mpr = Mxrb::IO::MprFile.open(path, apply_studio_compatibility: false)
      mpr.all_units.each do |unit|
        document = mpr.parse_contents(unit)
        next unless document['$Type'] == 'DomainModels$DomainModel'

        document['Entities'].drop(1).each { _1.delete(field) }
        mpr.update_unit(unit.fetch('UnitID'), document)
      end
    ensure
      mpr&.close
    end

    def entity_fields(path)
      Mxrb.open(path) do |project|
        unit = project.all_units.find { project.parse_bson(_1)['$Type'] == 'DomainModels$DomainModel' }
        project.parse_bson(unit)['Entities'].drop(1).first.keys
      end
    end

    it 'writes only the fields its project stores' do
      expect(rebuild('9.6.1.29396')).not_to include('IsRemote')
    end

    it 'keeps the fields of a schema the writer follows' do
      expect(rebuild('11.12.1')).to include('IsRemote')
    end
  end
end
# rubocop:enable Metrics/BlockLength
