# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'script/validate_matrix' do
  it 'reports every missing fixture and fails closed after completing the matrix' do
    Dir.mktmpdir do |directory|
      report = File.join(directory, 'matrix.json')
      script = File.expand_path('../script/validate_matrix', __dir__)
      _stdout, stderr, status = Open3.capture3(
        { 'MXRB_FIXTURES_ROOT' => directory }, RbConfig.ruby, script, report
      )

      expect(status).not_to be_success
      payload = JSON.parse(File.read(report))
      expect(payload.fetch('totals')).to include('fixtures' => 6, 'passed' => 0, 'failed' => 6)
      expect(payload.fetch('fixtures').map { _1.fetch('result') }).to contain_exactly(*Array.new(6, 'fail'))
      expect(stderr.scan(/fixture not found/).size).to eq(6)
    end
  end
end
