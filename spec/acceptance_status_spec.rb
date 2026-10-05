# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Acceptance status report' do
  def status_report(*inputs)
    Dir.mktmpdir do |directory|
      arguments = inputs.each_with_index.flat_map do |(kind, payload), index|
        path = File.join(directory, "#{index}.json")
        File.write(path, JSON.generate(payload))
        ["--#{kind}", path]
      end
      script = File.expand_path('../script/acceptance_status', __dir__)
      stdout, stderr, result = Open3.capture3(RbConfig.ruby, script, *arguments)
      [stdout.empty? ? nil : JSON.parse(stdout), stderr, result.exitstatus]
    end
  end

  it 'keeps declaration classifications separate from tested execution' do
    manifest = { project: { name: 'App' }, runtime_model: 'ruby', coverage: [
      { status: 'executable_bidirectional' }, { status: 'source_preserved' }
    ] }
    report, _error, status = status_report([:manifest, manifest])
    expect(status).to eq(0)
    expect(report['status']).to eq('no_execution_evidence')
    expect(report['catalogs'].first['declared_artifacts']).to eq(2)
    expect(report['checks']).to eq([])
  end

  it 'reports successful nonempty native builds and exact line/branch coverage' do
    build = { status: 'completed', case_count: 1, cases: [{ label: 'source', status: 'passed', mxbuild_exit_code: 0 }] }
    coverage = { lines: { covered: 5, total: 5, percent: 100 }, branches: { covered: 2, total: 2, percent: 100 } }
    runtime = { status: 'passed', http_status: 200, page_ready: true, package_sha256: 'fixture',
                crud: { status: 'passed', steps: %w[create read update delete] } }
    report, _error, status = status_report([:native, build], [:coverage, coverage], [:runtime, runtime])
    expect(status).to eq(0)
    expect(report['status']).to eq('passed_for_supplied_evidence')
    expect(report['checks'].length).to eq(3)
    expect(report['checks'].map { _1['source']['sha256'].length }).to eq([64, 64, 64])
    coverage[:lines][:covered] = 4
    report, _error, status = status_report([:coverage, coverage])
    expect(status).to eq(1)
    expect(report['status']).to eq('failed')
  end

  it 'does not label empty batches or failed startup as certified' do
    report, _error, status = status_report([:native, { status: 'completed', case_count: 0, cases: [] }])
    expect(status).to eq(1)
    expect(report['checks'].first['passed']).to be(false)
    report, _error, status = status_report([:runtime, { status: 'failed', package_sha256: 'fixture' }])
    expect(status).to eq(1)
    expect(report['status']).to eq('failed')
  end

  it 'rejects malformed report types and missing inputs' do
    _report, error, status = status_report([:manifest, []])
    expect(status).to eq(2)
    expect(error).to include('expected JSON object')
    _report, error, status = status_report
    expect(status).to eq(2)
    expect(error).to include('supply at least one report')
  end
end
# rubocop:enable Metrics/BlockLength
