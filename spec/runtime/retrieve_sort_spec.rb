# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::SortOrder do
  let(:fixture) { 'spec/fixtures/native_retrieve_sort' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'Sort.mpr')
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  it 'orders database retrieves exactly as the native Mendix 11.12.1 Runtime' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h do |line|
      name, values = line.delete_prefix('ORACLE ').split('=', 2)
      [name, values.delete_suffix(',').split(',')]
    end
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'orders server-side data grids with the same rules' do
    rows = JSON.parse(File.read(File.join(fixture, 'rows.json'))).each_with_index.map do |row, index|
      members = row.to_h { |key, value| [key, %w[Amount Other].include?(key) && value ? BigDecimal(value) : value] }
      Mxrb::Runtime::Native::ObjectValue.new(entity: 'Views.Location', id: index.to_s, members:)
    end
    app = Mxrb::RubyApp::Application.allocate
    cases.each do |item|
      sortings = item.fetch('sort').map do |attribute, direction|
        { attribute: "Views.Location.#{attribute}", direction: }
      end
      ordered = app.send(:grid_sort_records, rows, sortings).map { _1.members['Name'] }
      expect(ordered).to eq(item.fetch('expected')), item.fetch('name')
    end
  end

  it 'keeps equal rows in stored order and refuses incomparable values' do
    expect(described_class.sort(%w[b a b], [[:self, false]]) { |value, _key| value.upcase }).to eq(%w[a b b])
    expect { described_class.compare(1, 'a', false) }.to raise_error(Mxrb::NativeRuntimeError, /cannot sort/)
    expect(described_class.compare(nil, nil, true)).to eq(0)
  end
end
# rubocop:enable Metrics/BlockLength
