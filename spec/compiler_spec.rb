# frozen_string_literal: true

require 'digest'
require 'open3'
require 'tmpdir'
require 'spec_helper'

# Compiler examples intentionally share one realistic deployment fixture.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler do
  def create_project(root, version: '11.12.1')
    path = File.join(root, 'Clinic.mpr')
    Mxrb.define(path) do
      mendix_version version
      self.module(:Clinic) { entity(:Animal) { string :Name } }
    end
    path
  end

  # rubocop:disable Metrics/MethodLength
  def create_deployment(root, runtime_version: '11.12.1')
    deployment = File.join(root, 'deployment')
    {
      'model/model.mdp' => 'compiled-model',
      'model/metadata.json' => JSON.generate(
        'RuntimeVersion' => runtime_version, 'ProjectName' => 'Clinic', 'JavaVersion' => 21
      ),
      'model/bundles/project.jar' => 'jar',
      'web/index.html' => '<main>Clinic</main>',
      'web/dist/index.js' => "export default 'clinic'",
      'native/package.json' => '{}',
      'sass/main.scss' => 'body {}',
      'tmp/.keep' => ''
    }.each do |relative, content|
      path = File.join(deployment, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, content)
    end
    deployment
  end
  # rubocop:enable Metrics/MethodLength

  it 'selects explicit compiler adapters by Mendix major version' do
    expect(described_class::Adapter.for('9.24.0')).to be_a(described_class::Adapter::V9)
    expect(described_class::Adapter.for('10.21.0')).to be_a(described_class::Adapter::V10)
    expect(described_class::Adapter.for('11.12.1')).to be_a(described_class::Adapter::V11)
    expect { described_class::Adapter.for('8.18.0') }
      .to raise_error(Mxrb::UnsupportedVersion, /9\.x through 11\.x/)
  end

  it 'packs a deterministic MDA without invoking an external toolchain' do
    Dir.mktmpdir do |root|
      mpr = create_project(root)
      deployment = create_deployment(root)
      first = File.join(root, 'first.mda')
      second = File.join(root, 'second.mda')

      result = described_class::Packager.new(mpr, deployment:).pack(output: first)
      described_class::Packager.new(mpr, deployment:).pack(output: second)
      inspection = described_class::Mda.inspect(first)

      expect(result.files).to eq(8)
      expect(inspection.roots).to eq(%w[model native sass tmp web])
      expect(inspection.metadata).to include(
        'RuntimeVersion' => '11.12.1', 'ProjectName' => 'Clinic'
      )
      expect(Digest::SHA256.file(first).hexdigest)
        .to eq(Digest::SHA256.file(second).hexdigest)
    end
  end

  it 'rejects stale packages and excludes runtime working files' do
    Dir.mktmpdir do |root|
      mpr = create_project(root)
      deployment = create_deployment(root, runtime_version: '10.24.0')
      packager = described_class::Packager.new(mpr, deployment:)
      expect { packager.pack(output: File.join(root, 'stale.mda')) }
        .to raise_error(Mxrb::CompilationError, /targets Mendix 10\.24\.0/)

      deployment = create_deployment(root)
      packager = described_class::Packager.new(mpr, deployment:)
      FileUtils.mkdir_p(File.join(deployment, 'run'))
      File.write(File.join(deployment, 'run', 'secret.txt'), 'runtime state')
      result = packager.pack(output: File.join(root, 'roots.mda'))
      paths = described_class::Mda.inspect(result.path).entries.map(&:path)
      expect(paths).not_to include('run/secret.txt')
    end
  end

  it 'compares MDA entries by content rather than zip metadata' do
    Dir.mktmpdir do |root|
      mpr = create_project(root)
      deployment = create_deployment(root)
      left = File.join(root, 'left.mda')
      right = File.join(root, 'right.mda')
      described_class::Packager.new(mpr, deployment:).pack(output: left)
      File.write(File.join(deployment, 'web', 'index.html'), 'changed')
      described_class::Packager.new(mpr, deployment:).pack(output: right)

      expect(described_class::Mda.compare(left, right).map(&:path)).to eq(['web/index.html'])
    end
  end

  it 'exposes pack and MDA inspection through the CLI' do
    Dir.mktmpdir do |root|
      mpr = create_project(root)
      create_deployment(root)
      output = File.join(root, 'Clinic.mda')
      cli = File.expand_path('../bin/mxrb', __dir__)
      stdout, status = Open3.capture2e(
        RbConfig.ruby, cli, 'pack', mpr, '--output', output
      )
      expect(status).to be_success
      expect(stdout).to include('Packed 8 files')

      inspection, inspect_status = Open3.capture2e(
        RbConfig.ruby, cli, 'mda', 'inspect', output, '--json'
      )
      expect(inspect_status).to be_success
      expect(JSON.parse(inspection)).to include('files' => 8)
    end
  end
end
# rubocop:enable Metrics/BlockLength
