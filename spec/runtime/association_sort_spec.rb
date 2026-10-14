# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Sorting through associations, as the Mendix 11.12.1 Runtime orders the
# native_association_sort fixture (docs/evidence/association-sort-2026-10-14.json).
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::SortPath do
  let(:evidence) { JSON.parse(File.read('docs/evidence/association-sort-2026-10-14.json')) }

  it 'orders retrieves through one and two associations as the native Runtime' do
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'Sort.mpr')
      load 'spec/fixtures/native_association_sort/project.rb'
      project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      expect(interpreter.call('Views.RunAll')).to be(true)
      logged = interpreter.instance_variable_get(:@log).to_h { _1.delete_prefix('ORACLE ').split('=', 2) }
      expect(logged.transform_values { _1.split(',') }).to eq(evidence.dig('native', 'results'))
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      project&.close
    end
  end

  it 'keeps the association steps through the Mendix DSL round trip' do
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = source = File.join(directory, 'source', 'Sort.mpr')
      load 'spec/fixtures/native_association_sort/project.rb'
      Mxrb::Exporter.new(source, File.join(directory, 'dsl')).export!
      sources = Dir[File.join(directory, 'dsl', '**', '*.rb')].map { File.read(_1) }.join
      expect(sources).to include('"Views.Shop_Region/Views.Region/Views.Region_Country/Views.Country/Rank"')
      ENV['MXRB_OUTPUT_PATH'] = rebuilt = File.join(directory, 'rebuilt', 'Sort.mpr')
      load File.join(directory, 'dsl', 'project.rb')
      expect(Mxrb.compare(source, rebuilt)).to be_identical
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
    end
  end

  it 'parses attribute paths and attribute references' do
    expect(described_class.parse('Name')).to eq([[], 'Name'])
    expect(described_class.parse('App.Shop.Name')).to eq([[], 'Name'])
    expect(described_class.parse('App.Shop_Region/App.Region/App.Region.Name')).to eq([['App.Shop_Region'], 'Name'])
    expect { described_class.parse('') }.to raise_error(ArgumentError, /cannot be empty/)
    reference = {
      'Attribute' => 'App.Country.Rank',
      'EntityRef' => { 'Steps' => Mxrb::IO::BsonCodec.build_array([{ 'Association' => 'App.Shop_Region' },
                                                                   { 'Association' => 'App.Region_Country' }]) }
    }
    expect(described_class.from_reference(reference)).to eq([%w[App.Shop_Region App.Region_Country], 'Rank'])
    expect(described_class.from_reference('Attribute' => 'App.Shop.Name')).to eq([[], 'Name'])
  end

  it 'reads associated values once per record and treats missing objects as empty' do
    object = Mxrb::Runtime::Native::ObjectValue
    region = object.new(entity: 'App.Region', id: 'r', members: { 'Name' => 'North' })
    shop = object.new(entity: 'App.Shop', id: 's', members: { 'Name' => 'Bea' })
    lonely = object.new(entity: 'App.Shop', id: 'l', members: {})
    store = Object.new
    calls = 0
    store.define_singleton_method(:retrieve_association) do |_association, record|
      calls += 1
      record.id == 's' ? [region] : []
    end
    read = described_class.reader { store }
    path = described_class.parse('App.Shop_Region/App.Region/Name')
    2.times { expect(read.call(shop, path)).to eq('North') }
    expect(read.call(lonely, path)).to be_nil
    expect(read.call(shop, [[], 'Name'])).to eq('Bea')
    expect(calls).to eq(2)
  end
end
# rubocop:enable Metrics/BlockLength
