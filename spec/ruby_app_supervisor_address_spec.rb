# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::RubyApp::Supervisor do
  around do |example|
    saved = ENV.to_h.slice('HOST', 'MXRB_SERVER_PORT')
    example.run
  ensure
    %w[HOST MXRB_SERVER_PORT].each { ENV.delete(_1) }
    ENV.update(saved)
  end

  it 'gives an in-process backend the address Java actions report as the application root' do
    allow(Mxrb::RubyApp::Manifest).to receive(:load).and_return(double(data: {}))
    allow(Mxrb::RubyApp::Server).to receive(:new).and_return(double(start: nil, shutdown: nil))
    environment = Mxrb::Environment.new('development', root: '.', process: {})
    described_class.new('.', api_port: 9392, environment:, frontend: false).start
    context = Mxrb::Runtime::JavaActionContext.allocate
    context.instance_variable_set(:@environment, ENV)
    expect(context.application_root_url).to eq('http://127.0.0.1:9392/')
  end
end
