# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/calibrate_benchmark', __dir__)

RSpec.describe PipelineBenchmark::Calibration do # rubocop:disable Metrics/BlockLength
  def report(value)
    stages = PipelineBenchmark::STAGES.to_h { [_1, value] }
    { 'schema_version' => 1, 'compatibility' => { 'runs' => 3, 'runner' => 'test' },
      'measurements_seconds' => stages, 'total_seconds' => value * stages.size,
      'samples' => Array.new(3) { { 'measurements_seconds' => stages.dup, 'total_seconds' => value * stages.size } } }
  end

  it 'uses the worst observed median and records variation without mixing environments' do
    result = described_class.build([report(1), report(2), report(3)])
    expect(result.fetch('limits_seconds')).to include('export' => 4.5, 'total' => 31.5)
    expect(result.dig('calibration', 'observed_seconds', 'export')).to eq('min' => 1, 'max' => 3, 'median' => 2)
    expect { described_class.build([report(1), report(2), report(3).merge('compatibility' => { 'runs' => 4 })]) }
      .to raise_error(ArgumentError, /incompatible/)
  end

  it 'rejects insufficient evidence, invalid margins, missing metrics and incorrect summaries' do
    expect { described_class.build([report(1)]) }.to raise_error(ArgumentError, /three reports/)
    [1, 0, Float::INFINITY].each do |margin|
      expect { described_class.build([report(1)] * 3, margin:) }.to raise_error(ArgumentError, /margin/)
    end
    bad = report(1)
    bad['samples'] = []
    expect { described_class.build([bad] * 3) }.to raise_error(ArgumentError, /sample count/)
    bad = report(1)
    bad['measurements_seconds']['export'] = 10
    expect { described_class.build([bad] * 3) }.to raise_error(ArgumentError, /medians/)
    bad = report(1)
    bad['total_seconds'] = 0
    expect { described_class.build([bad] * 3) }.to raise_error(ArgumentError, /positive finite/)
    bad = report(1)
    bad['samples'].first['total_seconds'] = 100
    expect { described_class.build([bad] * 3) }.to raise_error(ArgumentError, /sample total/)
  end

  it 'records file digests and refuses duplicate input evidence' do
    Dir.mktmpdir do |root|
      paths = [1, 2, 3].map do |value|
        File.join(root, "#{value}.json").tap { File.write(_1, JSON.generate(report(value))) }
      end
      expect { expect(described_class.cli(paths.dup)).to eq(0) }.to output(/source_sha256/).to_stdout
      expect { expect(described_class.cli([paths.first] * 3)).to eq(2) }.to output(/distinct/).to_stderr
    end
  end
end
