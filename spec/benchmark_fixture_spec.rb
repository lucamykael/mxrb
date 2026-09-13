# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/benchmark_fixture'

RSpec.describe Mxrb::BenchmarkFixture do
  it 'copies v2 external unit contents with the benchmark MPR' do
    Dir.mktmpdir('mxrb-benchmark-source-') do |source|
      Dir.mktmpdir('mxrb-benchmark-target-') do |target|
        mpr = File.join(source, 'App.mpr')
        contents = File.join(source, 'mprcontents')
        FileUtils.mkdir_p(contents)
        File.binwrite(mpr, 'mpr')
        File.binwrite(File.join(contents, 'unit.mxunit'), 'unit')

        copied = described_class.copy(mpr, target)

        expect(File.binread(copied)).to eq('mpr')
        expect(File.binread(File.join(target, 'mprcontents', 'unit.mxunit'))).to eq('unit')
      end
    end
  end

  it 'copies legacy self-contained MPRs without creating external contents' do
    Dir.mktmpdir('mxrb-benchmark-source-') do |source|
      Dir.mktmpdir('mxrb-benchmark-target-') do |target|
        mpr = File.join(source, 'Legacy.mpr')
        File.binwrite(mpr, 'legacy')

        expect(described_class.copy(mpr, target)).to eq(File.join(target, 'Legacy.mpr'))
        expect(File).not_to exist(File.join(target, 'mprcontents'))
      end
    end
  end
end
