# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'script/certify_mprs' do
  def make_split_project(path)
    manifest = File.join(File.dirname(path), 'native_units.json')
    File.write(manifest, JSON.generate('format_version' => 'v2', 'units' => []))
    Mxrb.define(path) do
      mendix_version '11.12.1'
      native_units manifest
      self.module(:App) { entity(:Item) { string :Name } }
    end
    path
  end

  def certify(directory, *arguments)
    report = File.join(directory, 'report.json')
    script = File.expand_path('../script/certify_mprs', __dir__)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, '--output', report, *arguments)
    [JSON.parse(File.read(report)).fetch('projects'), stderr, status]
  end

  def package_digests(directory)
    Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).select { File.file?(_1) }.sort.to_h do |path|
      [path, Digest::SHA256.file(path).hexdigest]
    end
  end

  it 'certifies an MPR sharing another project contents from a copy and leaves the package untouched' do
    Dir.mktmpdir do |directory|
      owner = make_split_project(File.join(directory, 'Owner.mpr'))
      shared = File.join(directory, 'Shared.mpr')
      FileUtils.cp(owner, shared)
      before = package_digests(directory)

      rows, stderr, status = certify(directory, owner, shared)

      expect(status).to be_success, stderr
      expect(rows.map { _1.fetch('result') }).to eq(%w[pass pass])
      expect(rows.first).not_to have_key('contents_shared_with')
      expect(rows.last).to include('name' => 'Shared', 'contents_shared_with' => 'Owner.mpr')
      expect(stderr).to include('Shared: certifying a temporary copy, because mprcontents belongs to Owner.mpr')
      expect(package_digests(directory).except(File.join(directory, 'report.json'))).to eq(before)
    end
  end

  it 'still fails when the contents it would share do not match the MPR, even when repairing hashes' do
    Dir.mktmpdir do |directory|
      make_split_project(File.join(directory, 'Owner.mpr'))
      other = Dir.mktmpdir do |elsewhere|
        make_split_project(File.join(elsewhere, 'Other.mpr'))
        FileUtils.cp(File.join(elsewhere, 'Other.mpr'), directory)
        File.join(directory, 'Other.mpr')
      end

      rows, _stderr, status = certify(directory, '--repair-hashes', other)

      expect(status).not_to be_success
      expect(rows.first).to include('result' => 'fail', 'contents_shared_with' => 'Owner.mpr')
      expect(File.read(File.join(directory, 'mprcontents', 'mprname')).strip).to eq('Owner.mpr')
    end
  end

  it 'does not report sharing for an inline MPR beside another project contents' do
    Dir.mktmpdir do |directory|
      make_split_project(File.join(directory, 'Owner.mpr'))
      inline = File.join(directory, 'Inline.mpr')
      Mxrb.define(inline) { mendix_version '11.12.1' }

      rows, stderr, status = certify(directory, inline)

      expect(status).to be_success, stderr
      expect(rows.first).to include('name' => 'Inline', 'result' => 'pass')
      expect(rows.first).not_to have_key('contents_shared_with')
    end
  end
end
# rubocop:enable Metrics/BlockLength
