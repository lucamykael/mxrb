# frozen_string_literal: true

require 'spec_helper'
require_relative 'fixtures/legacy_oql_view/project'

RSpec.describe 'Mendix 10 OQL view storage' do # rubocop:disable Metrics/BlockLength
  def oql_query = LegacyOqlViewFixture::QUERY

  def fixture(path, version: '10.24.18.103793')
    LegacyOqlViewFixture.build(path, version:)
  end

  def change_source(path) # rubocop:disable Metrics/AbcSize
    Mxrb.open(path, readonly: false) do |project|
      mod = project.modules.find { _1.name == 'App' }
      unit = project.mpr.unit(mod.domain_model.id)
      raw = project.mpr.parse_contents(unit)
      source = raw.fetch('Entities').drop(1).find { _1['Name'] == 'ItemView' }.fetch('Source')
      yield source, project, mod
      project.mpr.update_unit(unit.fetch('UnitID'), raw)
    end
  end

  it 'writes inline queries for Mendix 10 and named documents for Mendix 11' do
    Dir.mktmpdir do |root|
      %w[10.24.18.103793 11.12.1].each do |version|
        path = File.join(root, version, 'App.mpr')
        fixture(path, version:)
        change_source(path) do |source, _project, _mod|
          expect(source['SourceDocument']).to eq('App.ItemView')
          if version.start_with?('10.')
            expect(source['Oql']).to eq(oql_query)
          else
            expect(source).not_to have_key('Oql')
          end
        end
      end
    end
  end

  it 'preserves a valid inline query through both Ruby export modes' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source/App.mpr')
      fixture(source)
      change_source(source) { |native, _project, _mod| native['Oql'] = oql_query }
      %i[mendix ruby].each do |mode|
        app = File.join(root, mode.to_s)
        Mxrb::Exporter.new(source, app, mode:).export!
        built = File.join(root, "built-#{mode}/App.mpr")
        if mode == :ruby
          manifest = Mxrb::RubyApp::Manifest.load(app)
          FileUtils.rm_rf(File.dirname(manifest.absolute_path('runtime_mpr')))
          Mxrb::RubyApp.compile(app, built)
        else
          previous = ENV['MXRB_OUTPUT_PATH']
          begin
            ENV['MXRB_OUTPUT_PATH'] = built
            load File.join(app, 'project.rb')
          ensure
            previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
          end
        end
        expect(Mxrb.compare(source, built)).to be_identical
      end
    end
  end

  it 'applies a public Ruby query edit to both the native inline query and its document' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source/App.mpr')
      fixture(source)
      change_source(source) { |native, _project, _mod| native['Oql'] = oql_query }
      FileUtils.cp_r(File.dirname(source), File.join(root, 'expected'))
      expected = File.join(root, 'expected/App.mpr')
      query = 'SELECT Code AS Name FROM App.Item'
      change_source(expected) do |native, project, mod|
        native['Oql'] = query
        document = mod.oql_view_documents.first
        project.mpr.update_unit(document.fetch(:id), document.fetch(:doc).merge('Oql' => query))
      end
      app = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, app, mode: :ruby).export!
      path = File.join(app, 'app/models/app/item_view.rb')
      code = File.read(path)
      expect(code.scan(oql_query).length).to eq(1)
      File.write(path, code.sub(oql_query, query))
      FileUtils.rm_rf(File.dirname(Mxrb::RubyApp::Manifest.load(app).absolute_path('runtime_mpr')))
      built = Mxrb::RubyApp.compile(app, File.join(root, 'built/App.mpr'))
      expect(Mxrb.compare(expected, built)).to be_identical
    end
  end

  it 'retains an existing inline query on a source-only update without inventing a missing query' do
    Dir.mktmpdir do |root|
      [true, false].each do |present|
        path = File.join(root, present.to_s, 'App.mpr')
        fixture(path)
        expected = nil
        change_source(path) do |source, _project, _mod|
          present ? source['Oql'] = oql_query : source.delete('Oql')
          expected = Marshal.load(Marshal.dump(source))
        end
        Mxrb.open(path, readonly: false) do |project|
          writer = Mxrb::Writer.new(path, version: project.mendix_version, modules: [])
          writer.synchronize_ruby_entity_structures!(
            project.mpr, module_name: 'App', entities: [{ name: 'ItemView', oql_view: { source: 'App.ItemView' } }]
          )
        end
        Mxrb.open(path) do |project|
          view = project.modules.find { _1.name == 'App' }.entities.find { _1.name == 'ItemView' }
          expect(view.source).to eq(expected)
        end
      end
    end
  end
end
