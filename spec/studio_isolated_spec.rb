# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/isolated'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Studio::Isolated do
  let(:notifications) { [] }
  let(:context) do
    Mxrb::Studio::RequestContext.new(id: 7, notifier: ->(name, payload) { notifications << [name, payload] })
  end

  around do |example|
    previous = Mxrb::Studio::ProgressTask.instance_variable_get(:@interval)
    Mxrb::Studio::ProgressTask.interval = 0
    example.run
  ensure
    Mxrb::Studio::ProgressTask.interval = previous
    Thread.current[Mxrb::Progress::THREAD_KEY] = nil
  end

  def child_frames(roots = [], &)
    reader, writer = IO.pipe
    described_class.serve_child(IO.pipe.first, writer, roots, &)
    frames = []
    while (frame = described_class.read_frame(reader))
      frames << frame
    end
    frames
  ensure
    reader&.close
    Thread.current[Mxrb::Progress::THREAD_KEY] = nil
  end

  it 'returns the value of a forked block and forwards its progress to the request' do
    result = context.with_progress('Isolated') do
      described_class.run(context) do
        Mxrb::Progress.with('child') do |task|
          task.add_total(3)
          task.update(current: 1, detail: 'one')
          task.advance(1, detail: 'two')
        end
        { pid: Process.pid, values: [1, 'two'] }
      end
    end
    expect(result[:pid]).not_to eq(Process.pid)
    expect(result[:values]).to eq([1, 'two'])
    reports = notifications.map(&:last)
    expect(reports.map { _1[:kind] }).to include('begin', 'report', 'end')
    expect(reports.find { _1[:detail] == 'two' }).to include(current: 2, total: 3, token: 7)
  end

  it 'turns child failures into protocol failures that keep their code and locations' do
    expect { described_class.run(context) { raise ArgumentError, 'bad input' } }
      .to raise_error(Mxrb::Studio::Protocol::Failure) { |error|
        expect(error.code).to eq(Mxrb::Studio::Protocol::INVALID_PARAMS)
        expect(error.message).to eq('bad input')
        expect(error.data).to include(kind: 'invalid_params', type: 'ArgumentError')
      }
    Dir.mktmpdir('mxrb-isolated-') do |root|
      file = File.join(root, 'project.rb')
      File.write(file, "raise 'broken definition'\n")
      expect { described_class.run(context, roots: [root]) { Kernel.load(file) } }
        .to raise_error(Mxrb::Studio::Protocol::Failure) { |error|
          expect(error.data[:locations]).to include(file:, line: 1)
        }
    end
  end

  it 'reports a worker that ends without a result' do
    expect { described_class.run(context) { exit!(3) } }
      .to raise_error(Mxrb::Studio::Protocol::Failure, /without a result/)
  end

  it 'terminates the worker when the request is cancelled' do
    canceller = Thread.new do
      sleep 0.2
      context.cancel!
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { described_class.run(context) { sleep 10 } }.to raise_error(Mxrb::Studio::Cancelled)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    canceller.join
  end

  it 'serves results, errors and exits on the child side' do
    expect(child_frames { 42 }).to eq([[:ok, 42]])
    kind, payload = child_frames { exit 5 }.first
    expect(kind).to eq(:error)
    expect(payload).to include(code: Mxrb::Studio::Protocol::RUBY_SOURCE, message: /exited with status 5/)
    kind, payload = child_frames { raise Mxrb::ToolchainError, 'no git' }.first
    expect([kind, payload[:code]]).to eq([:error, Mxrb::Studio::Protocol::TOOLCHAIN])
    frames = child_frames do
      Mxrb::Progress.current.start.update(current: 1, total: 2, detail: 'x', force: true)
      Mxrb::Progress.current.advance(2, detail: 'y', force: true).add_total(1).finish('done')
      Mxrb::Progress.current.fail('nope')
      Mxrb::Progress.current.enabled?
    end
    expect(frames).to eq([[:progress, { current: 1, total: 2, detail: 'x' }], [:advance, { amount: 2, detail: 'y' }],
                          [:add_total, { amount: 1 }], [:ok, true]])
  end

  it 'forwards child progress kinds and converts a cancelled parent task into cancellation' do
    task = instance_double(Mxrb::Studio::ProgressTask)
    allow(task).to receive(:update).and_raise(Mxrb::Studio::Cancelled)
    allow(task).to receive(:advance)
    allow(task).to receive(:add_total)
    described_class.forward(task, :advance, { amount: 2, detail: 'a' }, context)
    described_class.forward(task, :add_total, { amount: 4 }, context)
    expect(task).to have_received(:advance).with(2, detail: 'a')
    expect(task).to have_received(:add_total).with(4)
    expect(context).not_to be_cancelled
    described_class.forward(task, :progress, { current: 1, total: nil, detail: nil }, context)
    expect(context).to be_cancelled
  end

  it 'ignores truncated frames and processes that are already gone' do
    reader, writer = IO.pipe
    writer.write('abc')
    writer.close
    expect(described_class.read_frame(reader)).to be_nil
    pid = Process.spawn(RbConfig.ruby, '-e', 'exit 0')
    Process.wait(pid)
    expect(described_class.terminate(pid)).to be_nil
  end
end

RSpec.describe Mxrb::Studio::RequestContext do
  let(:notifications) { [] }
  let(:context) { described_class.new(id: 'r1', notifier: ->(*message) { notifications << message }) }

  around do |example|
    previous = Mxrb::Studio::ProgressTask.instance_variable_get(:@interval)
    Mxrb::Studio::ProgressTask.interval = 0
    example.run
  ensure
    Mxrb::Studio::ProgressTask.interval = previous
  end

  it 'runs cancel hooks once, immediately for late hooks, and not after removal' do
    calls = []
    first = context.on_cancel { calls << :first }
    removed = context.on_cancel { calls << :removed }
    context.remove_cancel_hook(removed)
    expect { context.check! }.not_to raise_error
    context.cancel!
    expect(calls).to eq([:first])
    context.on_cancel { calls << :late }
    expect(calls).to eq(%i[first late])
    expect { context.check! }.to raise_error(Mxrb::Studio::Cancelled, 'request cancelled')
    expect(context.remove_cancel_hook(first)).to be_nil
  end

  it 'notifies without a notifier and restores the previous progress task' do
    expect(described_class.new.notify('x', {})).to be_nil
    outer = Mxrb::Progress::NullTask.instance
    Thread.current[Mxrb::Progress::THREAD_KEY] = outer
    expect(context.with_progress('Work', total: 2) { |task| task.advance.advance(detail: 'b').current }).to eq(2)
    expect(Thread.current[Mxrb::Progress::THREAD_KEY]).to be(outer)
    kinds = notifications.map { _1.last[:kind] }
    expect(kinds).to eq(%w[begin report report end])
    expect(notifications.last.last).to include(token: 'r1', label: 'Work', current: 2, total: 2, detail: 'b')
  ensure
    Thread.current[Mxrb::Progress::THREAD_KEY] = nil
  end

  it 'reports failures and cancellation through the progress task' do
    expect { context.with_progress('Fails') { raise 'boom' } }.to raise_error(RuntimeError, 'boom')
    expect(notifications.last.last).to include(kind: 'end', failed: true, detail: 'boom')
    context.cancel!
    notifications.clear
    expect { context.with_progress('Never') { :unreachable } }.to raise_error(Mxrb::Studio::Cancelled)
    expect(notifications).to be_empty
  end
end

RSpec.describe Mxrb::Studio::ProgressTask do
  it 'throttles reports to the interval unless forced and keeps state' do
    messages = []
    context = Mxrb::Studio::RequestContext.new(id: 1, notifier: ->(*message) { messages << message })
    previous = described_class.instance_variable_get(:@interval)
    described_class.interval = nil
    expect(described_class.interval).to eq(described_class::INTERVAL)
    described_class.interval = 60
    task = described_class.new(context, :label).start
    task.update(current: 1, total: 4, detail: 'first')
    task.update(current: 2)
    task.update(detail: 'forced', force: true)
    task.add_total(1)
    task.finish('finished')
    expect(messages.map { _1.last[:kind] }).to eq(%w[begin report end])
    expect(task).to have_attributes(label: 'label', total: 5, current: 2, detail: 'finished', enabled?: true)
    task.finish
    task.fail
    expect(messages.last.last).to include(failed: true, detail: 'finished')
  ensure
    described_class.interval = previous
  end
end
# rubocop:enable Metrics/BlockLength
