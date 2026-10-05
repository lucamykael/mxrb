# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::AsyncInvocations do
  it 'runs each invocation once, isolates sessions, retains failures and expires completed results' do
    started = Queue.new
    release = Queue.new
    now = 0
    application = double('application')
    allow(application).to receive(:invoke_service) do |name, args, context:|
      started << name
      release.pop
      raise 'failed flow' if name == 'App.Fail'

      { result: args.fetch('value'), context: }
    end
    jobs = described_class.new(application, limit: 2, retention: 10, clock: -> { now })
    arguments = { 'value' => 42 }
    first = jobs.submit('App.Run', arguments, owner: 'session-a', context: nil)
    expect(started.pop).to eq('App.Run')
    arguments['value'] = 99
    expect(jobs.fetch(first[:id], owner: 'session-b')).to be_nil
    expect(jobs.fetch(first[:id], owner: 'session-a')).to eq(status: 'pending')
    second = jobs.submit('App.Fail', {}, owner: 'session-a', context: nil)
    expect { jobs.submit('App.Run', {}, owner: 'session-a', context: nil) }.to raise_error(ArgumentError, /capacity/)
    release << true
    expect(started.pop).to eq('App.Fail')
    expect(jobs.fetch(first[:id], owner: 'session-a')).to eq(status: 'completed', result: { result: 42, context: nil })
    release << true
    jobs.close
    expect(jobs.fetch(second[:id],
                      owner: 'session-a')).to include(status: 'failed',
                                                      error: {
                                                        code: 'invocation_failed', message: 'failed flow'
                                                      })
    now = 11
    expect(jobs.fetch(first[:id], owner: 'session-a')).to be_nil
    expect { jobs.submit('', {}, owner: nil, context: nil) }.to raise_error(ArgumentError, /name/)
    expect { jobs.submit('App.Run', nil, owner: nil, context: nil) }.to raise_error(ArgumentError, /arguments/)
    expect(application).to have_received(:invoke_service).twice
    expect { jobs.submit('App.Run', {}, owner: nil, context: nil) }.to raise_error(ArgumentError, /closed/)
  ensure
    jobs&.close
  end

  it 'closes an unused executor without creating a worker' do
    jobs = described_class.new(double('unused application'))
    expect(jobs.close).to be_nil
    expect(jobs.close).to be_nil
    expect { jobs.submit('App.Run', {}, owner: nil, context: nil) }.to raise_error(ArgumentError, /closed/)
  end
end
# rubocop:enable Metrics/BlockLength
