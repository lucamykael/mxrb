# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
load File.expand_path('../script/frontend_lifecycle_acceptance', __dir__)

# rubocop:disable Metrics/BlockLength
RSpec.describe MxrbFrontendLifecycleAcceptance do
  it 'proves the complete CLI-only Ruby/MPR mutation lifecycle on Mendix 10 and 11' do
    Dir.mktmpdir do |root|
      %w[10.24.0.73019 11.12.1].each do |version|
        workspace = File.join(root, version)
        report = described_class::Runner.new(workspace:, version:).run

        expect(report).to include(
          passed: true, scenario: 'frontend_cli_lifecycle', mendix_version: version
        )
        expect(report).not_to have_key(:error)
        expect(report.fetch(:gates).values).to all(be(true))
        expect(report.dig(:preflight, :baseline, 'stats')).to include(
          'pages' => 1, 'layouts' => 1, 'microflows' => 0, 'nanoflows' => 0
        )
        expect(report.dig(:preflight, :final, 'stats')).to include(
          'pages' => 2, 'layouts' => 1, 'microflows' => 1, 'nanoflows' => 1
        )
        expect(report.dig(:mutations, :diff).join("\n")).to include(
          'Orders', 'ACT_CreateOrder', 'NAN_RefreshOrders'
        )
        expect(report.fetch(:oracles)).to eq({})
        expect(report.fetch(:commands).map { _1.fetch(:command).first }.uniq).to eq(['mxrb'])

        project_root = report.fetch(:project_root)
        final_root = File.join(workspace, 'final')
        final_ruby = File.join(workspace, 'final-ruby')
        expect(File).to exist(File.join(project_root, 'FrontendCycle.mpr'))
        expect(File).to exist(File.join(final_root, 'FrontendCycle.mpr'))
        expect(File.read(File.join(final_ruby, 'app', 'navigation', 'navigation.rb')))
          .to include('item "Orders", page: "FrontendCycle.Orders"')
        expect(File.read(File.join(final_ruby, 'theme', 'web', 'frontend-lifecycle.css')))
          .to include('display: block')
      end
    end
  end

  it 'fails closed for unsupported versions and an existing scenario project' do
    Dir.mktmpdir do |root|
      unsupported = described_class::Runner.new(workspace: File.join(root, 'old'), version: '9.6.1').run
      expect(unsupported).to include(passed: false)
      expect(unsupported.fetch(:error)).to include('unsupported lifecycle version')

      workspace = File.join(root, 'occupied')
      FileUtils.mkdir_p(File.join(workspace, described_class::PROJECT_NAME))
      occupied = described_class::Runner.new(workspace:).run
      expect(occupied).to include(passed: false)
      expect(occupied.fetch(:error)).to include('workspace project already exists')
    end
  end

  it 'aggregates configurable mx check and MxBuild read-only oracles' do
    Dir.mktmpdir do |root|
      mx = File.join(root, 'mx')
      mxbuild = File.join(root, 'mxbuild')
      File.write(mx, <<~RUBY)
        #!#{RbConfig.ruby}
        require 'json'
        output = ARGV.fetch(ARGV.index('--json') + 1)
        File.write(output, JSON.generate(
          'serialization_version' => 1, 'errors' => [], 'warnings' => [],
          'deprecations' => [], 'performance' => { 'recommendations' => [] },
          'total-problems' => 0
        ))
      RUBY
      File.write(mxbuild, <<~RUBY)
        #!#{RbConfig.ruby}
        output = ARGV.find { _1.start_with?('--output=') }.split('=', 2).last
        File.binwrite(output, 'mda')
      RUBY
      FileUtils.chmod(0o755, [mx, mxbuild])

      report = described_class::Runner.new(
        workspace: File.join(root, 'workspace'), mxcheck: mx, mxbuild:, strict_warnings: true
      ).run

      expect(report).to include(passed: true)
      expect(report.fetch(:oracles).keys).to contain_exactly(:mx, :mxbuild)
      expect(report.fetch(:gates)).to include(mx_oracle: true, mxbuild_oracle: true)
      expect(report.dig(:oracles, :mx, 'strict_warnings')).to be(true)
      expect(report.dig(:oracles, :mxbuild, 'strict_warnings')).to be(false)
    end
  end
end
# rubocop:enable Metrics/BlockLength
