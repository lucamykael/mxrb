# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Mxrb.compare on every stored unit' do
  def project(path, version)
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version version
      self.module(:App) { entity(:Item) { string :Name } }
    end
    path
  end

  def edit_domain_model(path)
    mpr = Mxrb::IO::MprFile.open(path, apply_studio_compatibility: false)
    unit = mpr.all_units.find { mpr.parse_contents(_1)['$Type'] == 'DomainModels$DomainModel' }
    document = mpr.parse_contents(unit)
    yield document
    mpr.update_unit(unit.fetch('UnitID'), document)
    path
  ensure
    mpr&.close
  end

  def differences(version: '11.12.1', &change)
    Dir.mktmpdir do |directory|
      left = project(File.join(directory, 'left', 'App.mpr'), version)
      right = edit_domain_model(project(File.join(directory, 'right', 'App.mpr'), version), &change)
      Mxrb.compare(left, right).differences
    end
  end

  it 'reports a stored field that no summary reads, under the names of its containers' do
    expect(differences { _1['Documentation'] = 'Changed' })
      .to contain_exactly(a_string_including('documents.App DomainModels$DomainModel.Documentation', 'Changed'))
  end

  it 'pairs stored elements by name' do
    changes = differences { _1['Entities'][1]['Location'] = '10;20' }

    expect(changes).to contain_exactly(a_string_including('Entities.Item.Location'))
  end

  it 'reports an empty field only where a rebuild writes exactly the stored fields' do
    expect(differences(version: '9.6.1.29396') { _1['Extra'] = '' }).to contain_exactly(a_string_including('Extra'))
    expect(differences(version: '11.12.1') { _1['Extra'] = '' }).to be_empty
  end

  it 'treats an unedited project as identical' do
    expect(differences { nil }).to be_empty
  end

  describe 'stored lists and labels' do
    let(:comparator) { Mxrb::Compare::Comparator.new('left', 'right') }

    it 'compares the marker of a list and pairs its elements by name' do
      expect(comparator.send(:diff_values, { 'a' => [3] }, { 'a' => [2] })).to contain_exactly(
        having_attributes(path: ['a', 0], before: 3, after: 2)
      )
      left = [3, { 'Name' => 'A', 'X' => 1 }, { 'Name' => 'B', 'X' => 1 }]
      right = [2, { 'Name' => 'B', 'X' => 1 }, { 'Name' => 'A', 'X' => 2 }]
      expect(comparator.send(:diff_values, left, right).map(&:path)).to contain_exactly([0], %w[A X])
    end

    it 'numbers documents that share a label by their unit' do
      units = {
        'root' => { 'UnitID' => 'root', 'ContainerID' => 'root', 'doc' => { '$Type' => 'Projects$Project' } },
        'module' => { 'UnitID' => 'module', 'ContainerID' => 'root', 'doc' => { 'Name' => 'App' } },
        'b' => { 'UnitID' => 'b', 'ContainerID' => 'module', 'doc' => { '$Type' => 'Texts$Text', 'V' => 2 } },
        'a' => { 'UnitID' => 'a', 'ContainerID' => 'module', 'doc' => { '$Type' => 'Texts$Text', 'V' => 1 } }
      }
      project = double(all_units: units.values)
      allow(project).to receive(:parse_bson) { _1.fetch('doc') }

      expect(comparator.send(:document_summary, project).transform_values { _1['V'] }).to eq(
        'App' => nil, 'App Texts$Text 1' => 1, 'App Texts$Text 2' => 2
      )
    end
  end
end
# rubocop:enable Metrics/BlockLength
