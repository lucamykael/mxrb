# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::RubyApp::Application do
  it 'serializes complete service invocations before they reach the shared SQLite runtime' do
    application = described_class.allocate
    application.instance_variable_set(:@runtime_monitor, Monitor.new)
    store = instance_double(Mxrb::Runtime::SQLiteStore, release_cache!: nil)
    interpreter = instance_double(Mxrb::Runtime::Native::Interpreter, effects: [], store:)
    bridge = instance_double(Mxrb::RubyApp::NativeBridge, interpreter:)
    allow(application).to receive(:bridge).and_return(bridge)
    allow(interpreter).to receive(:clear_effects!)
    allow(application).to receive(:serialize) { |value, **| value }
    active = 0
    maximum = 0
    lock = Mutex.new
    allow(application).to receive(:call_service) do
      lock.synchronize do
        active += 1
        maximum = [maximum, active].max
      end
      sleep 0.02
      lock.synchronize { active -= 1 }
      :ok
    end

    results = 4.times.map { Thread.new { application.invoke_service('App.Run') } }.map(&:value)

    expect(results).to all(include(result: :ok, effects: [], context: nil))
    expect(maximum).to eq(1)
  end
end
