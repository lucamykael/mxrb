# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Password policy of persisted users' do
  let(:fixture) { 'spec/fixtures/native_password_policy' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Policy.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load File.join(fixture, 'project.rb')
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def application
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: { 'MXRB_DATABASE_PATH' => ':memory:' })
  end

  def status(app, flow)
    app.call_service("Views.#{flow}")
    200
  rescue Mxrb::RubyApp::RecordValidationError
    403
  end

  it 'refuses the same commits as the native Mendix 11.12.1 Runtime' do
    app = application
    app.call_service('Views.Setup')
    expect(app.call_service('Views.Users')).to eq(expected.first.fetch('users'))
    expected.drop(1).each do |step|
      flow = step.fetch('step').delete_prefix('GET:')
      expect(status(app, flow)).to eq(step.fetch('status')), flow
    end
  end
end

RSpec.describe Mxrb::Runtime::PasswordPolicy do
  it 'reports each failed criterion with the Mendix system texts' do
    policy = described_class.new(minimum_length: 8, digit: true, mixed_case: true, symbol: true)
    expect(policy.message(policy.failures('ab'))).to eq(
      "Password does not meet password policy criteria:\n - Password should be at least 8 characters.\n " \
      "- Password should contain a digit.\n - Password should contain an uppercase character.\n - " \
      "Password should contain at least one of the following symbols: #{described_class::SYMBOLS}"
    )
    expect(policy.failures('ÁBCdef1!')).to eq([])
    expect(policy.failures('Abcdefg1 ')).to eq(
      ["Password should contain at least one of the following symbols: #{described_class::SYMBOLS}"]
    )
    expect(described_class.from_security(nil).failures('')).to eq([])
    expect(described_class.new(minimum_length: 0, digit: false, mixed_case: true, symbol: false).failures('ABC'))
      .to eq(['Password should contain a lowercase character.'])
  end
end
# rubocop:enable Metrics/BlockLength
