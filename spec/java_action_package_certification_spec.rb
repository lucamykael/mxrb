# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Java action package certification' do
  it 'keeps the editable action document and Java source stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-java-package-') do |dir|
      source_root = File.join(dir, 'source')
      FileUtils.mkdir_p(source_root)
      current = File.join(source_root, 'Actions.mpr')
      build_source(current)
      java = write_java_source(source_root)
      baseline_ids = action_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(exported, 'Actions.mpr')
        Mxrb::Exporter.new(current, exported).export!

        declaration = Dir[File.join(exported, 'modules/Actions/application/actions/java/*.rb')]
                      .map { File.read(_1) }.join("\n")
        expect(declaration).to include('java_action :Ping', ':kind => :void')
        expect(declaration).not_to include('native_document', 'deep_structure:')
        expect(File.binread(File.join(exported, java))).to eq(File.binread(File.join(source_root, java)))

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
        java_action :Ping, parameters: [], return_type: { kind: :void },
                           documentation: 'Native Java action'
      end
    end
  end

  def write_java_source(root)
    relative = 'javasource/actions/actions/Ping.java'
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, Mxrb::Scaffold::Templates.java_action_source('Actions', 'Ping'))
    relative
  end

  def action_ids(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [document['Name'], unit['UnitID'].to_s] if document['$Type'] == 'JavaActions$JavaAction'
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
# rubocop:enable Metrics/BlockLength
