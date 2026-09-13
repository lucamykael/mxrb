# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/forms_core_project_gate', __dir__)

# rubocop:disable Metrics/BlockLength
RSpec.describe MxrbFormsCoreProjectGate do
  it 'imports and recompiles every inherited core Forms property as readable Ruby' do
    Dir.mktmpdir('mxrb-forms-core-project-spec-') do |workspace|
      report = described_class.run(['--workspace', workspace])

      expect(report).to include(
        passed: true, project_round_trip_passed: true,
        mendix_version: '11.12.1', widget_count: 41,
        property_count: 455, readable_ruby: true
      )
      expect(report.fetch(:phases)).to include(
        represented: 455, source_emitted: 455, storage_transcoded: 455,
        imported: 455, compiled: 455, round_tripped: 455, studio_validated: 0
      )
      expect(report.dig(:source, :mismatches)).to be_empty
      expect(report.dig(:rebuilt, :mismatches)).to be_empty
      expect(report.dig(:source, :certified_properties)).to eq(455)
      expect(report.dig(:rebuilt, :certified_properties)).to eq(455)
    end
  end

  it 'keeps Studio validation independent from successful project round-trips' do
    expect(described_class.property_cases.size).to eq(455)
  end

  it 'distinguishes an MxBuild-readable project from an accepted project' do
    status = instance_double(Process::Status, success?: false, exitstatus: 3)
    payload = { 'problems' => [{ 'errorCode' => 'CE0544' }, { 'errorCode' => 'CE0544' }] }

    report = described_class.oracle_report('BUILD FAILED', status, payload, '/tmp/errors.json')

    expect(report).to include(
      loaded: true, accepted: false, exit_status: 3, problem_count: 2,
      problem_codes: { 'CE0544' => 2 }
    )
    expect(described_class.oracle_report('StorageLoadException', status, payload, '/tmp/errors.json'))
      .to include(loaded: false, accepted: false)
  end
end
# rubocop:enable Metrics/BlockLength
