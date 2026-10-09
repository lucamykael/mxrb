# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Microflow list Sort operation' do
  let(:fixture) { 'spec/fixtures/native_list_sort' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      @source = File.join(directory, 'ListSort.mpr')
      ENV['MXRB_OUTPUT_PATH'] = @source
      load File.join(fixture, 'project.rb')
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
    end
  end

  def logged(path)
    Mxrb.open(path) do |project|
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      expect(interpreter.call('Views.RunAll')).to be(true)
      interpreter.instance_variable_get(:@log).to_h do |line|
        name, values = line.delete_prefix('ORACLE ').split('=', 2)
        [name, values.delete_suffix(',').split(',')]
      end
    end
  end

  it 'sorts in memory exactly as the native Mendix 11.12.1 Runtime' do
    results = logged(@source)
    cases.each { |item| expect(results.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'keeps the sort keys through two Ruby export and regeneration cycles' do
    current = @source
    2.times do |index|
      target = File.join(@directory, "ruby-#{index}")
      rebuilt = File.join(@directory, "rebuilt-#{index}.mpr")
      Mxrb::Exporter.new(current, target).export!
      source = Dir[File.join(target, '**', '*.rb')].map { File.read(_1) }.join
      expect(source).to include('list_operation :sort, :stored, sort: [["Views.Location.Name", :descending]')
      ENV['MXRB_OUTPUT_PATH'] = rebuilt
      load File.join(target, 'project.rb')
      expect(Mxrb.compare(current, rebuilt)).to be_identical
      expect(logged(rebuilt)).to eq(logged(@source))
      current = rebuilt
    end
  end

  it 'accepts sort keys only for the sort operation' do
    expect do
      Mxrb.define(File.join(@directory, 'Invalid.mpr')) do
        mendix_version '11.12.1'
        self.module(:M) { microflow(:F) { list_operation :head, :items, as: :first, sort: [%w[M.E.Name Ascending]] } }
      end
    end.to raise_error(ArgumentError, /only to the sort list operation/)
  end
end
# rubocop:enable Metrics/BlockLength
