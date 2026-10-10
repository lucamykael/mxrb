# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby app nanoflow client expressions' do
  let(:fixture) { 'spec/fixtures/native_nanoflow_expressions' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  def export_fixture(directory)
    source = File.join(directory, 'Expressions.mpr')
    previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
    ENV['MXRB_OUTPUT_PATH'] = source
    load File.join(fixture, 'project.rb')
    ENV['MXRB_OUTPUT_PATH'] = previous
    File.join(directory, 'ruby').tap { Mxrb::Exporter.new(source, _1, mode: :ruby).export! }
  ensure
    Mxrb::RubyApp::Registry.reset!
  end

  def exported_nanoflows(directory)
    generated = File.join(export_fixture(directory), 'frontend', 'src', 'generated', 'nanoflows', 'probe')
    cases.to_h do |item|
      [item['name'], File.read(File.join(generated, "case_#{item['name'].gsub(/(?<!^)([A-Z])/, '_\\1').downcase}.ts"))]
    end
  end

  it 'exports every natively verified expression case to a client nanoflow' do
    expect(cases.map { _1.fetch('expected') }).to all(be_a(String))
    expect(cases.count { _1['expected'] == '<no result>' }).to eq(2)
    sources = Dir.mktmpdir { exported_nanoflows(_1) }
    expect(sources.values.join).not_to include('runtime.unsupported(')
    expect(sources.fetch('Path')).to include('$row/Probe.Row_Item/Probe.Item/Name')
    expect(sources.fetch('Tokens')).to include('[%BeginOfCurrentDay%]')
    expect(sources.fetch('Caption')).to include('getCaption($row/Kind)')
  end
end
# rubocop:enable Metrics/BlockLength
