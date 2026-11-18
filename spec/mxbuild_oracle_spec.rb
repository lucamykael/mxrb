# frozen_string_literal: true

require 'spec_helper'
require 'rbconfig'
load File.expand_path('../script/mxbuild_oracle', __dir__)

RSpec.describe MxbuildOracle do # rubocop:disable Metrics/BlockLength
  def outcome(built: false, exit_code: 1, diagnostics: [])
    { built:, exit_code:, diagnostics:, errors: [], warnings: [] }
  end

  it 'accepts successful builds only without new consistency errors' do
    built = outcome(built: true, exit_code: 0)
    expect(described_class.status(built, built, [])).to eq('pass')
    expect(described_class.status(built, built, ['CE1234: missing member'])).to eq('fail')
    expect(described_class.status(built, outcome, [])).to eq('fail')
  end

  it 'requires actual builds in certification mode while retaining equivalence for comparison' do
    equivalent = { pass: 0, equivalent: 1, fail: 0 }
    expect(described_class.passed?(equivalent)).to be(true)
    expect(described_class.passed?(equivalent, require_build: true)).to be(false)
    expect(described_class.passed?({ pass: 1, equivalent: 0, fail: 0 }, require_build: true)).to be(true)
    expect(described_class.passed?({ pass: 1, equivalent: 0, fail: 1 })).to be(false)
  end

  it 'returns a failing CLI exit for equivalent results when a build is required' do
    Dir.mktmpdir do |root|
      %w[source rebuilt].each { FileUtils.mkdir_p(File.join(root, 'case', _1)) }
      test_case = { label: 'case', version: '7.5.0', mpr: 'App.mpr',
                    source: 'case/source', rebuilt: 'case/rebuilt' }
      File.write(File.join(root, 'cases.json'), JSON.generate([test_case]))
      executable = File.join(root, 'mxbuild')
      File.write(executable, "#!#{RbConfig.ruby}\nwarn 'error: missing library'\nexit 1\n")
      File.chmod(0o755, executable)
      command = [RbConfig.ruby, File.expand_path('../script/mxbuild_oracle', __dir__), root, '--mxbuild', executable]
      _stdout, stderr, status = Open3.capture3(*command)
      expect(status.exitstatus).to eq(0), stderr
      _stdout, stderr, status = Open3.capture3(*command, '--require-build')
      expect(status.exitstatus).to eq(1), stderr
      expect(JSON.parse(File.read(File.join(root, 'oracle-all.json')))).to include('pass' => 0, 'equivalent' => 1)
    end
  end

  it 'rejects empty packages and records the size and digest of a successful package' do
    Dir.mktmpdir do |root|
      log = File.join(root, 'build.log')
      package = File.join(root, 'App.mda')
      File.write(log, '')
      File.write(package, '')
      expect(described_class.outcome(0, package, log, root)).to include(built: false, package_bytes: 0)
      File.write(package, 'package')
      expect(described_class.outcome(0, package, log, root))
        .to include(built: true, package_bytes: 7, package_sha256: Digest::SHA256.hexdigest('package'))
    end
  end

  it 'requires a diagnostic and matching nonzero exits for equivalent failures' do
    failed = outcome(diagnostics: ['error: missing library'])
    expect(described_class.status(failed, failed, [])).to eq('equivalent')
    expect(described_class.status(outcome, outcome, [])).to eq('fail')
    expect(described_class.status(failed, failed.merge(exit_code: 2), [])).to eq('fail')
    expect(described_class.status(failed, failed.merge(diagnostics: ['error: missing theme']), [])).to eq('fail')
    expect(described_class.status(failed, failed, ['CE1234: missing member'])).to eq('fail')
  end

  it 'never treats timeouts or missing packages after successful exits as equivalent' do
    [0, 124].each do |exit_code|
      failed = outcome(exit_code:, diagnostics: ['error: interrupted'])
      expect(described_class.status(failed, failed, [])).to eq('fail')
    end
  end

  it 'removes a previous package before invoking MxBuild' do
    Dir.mktmpdir do |root|
      directory = File.join(root, 'case', 'source')
      FileUtils.mkdir_p(directory)
      package = File.join(root, 'case', 'source.mda')
      File.write(package, 'stale package')
      allow(described_class).to receive(:execute) do |_command, log, _seconds|
        File.write(log, '')
        0
      end
      test_case = { 'source' => 'case/source', 'mpr' => 'App.mpr' }
      result = described_class.build(root, test_case, 'source', mxbuild: 'mxbuild', timeout: 1)

      expect(result).to include(built: false, exit_code: 0)
      expect(File).not_to exist(package)
    end
  end

  it 'normalizes project paths and retains consistency diagnostics without error keywords' do
    Dir.mktmpdir do |root|
      log = File.join(root, 'build.log')
      File.write(log, "#{root}/App.mpr CE1234: Missing member\n#{root}/App.mpr CW1234: Warning\n")
      result = described_class.outcome(1, File.join(root, 'App.mda'), log, root)

      expect(result[:errors]).to eq(['<project>/App.mpr CE1234: Missing member'])
      expect(result[:diagnostics]).to include('<project>/App.mpr CE1234: Missing member')
    end
  end

  it 'terminates a timed out process and records the timeout' do
    Dir.mktmpdir do |root|
      log = File.join(root, 'build.log')
      status = described_class.execute([RbConfig.ruby, '-e', 'sleep 5'], log, 0.1)
      expect(status).to eq(124)
      expect(File.read(log)).to include('timed out')
    end
  end
end
