# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby app nanoflow client functions' do
  let(:fixture) { 'spec/fixtures/native_nanoflow_functions' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  def export_fixture(directory)
    source = File.join(directory, 'Functions.mpr')
    previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
    ENV['MXRB_OUTPUT_PATH'] = source
    load File.join(fixture, 'project.rb')
    ENV['MXRB_OUTPUT_PATH'] = previous
    File.join(directory, 'ruby').tap { Mxrb::Exporter.new(source, _1, mode: :ruby).export! }
  ensure
    Mxrb::RubyApp::Registry.reset!
  end

  it 'exports every natively verified function case to a client nanoflow with date-fns' do
    expect(cases.map { _1.fetch('expected') }).to all(be_a(String))
    expect(cases.count { _1['expected'] == '<no result>' }).to eq(9)
    Dir.mktmpdir do |directory|
      app = export_fixture(directory)
      generated = File.join(app, 'frontend', 'src', 'generated', 'nanoflows', 'probe')
      sources = cases.to_h do |item|
        file = "case_#{item['name'].gsub(/(?<!^)([A-Z])/, '_\\1').downcase}.ts"
        [item['name'], File.read(File.join(generated, file))]
      end
      expect(sources.values.join).not_to include('runtime.unsupported(')
      expect(sources.fetch('FormatPattern'))
        .to include("formatDateTime(dateTime(2024, 3, 5, 14, 7, 9), 'yyyy-MM-dd HH:mm:ss')")
      expect(sources.fetch('WeekToken')).to include('[%BeginOfCurrentWeek%]')
      package = JSON.parse(File.read(File.join(app, 'frontend', 'package.json')))
      lock = JSON.parse(File.read(File.join(app, 'frontend', 'package-lock.json')))
      expect(package.dig('dependencies', 'date-fns')).to eq('^4.1.0')
      expect(lock.dig('packages', 'node_modules/date-fns', 'version')).to start_with('4.')
    end
  end
end
# rubocop:enable Metrics/BlockLength
