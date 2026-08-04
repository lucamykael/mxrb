# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength

require 'spec_helper'
require 'tmpdir'
load File.expand_path('../script/frontend_acceptance', __dir__)

RSpec.describe MxrbFrontendAcceptance do
  def problem(code:, severity: 'Error', message: 'problem', module_name: 'App', element: 'Widget')
    {
      'severity' => severity,
      'errorCode' => code,
      'message' => message,
      'locations' => [{
        'module' => module_name, 'document' => "Page 'Home'", 'element' => element,
        'unitId' => 'volatile-unit', 'elementId' => 'volatile-element'
      }]
    }
  end

  def check_problem(code:, message: 'check problem')
    {
      'code' => code, 'message' => message,
      'locations' => [{
        'module-name' => 'App', 'document-name' => "Page 'Home'",
        'element-name' => 'Widget', 'unit-id' => 'unit', 'element-id' => 'element'
      }]
    }
  end

  def check_payload(errors: [], warnings: [], deprecations: [], recommendations: [])
    {
      'serialization_version' => 1, 'errors' => errors, 'warnings' => warnings,
      'deprecations' => deprecations, 'performance' => { 'recommendations' => recommendations },
      'total-problems' => errors.size + warnings.size + deprecations.size + recommendations.size
    }
  end

  def errors_file(root, name, problems)
    path = File.join(root, name)
    File.write(path, JSON.generate('errors' => [], 'problems' => problems))
    path
  end

  def project(root, version: '11.12.1', marketplace: false)
    FileUtils.mkdir_p(File.join(root, 'theme', 'web'))
    File.write(File.join(root, 'theme', 'web', 'main.scss'), '$brand: #123456;')
    path = File.join(root, 'App.mpr')
    Mxrb.define(path) do
      mendix_version version
      self.module(:App) { entity :Item }
    end
    return path unless marketplace

    FileUtils.mkdir_p(File.join(root, '.mxrb', 'marketplace'))
    File.write(File.join(root, '.mxrb', 'marketplace.lock.json'), '{}')
    File.binwrite(File.join(root, '.mxrb', 'marketplace', 'App-1.0.0.mpk'), 'package')
    path
  end

  it 'classifies MxBuild diagnostics and compares stable semantic signatures' do
    source_payload = {
      'problems' => [problem(code: 'CE0462'), problem(code: 'CE9999', severity: 'Warning')]
    }
    rebuilt_payload = {
      'problems' => [problem(code: 'CE9999', severity: 'Warning'), problem(code: 'CE0462')]
    }
    source = described_class::DiagnosticSet.new(source_payload)
    rebuilt = described_class::DiagnosticSet.new(rebuilt_payload)

    expect(source).to be_equivalent(rebuilt)
    expect(source).not_to be_ready
    expect(source.to_h).to include(
      problems: 2, errors: 1, warnings: 1,
      warnings_observable: true,
      categories: { 'missing_widget_package' => 1, 'unclassified' => 1 },
      codes: { 'CE0462' => 1, 'CE9999' => 1 },
      modules: { 'App' => 2 }, elements: { 'Widget' => 2 }
    )
    changed = described_class::DiagnosticSet.new(
      { 'problems' => [problem(code: 'CE0462', message: 'different')] }
    )
    expect(source).not_to be_equivalent(changed)
  end

  it 'enforces optional warning strictness and validates diagnostic JSON fail-closed' do
    warnings = described_class::DiagnosticSet.new(
      { 'problems' => [problem(code: 'CW0263', severity: 'Warning')] }
    )
    expect(warnings).to be_ready
    expect(warnings.ready?(strict_warnings: true)).to be(false)
    expect { described_class::DiagnosticSet.new([]) }
      .to raise_error(described_class::Failure, /JSON object/)
    expect { described_class::DiagnosticSet.new({ 'problems' => {} }) }
      .to raise_error(described_class::Failure, /array/)
    expect { described_class::DiagnosticSet.new({}) }
      .to raise_error(described_class::Failure, /no problems array/)
    expect do
      described_class::DiagnosticSet.new(
        { 'problems' => [problem(code: 'X', severity: 'Fatal')] }
      )
    end.to raise_error(described_class::Failure, /unknown MxBuild severity/)
    expect { described_class::DiagnosticSet.new({ 'problems' => ['bad'] }) }
      .to raise_error(described_class::Failure, /must be an object/)
    expect do
      described_class::DiagnosticSet.new(
        { 'problems' => [
          { 'severity' => 'Error', 'message' => 'bad', 'errorCode' => 'X', 'locations' => {} }
        ] }
      )
    end.to raise_error(described_class::Failure, /locations must be an array/)
  end

  it 'normalizes mx check diagnostics and validates their exit-status mask' do
    payload = check_payload(
      errors: [check_problem(code: 'CE0001')],
      warnings: [check_problem(code: 'CW0001')],
      deprecations: [check_problem(code: 'DEPRECATED')],
      recommendations: [check_problem(code: 'MXP011')]
    )
    diagnostics = described_class::DiagnosticSet.new(payload)
    expect(diagnostics.exit_mask).to eq(15)
    expect(diagnostics.to_h).to include(
      problems: 4, errors: 1, warnings: 3, warnings_observable: true,
      kinds: { 'best_practice' => 1, 'deprecation' => 1, 'error' => 1, 'warning' => 1 }
    )

    expect do
      described_class::DiagnosticSet.new(payload.merge('total-problems' => 3))
    end.to raise_error(described_class::Failure, /total-problems mismatch/)
    expect do
      described_class::DiagnosticSet.new(payload.merge('performance' => []))
    end.to raise_error(described_class::Failure, /performance must be an object/)
    expect do
      described_class::DiagnosticSet.new(payload.merge('warnings' => {}))
    end.to raise_error(described_class::Failure, /warnings must be an array/)
  end

  it 'fails closed on nonzero MxBuild exits without reported model errors' do
    Dir.mktmpdir do |root|
      mpr = project(File.join(root, 'source'))
      executable = File.join(root, 'mxbuild')
      File.write(executable, <<~RUBY)
        #!/usr/bin/env ruby
        require 'json'
        errors = ARGV.find { _1.start_with?('--write-errors=') }.split('=', 2).last
        File.write(errors, JSON.generate('problems' => []))
        exit 1
      RUBY
      File.chmod(0o755, executable)

      oracle = described_class::MxBuildOracle.new(executable)
      expect { oracle.diagnose(mpr, File.join(root, 'empty')) }
        .to raise_error(described_class::Failure, /exited 1 without model errors/)

      File.write(executable, <<~RUBY)
        #!/usr/bin/env ruby
        require 'json'
        errors = ARGV.find { _1.start_with?('--write-errors=') }.split('=', 2).last
        problem = {'severity' => 'Error', 'errorCode' => 'CE0001', 'message' => 'model error'}
        File.write(errors, JSON.generate('problems' => [problem]))
        exit 1
      RUBY
      result = oracle.diagnose(mpr, File.join(root, 'model-error'))
      expect(result).not_to be_ready
      expect { described_class::MxBuildOracle.new(File.join(root, 'missing')) }
        .to raise_error(described_class::Failure, /not executable/)
    end
  end

  it 'proves zero errors without inventing warnings when live MxBuild omits diagnostics' do
    Dir.mktmpdir do |root|
      source = project(File.join(root, 'source'))
      executable = File.join(root, 'mxbuild')
      File.write(executable, <<~RUBY)
        #!/usr/bin/env ruby
        output = ARGV.find { _1.start_with?('--output=') }.split('=', 2).last
        File.binwrite(output, 'mda')
        exit 0
      RUBY
      File.chmod(0o755, executable)

      oracle = described_class::MxBuildOracle.new(executable)
      diagnostics = oracle.diagnose(source, File.join(root, 'oracle'))
      expect(diagnostics).to be_ready
      expect(diagnostics.ready?(strict_warnings: true)).to be(false)
      expect(diagnostics.to_h).to include(
        problems: nil, errors: 0, warnings: nil, warnings_observable: false
      )

      report = described_class::Runner.new(source, mxbuild: executable).run
      expect(report).to include(passed: true, scope: 'frontend', frontend_ready: true)
      expect(report.dig(:oracle, :source)).to include(
        errors: 0, warnings: nil, warnings_observable: false
      )

      expect do
        described_class::Runner.new(source, mxbuild: executable, strict_warnings: true).run
      end.to raise_error(described_class::Failure, /strict warning gate requires observable warnings/)
    end
  end

  it 'runs mx check with observable diagnostics and rejects tool/status mismatches' do
    Dir.mktmpdir do |root|
      source = project(File.join(root, 'source'))
      executable = File.join(root, 'mx')
      payload = check_payload(
        warnings: [check_problem(code: 'CW0055')],
        recommendations: [check_problem(code: 'MXP011')]
      )
      File.write(executable, <<~RUBY)
        #!/usr/bin/env ruby
        require 'json'
        output = ARGV.fetch(ARGV.index('--json') + 1)
        File.write(output, #{JSON.generate(payload).inspect})
        exit 10
      RUBY
      File.chmod(0o755, executable)

      report = described_class::Runner.new(source, mxcheck: executable).run
      expect(report).to include(passed: true, scope: 'frontend', frontend_ready: true)
      expect(report.dig(:oracle, :source)).to include(
        errors: 0, warnings: 2, warnings_observable: true,
        kinds: { 'best_practice' => 1, 'warning' => 1 }
      )
      strict = described_class::Runner.new(source, mxcheck: executable, strict_warnings: true).run
      expect(strict).to include(passed: false, frontend_ready: false)

      File.write(executable, <<~RUBY)
        #!/usr/bin/env ruby
        require 'json'
        output = ARGV.fetch(ARGV.index('--json') + 1)
        File.write(output, #{JSON.generate(payload).inspect})
        exit 0
      RUBY
      oracle = described_class::MxCheckOracle.new(executable)
      expect { oracle.diagnose(source, File.join(root, 'mismatch')) }
        .to raise_error(described_class::Failure, /does not match diagnostic mask 10/)

      File.write(executable, "#!/usr/bin/env ruby\nwarn 'broken'\nexit 1\n")
      expect { oracle.diagnose(source, File.join(root, 'missing-json')) }
        .to raise_error(described_class::Failure, /produced no JSON: broken/)
      expect { described_class::MxCheckOracle.new(File.join(root, 'missing')) }
        .to raise_error(described_class::Failure, /mx is not executable/)
    end
  end

  it 'round-trips Mendix 10 and 11 with exact assets and native preflight' do
    Dir.mktmpdir do |root|
      %w[10.24.0.73019 11.12.1].each do |version|
        source_root = File.join(root, version)
        FileUtils.mkdir_p(source_root)
        report = described_class::Runner.new(project(source_root, version:)).run

        expect(report).to include(
          passed: true, mendix_version: version, oracle: nil,
          scope: 'round_trip', frontend_ready: nil
        )
        expect(report[:gates].values).to all(be(true))
        expect(report[:assets]).to include(passed: true, files: 1, bytes: 16)
      end
    end
  end

  it 'keeps round-trip equivalence separate from frontend readiness' do
    Dir.mktmpdir do |root|
      source = project(File.join(root, 'source'))
      errors = [problem(code: 'CE0463')]
      source_errors = errors_file(root, 'source.json', errors)
      rebuilt_errors = errors_file(root, 'rebuilt.json', errors)
      report = described_class::Runner.new(source, source_errors:, rebuilt_errors:).run

      expect(report[:passed]).to be(false)
      expect(report).to include(scope: 'frontend', frontend_ready: false)
      expect(report[:oracle]).to include(passed: false, equivalent: true, frontend_ready: false)
      expect(report.dig(:oracle, :source, :categories)).to eq('stale_widget_definition' => 1)
    end
  end

  it 'rejects diagnostic divergence, unpaired evidence, and unsupported generations' do
    Dir.mktmpdir do |root|
      source = project(File.join(root, 'source'))
      source_errors = errors_file(root, 'source.json', [])
      rebuilt_errors = errors_file(root, 'rebuilt.json', [problem(code: 'CE6087')])
      report = described_class::Runner.new(source, source_errors:, rebuilt_errors:).run
      expect(report.dig(:oracle, :equivalent)).to be(false)

      expect { described_class::Runner.new(source, source_errors:) }
        .to raise_error(described_class::Failure, /supplied together/)
      expect { described_class::Runner.new(source, mxcheck: '/mx', mxbuild: '/mxbuild') }
        .to raise_error(described_class::Failure, /mutually exclusive/)
      old = project(File.join(root, 'old'), version: '9.6.1.29396')
      expect { described_class::Runner.new(old).run }
        .to raise_error(described_class::Failure, /unsupported Mendix generation/)
    end
  end

  it 'preserves Marketplace lifecycle provenance as part of the no-loss asset gate' do
    Dir.mktmpdir do |root|
      source = project(File.join(root, 'source'), marketplace: true)
      originals = File.join(root, 'source', '.mxrb', 'marketplace-originals')
      FileUtils.mkdir_p(originals)
      File.binwrite(File.join(originals, 'Widget.mpk'), 'original')
      report = described_class::Runner.new(source).run

      expect(report[:passed]).to be(true)
      expect(report.dig(:assets, :marketplace_provenance)).to eq(
        files: 3, missing: [], changed: [], unexpected: []
      )
    end
  end

  it 'rejects symlinks anywhere inside the no-loss asset boundary' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source')
      exported = File.join(root, 'exported')
      rebuilt = File.join(root, 'rebuilt')
      [source, rebuilt, File.join(exported, '.mxrb')].each { FileUtils.mkdir_p(_1) }
      target = File.join(root, 'lock.json')
      File.write(target, '{}')
      FileUtils.mkdir_p(File.join(source, '.mxrb'))
      File.symlink(target, File.join(source, '.mxrb', 'marketplace.lock.json'))
      File.write(File.join(exported, '.mxrb', 'assets.json'), JSON.generate('version' => 1, 'files' => []))

      gate = described_class::AssetGate.new(source, exported, rebuilt)
      expect { gate.inspect }.to raise_error(described_class::Failure, /contains symlinks/)
    end
  end
end

# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
