# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/benchmark', __dir__)

RSpec.describe PipelineBenchmark do # rubocop:disable Metrics/BlockLength
  let(:identity) { { 'protocol' => described_class::PROTOCOL, 'fixture' => { 'sha256' => 'abc' }, 'runs' => 3 } }
  let(:limits) { described_class::METRICS.to_h { [_1, 2.0] } }
  let(:budget) { { 'schema_version' => 1, 'compatibility' => identity, 'limits_seconds' => limits } }

  def sample(values)
    { measurements_seconds: described_class::STAGES.zip(values).to_h, total_seconds: values.sum }
  end

  it 'takes the median of each stage and of whole runs, without summing stage medians' do
    samples = [sample([1, 9, 0, 0, 0, 0, 0]), sample([9, 1, 0, 0, 0, 0, 0]), sample([2, 2, 0, 0, 0, 0, 0])]
    result = described_class.summarize(samples)
    expect(result[:measurements_seconds].values.first(2)).to eq([2, 2])
    expect(result[:total_seconds]).to eq(10)
    expect(described_class.median([1, 8, 2, 4])).to eq(3)
  end

  it 'accepts exact limits and reports every exceeded metric' do
    checker = described_class::Budget.new(budget, identity)
    report = { measurements_seconds: described_class::STAGES.to_h { [_1, 2.0] }, total_seconds: 2.0 }
    expect(checker.check(report)).to eq(passed: true, exceeded: [])
    report[:measurements_seconds]['export'] = 3.0
    report[:total_seconds] = 4.0
    expect(checker.check(report)).to eq(passed: false, exceeded: [
                                          { metric: 'export', actual: 3.0,
                                            limit: 2.0 }, { metric: 'total', actual: 4.0, limit: 2.0 }
                                        ])
  end

  it 'rejects incompatible identities, unknown schemas and malformed limits' do
    expect { described_class::Budget.new(budget, identity.merge('runs' => 4)) }
      .to raise_error(ArgumentError, /incompatible/)
    expect { described_class::Budget.new(budget.merge('schema_version' => 99), identity) }
      .to raise_error(ArgumentError, /schema/)
    [limits.except('export'), limits.merge('typo' => 1), []].each do |invalid|
      expect { described_class::Budget.new(budget.merge('limits_seconds' => invalid), identity) }
        .to raise_error(ArgumentError, /exactly/)
    end
    [0, -1, '2', Float::INFINITY].each do |invalid|
      expect do
        described_class::Budget.new(budget.merge('limits_seconds' => limits.merge('total' => invalid)), identity)
      end
        .to raise_error(ArgumentError, /positive finite/)
    end
  end

  it 'selects exactly one measured machine class without falling back to another runner' do
    catalog = { 'schema_version' => 2, 'budgets' => [budget, budget.merge('compatibility' => { 'cpu' => 'other' })] }
    report = { measurements_seconds: described_class::STAGES.to_h { [_1, 1.0] }, total_seconds: 1.0 }
    expect(described_class::Budget.new(catalog, identity).check(report)).to eq(passed: true, exceeded: [])
    expect { described_class::Budget.new(catalog, identity.merge('runs' => 9)) }
      .to raise_error(ArgumentError, /incompatible/)
    expect { described_class::Budget.new(catalog.merge('budgets' => [budget, budget]), identity) }
      .to raise_error(ArgumentError, /ambiguous/)
    expect { described_class::Budget.new(catalog.merge('budgets' => {}), identity) }
      .to raise_error(ArgumentError, /array/)
  end

  it 'checks compatibility before running any expensive sample' do
    Dir.mktmpdir do |root|
      file = File.join(root, 'budget.json')
      File.write(file, JSON.generate(budget))
      allow(described_class).to receive(:compatibility).and_return(identity.merge('runs' => 1))
      expect(described_class::Sample).not_to receive(:new)
      expect { described_class.run('unused', runs: 1, budget: file) }.to raise_error(ArgumentError, /incompatible/)
    end
  end

  it 'preserves a real v2 fixture and the callers output environment across repeated runs' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'Shop.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:Shop) { entity(:Item) { string :Name } }
      end
      Mxrb.open(source, readonly: false) { _1.mpr.ensure_storage_for_version!('11.12.1') }
      original = described_class.fixture_identity(source)
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = '/tmp/outer-build.mpr'
      report = described_class.run(source, runs: 2)
      expect(report[:samples].size).to eq(2)
      expect(report[:samples].map { _1.dig(:semantic_cache, :cleared) }).to eq([true, true])
      expect(report[:compatibility].fetch('fixture')).to eq(original)
      expect(described_class.fixture_identity(source)).to eq(original)
      expect(ENV['MXRB_OUTPUT_PATH']).to eq('/tmp/outer-build.mpr')
      FileUtils.mkdir_p(File.join(root, 'theme'))
      File.write(File.join(root, 'theme', 'custom.css'), 'body { color: red; }')
      expect(described_class.asset_identity(source)).not_to eq(report[:compatibility].fetch('assets_sha256'))
      unit = Dir.glob(File.join(root, 'mprcontents', '**', '*.mxunit')).first
      File.open(unit, 'ab') { _1.write('changed') }
      expect(described_class.fixture_identity(source)).not_to eq(original)
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
    end
  end

  it 'restores the output environment even when generation raises' do
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = '/tmp/outer-build.mpr'
    runner = described_class::Sample.new('unused')
    allow(runner).to receive(:load).and_raise(IOError, 'failed generation')
    expect { runner.send(:generate, '/tmp/export', '/tmp/new.mpr') }.to raise_error(IOError)
    expect(ENV['MXRB_OUTPUT_PATH']).to eq('/tmp/outer-build.mpr')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end

  it 'returns distinct CLI statuses for a regression and invalid arguments' do
    previous = ENV['MXRB_BENCHMARK_MPR']
    ENV['MXRB_BENCHMARK_MPR'] = '/tmp/fixture.mpr'
    allow(described_class).to receive(:run).and_return({ budget: { passed: false } }, { budget: { passed: true } })
    expect { expect(described_class.cli([])).to eq(1) }.to output(/false/).to_stdout
    expect { expect(described_class.cli([])).to eq(0) }.to output(/true/).to_stdout
    expect { expect(described_class.cli(['unexpected'])).to eq(2) }.to output(/unexpected/).to_stderr
    ENV['MXRB_BENCHMARK_MPR'] = ''
    expect { expect(described_class.cli([])).to eq(2) }.to output(/MXRB_BENCHMARK_MPR/).to_stderr
  ensure
    ENV['MXRB_BENCHMARK_MPR'] = previous
  end

  it 'rejects invalid repetition counts' do
    [0, -1, 101, 1.5].each do |runs|
      expect { described_class.run('unused', runs:) }.to raise_error(ArgumentError, /between 1 and 100/)
    end
  end
end
