# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::WebUi do
  around do |example|
    Dir.mktmpdir do |directory|
      @root = File.join(directory, 'web-ui')
      @assets = File.join(@root, 'assets')
      FileUtils.mkdir_p(File.join(@assets, 'nested'))
      File.binwrite(File.join(@root, 'domain.html'), '<title>Domain</title>')
      File.binwrite(File.join(@assets, 'app.js'), 'mxrb()')
      File.binwrite(File.join(@assets, 'blob.unknown'), "\x00\x01")
      example.run
    end
  end

  before { allow(described_class).to receive(:root).and_return(@root) }

  it 'reads named pages and assigns explicit or safe fallback content types' do
    expect(described_class.page('domain')).to eq('<title>Domain</title>')
    expect(described_class.asset('/assets/app.js'))
      .to eq(['mxrb()', 'application/javascript; charset=utf-8'])
    expect(described_class.asset('/assets/blob.unknown'))
      .to eq(["\x00\x01", 'application/octet-stream'])
  end

  it 'rejects missing, malformed, and traversing asset paths' do
    deeply_encoded_dot = '%2e'
    8.times { deeply_encoded_dot = deeply_encoded_dot.gsub('%', '%25') }

    paths = [
      '/other/app.js', '/assets/', "/assets/a\0b", '/assets/a\\b',
      '/assets/a//b', '/assets/./app.js', '/assets/../domain.html',
      '/assets/%252e%252e/domain.html', "/assets/#{deeply_encoded_dot}/app.js",
      '/assets/missing.js'
    ]
    expect(paths.map { described_class.asset(_1) }).to all(be_nil)
  end

  it 'allows only files whose real path stays inside the asset directory' do
    outside = File.join(File.dirname(@root), 'outside.js')
    File.binwrite(outside, 'outside()')
    File.symlink(outside, File.join(@assets, 'outside.js'))
    File.symlink(File.join(@assets, 'app.js'), File.join(@assets, 'inside.js'))

    expect(described_class.asset('/assets/outside.js')).to be_nil
    expect(described_class.asset('/assets/nested')).to be_nil
    expect(described_class.asset('/assets/inside.js'))
      .to eq(['mxrb()', 'application/javascript; charset=utf-8'])
  end
end
# rubocop:enable Metrics/BlockLength
