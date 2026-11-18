# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/mxbuild_oracle_inputs', __dir__)

RSpec.describe MxbuildOracleInputs do # rubocop:disable Metrics/BlockLength
  it 'rejects traversal labels before creating any output' do
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'App.mpr')
      File.write(mpr, 'placeholder')
      %w[. .. ../outside nested/case].each do |label|
        output = File.join(root, 'inputs')
        expect { described_class.generate(output, ["#{label}=#{mpr}"]) }
          .to raise_error(ArgumentError, /invalid label/)
        expect(File).not_to exist(output)
      end
    end
  end

  it 'rejects duplicate labels and missing inputs without leaving a partial workspace' do
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'App.mpr')
      File.write(mpr, 'placeholder')
      output = File.join(root, 'inputs')
      %w[demo Demo].each do |duplicate|
        expect { described_class.generate(output, ["demo=#{mpr}", "#{duplicate}=#{mpr}"]) }
          .to raise_error(ArgumentError, /duplicate label/)
        expect(File).not_to exist(output)
      end
      expect { described_class.generate(output, ["demo=#{mpr}", 'missing=/missing/App.mpr']) }
        .to raise_error(ArgumentError, /MPR not found/)
      expect(File).not_to exist(output)
    end
  end

  it 'prepares portable relative case paths from a relative output directory' do
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'original', 'App.mpr')
      FileUtils.mkdir_p(File.dirname(mpr))
      Mxrb.define(mpr) do
        mendix_version '11.12.1'
        self.module(:Shop) { entity(:Order) { string :Name } }
      end
      original = File.binread(mpr)
      Dir.chdir(root) { described_class.generate('inputs', ["legacy-11.12=#{mpr}"]) }
      output = File.join(root, 'inputs')
      test_case = JSON.parse(File.read(File.join(output, 'cases.json'))).first

      expect(test_case).to include('source' => 'legacy-11.12/source', 'rebuilt' => 'legacy-11.12/rebuilt')
      source = File.join(output, test_case.fetch('source'), 'App.mpr')
      rebuilt = File.join(output, test_case.fetch('rebuilt'), 'App.mpr')
      expect(Mxrb.compare(source, rebuilt)).to be_identical
      expect(File.binread(mpr)).to eq(original)
    end
  end
end
