# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'frontend migrator CLI' do
  def executable
    [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'frontend']
  end

  def project(dir, version: '10.24.0.73019', layout: true)
    path = File.join(dir, 'App.mpr')
    Mxrb.define(path) do
      mendix_version version
      self.module(:App) { entity :Item }
    end
    return path unless layout

    mpr = Mxrb::IO::MprFile.open(path)
    mpr.insert_unit(
      container_uuid: mpr.root_unit.fetch('UnitID'), containment_name: 'Documents',
      contents_doc: {
        '$Type' => 'Forms$Page', 'Name' => 'Home',
        'Row' => {
          '$Type' => 'Forms$LayoutGridRow',
          'Columns' => [{ '$Type' => 'Forms$LayoutGridColumn', 'Weight' => -1 }]
        }
      }
    )
    path
  ensure
    mpr&.close
  end

  def row_weight(path)
    Mxrb.open(path) do |model|
      page = model.all_units.find { model.parse_bson(_1)['$Type'] == 'Forms$Page' }
      model.parse_bson(page).dig('Row', 'Columns', 0, 'Weight')
    end
  end

  it 'previews and applies a safe migration with the complete JSON contract' do
    Dir.mktmpdir do |dir|
      path = project(dir)
      stdout, stderr, status = Open3.capture3(*executable, 'migrate', path, '--json')
      payload = JSON.parse(stdout)
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(payload).to eq(
        'version' => '10.24.0.73019', 'changes' => 1, 'widgets' => 0,
        'layout_rows' => 1, 'design_properties' => 0, 'issues' => [],
        'safe' => true, 'applied' => false
      )
      expect(row_weight(path)).to eq(-1)

      stdout, stderr, status = Open3.capture3(*executable, 'migrate', path, '--apply', '--json')
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(JSON.parse(stdout)).to include('safe' => true, 'applied' => true, 'layout_rows' => 1)
      expect(row_weight(path)).to eq(12)
    end
  end

  it 'renders a human preview and exits nonzero with structured issues when blocked' do
    Dir.mktmpdir do |dir|
      safe_path = project(dir)
      stdout, stderr, status = Open3.capture3(*executable, 'migrate', safe_path)
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include(
        'Version           : 10.24.0.73019', 'Changes           : 1',
        'Layout rows       : 1', 'Safe              : true', 'Applied           : false'
      )

      blocked = project(File.join(dir, 'blocked'), version: '9.24.0', layout: false)
      stdout, stderr, status = Open3.capture3(*executable, 'migrate', blocked, '--apply', '--json')
      payload = JSON.parse(stdout)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to be_empty
      expect(payload).to include(
        'version' => '9.24.0', 'changes' => 0, 'safe' => false, 'applied' => false
      )
      expect(payload.fetch('issues')).to include(include('kind' => 'unsupported_version'))
    end
  end

  it 'documents usage and rejects missing or unknown actions and options' do
    stdout, stderr, status = Open3.capture3(*executable, '--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('mxrb frontend migrate FILE.mpr', '--apply', '--json')

    stdout, stderr, status = Open3.capture3(*executable, 'migrate', '--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('changed only when --apply')

    _stdout, stderr, status = Open3.capture3(*executable, 'unknown')
    expect(status).not_to be_success
    expect(stderr).to include('Unknown frontend action')

    _stdout, stderr, status = Open3.capture3(*executable, 'migrate')
    expect(status).not_to be_success
    expect(stderr).to include('Usage: mxrb frontend migrate')

    Dir.mktmpdir do |dir|
      path = project(dir, layout: false)
      _stdout, stderr, status = Open3.capture3(*executable, 'migrate', path, '--unknown')
      expect(status).not_to be_success
      expect(stderr).to include('Unknown arguments: --unknown')
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
