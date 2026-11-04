# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'script/validate_ruby_app' do
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

  def validate(*arguments)
    script = File.expand_path('../script/validate_ruby_app', __dir__)
    Open3.capture3(RbConfig.ruby, script, *arguments)
  end

  def package_digests(directory)
    Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).select { File.file?(_1) }.sort.to_h do |path|
      [path, Digest::SHA256.file(path).hexdigest]
    end
  end

  it 'validates an MPR sharing another project contents from a copy and leaves the package untouched' do
    Dir.mktmpdir do |directory|
      owner = make_split_project(File.join(directory, 'Owner.mpr'))
      shared = File.join(directory, 'Shared.mpr')
      FileUtils.cp(owner, shared)
      before = package_digests(directory)

      stdout, stderr, status = validate(shared)

      expect(status).to be_success, stderr
      expect(JSON.parse(stdout)).to include(
        'source' => shared, 'contents_shared_with' => 'Owner.mpr', 'valid' => true, 'identical' => true
      )
      expect(stderr).to include('Shared.mpr: validating a temporary copy, because mprcontents belongs to Owner.mpr')
      expect(package_digests(directory)).to eq(before)
    end
  end

  it 'does not report sharing for the project that owns the contents' do
    Dir.mktmpdir do |directory|
      owner = make_split_project(File.join(directory, 'Owner.mpr'))

      stdout, stderr, status = validate(owner)

      expect(status).to be_success, stderr
      expect(JSON.parse(stdout)).to include('valid' => true, 'identical' => true)
      expect(JSON.parse(stdout)).not_to have_key('contents_shared_with')
      expect(stderr).not_to include('temporary copy')
    end
  end

  it 'does not report sharing for an inline MPR beside another project contents' do
    Dir.mktmpdir do |directory|
      make_split_project(File.join(directory, 'Owner.mpr'))
      inline = File.join(directory, 'Inline.mpr')
      Mxrb.define(inline) { mendix_version '11.12.1' }

      stdout, stderr, status = validate(inline)

      expect(status).to be_success, stderr
      expect(JSON.parse(stdout)).not_to have_key('contents_shared_with')
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

      _stdout, _stderr, status = validate('--repair-hashes', other)

      expect(status).not_to be_success
      expect(File.read(File.join(directory, 'mprcontents', 'mprname')).strip).to eq('Owner.mpr')
    end
  end
end
# rubocop:enable Metrics/BlockLength
