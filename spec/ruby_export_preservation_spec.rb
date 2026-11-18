# frozen_string_literal: true

require 'spec_helper'
require_relative 'fixtures/published_rest/project'

RSpec.describe 'Ruby application baseline preservation' do # rubocop:disable Metrics/BlockLength
  def roundtrip(source, directory)
    app = File.join(directory, 'ruby')
    Mxrb::Exporter.new(source, app, mode: :ruby).export!
    manifest = Mxrb::RubyApp::Manifest.load(app)
    FileUtils.rm_rf(File.dirname(manifest.absolute_path('runtime_mpr')))
    Mxrb::RubyApp.compile(app, File.join(directory, 'built', File.basename(source)))
  end

  it 'preserves documentation containing legacy response descriptions as well as structured response metadata' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source', 'Shop.mpr')
      PublishedRestFixture.build(source)
      documentation = "Lists items.\n\nResponses:\n- 200: Available items.\n- 404: Not found.\nAdditional prose."
      Mxrb.open(source, readonly: false) do |project|
        service = project.modules.find { _1.name == 'PublishedApi' }.infrastructure_documents
                         .find { _1[:type] == 'Rest$PublishedRestService' }
        raw = service.fetch(:doc)
        raw.fetch('Resources').last.fetch('Operations')[1]['Documentation'] = documentation
        project.mpr.update_unit(service.fetch(:id), raw)
      end
      built = roundtrip(source, root)
      expect(Mxrb.compare(source, built)).to be_identical
      metadata = JSON.parse(File.read(File.join(root, 'ruby/.mxrb/mendix/.mxrb/rest_metadata.json')))
      expect(metadata.fetch('operations').first.fetch('responses')).to include(
        include('status' => 200, 'description' => 'Available items.'),
        include('status' => 404, 'description' => 'Not found.')
      )
    end
  end

  it 'preserves distinct collection markers on individual indexes in the same domain model' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source', 'Shop.mpr')
      Mxrb.define(source) do
        mendix_version '10.24.18.103793'
        self.module(:App) do
          entity(:Item) do
            string :Name
            string :Code
            index :Name
            index :Code
          end
        end
      end
      Mxrb.open(source, readonly: false) do |project|
        mod = project.modules.find { _1.name == 'App' }
        unit = project.mpr.children_of(mod.id).find { _1['ContainmentName'] == 'DomainModel' }
        raw = project.mpr.parse_contents(unit)
        indexes = raw.fetch('Entities').last.fetch('Indexes')
        indexes[1]['Attributes'][0] = 2
        indexes[2]['Attributes'][0] = 3
        project.mpr.update_unit(unit.fetch('UnitID'), raw)
      end
      built = roundtrip(source, root)
      expect(Mxrb.compare(source, built)).to be_identical
    end
  end
end
