# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'JavaScript action package certification' do
  it 'keeps the editable action document and JavaScript source stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-javascript-package-') do |dir|
      source_root = File.join(dir, 'source')
      FileUtils.mkdir_p(source_root)
      current = File.join(source_root, 'Actions.mpr')
      build_source(current)
      javascript = write_javascript_source(source_root)
      baseline_ids = action_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(exported, 'Actions.mpr')
        Mxrb::Exporter.new(current, exported).export!

        declaration = Dir[
          File.join(exported, 'modules/Actions/application/actions/javascript/*.rb')
        ].map { File.read(_1) }.join("\n")
        expect(declaration).to include(
          'javascript_action :Notify', ':kind => :void', 'platform: "Web"'
        )
        expect(declaration).not_to include('native_document', 'deep_structure:')
        expect(File.binread(File.join(exported, javascript))).to eq(
          File.binread(File.join(source_root, javascript))
        )

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(action_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Actions do
        page(:Home) { title 'JavaScript actions' }
        javascript_action :Notify, parameters: [], return_type: { kind: :void },
                                   platform: :Web, documentation: 'Native JavaScript action'
      end
      navigation do
        profile :Responsive, home_page: 'Actions.Home', app_title: 'JavaScript actions'
      end
    end
  end

  def write_javascript_source(root)
    relative = 'javascriptsource/actions/actions/Notify.js'
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, Mxrb::Scaffold::Templates.javascript_action_source('Actions', 'Notify'))
    relative
  end

  def action_ids(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [document['Name'], unit['UnitID'].to_s] if
          document['$Type'] == 'JavaScriptActions$JavaScriptAction'
      end
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
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
