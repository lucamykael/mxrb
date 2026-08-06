# frozen_string_literal: true

require 'stringio'
require 'spec_helper'

ProgressTtyBuffer = Class.new(StringIO) do
  def tty? = true
end

ProgressNarrowBuffer = Class.new(ProgressTtyBuffer) do
  def winsize = [24, 18]
end

ProgressBrokenWinsizeBuffer = Class.new(ProgressTtyBuffer) do
  def winsize = raise(Errno::ENOTTY)
end

ProgressZeroWinsizeBuffer = Class.new(ProgressTtyBuffer) do
  def winsize = [24, 0]
end

ProgressPlainBuffer = Class.new do
  attr_reader :string

  def initialize = (@string = +'')
  def write(value) = (@string << value)
  def tty? = false
end

ProgressBrokenWriteBuffer = Class.new(ProgressPlainBuffer) do
  def write(*) = raise(IOError)
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Progress do
  after { described_class.reset! }

  it 'renders determinate progress and completes at 100 percent' do
    output = ProgressTtyBuffer.new
    described_class.configure(enabled: true, io: output)

    result = described_class.with('Exporting App.mpr', total: 4) do |progress|
      progress.advance(detail: 'native units', force: true)
      progress.advance(detail: 'modules', force: true)
      :done
    end

    expect(result).to eq(:done)
    expect(output.string).to include('Exporting App.mpr', '25%', '50%', '100%')
  end

  it 'does not render when progress is disabled' do
    output = ProgressTtyBuffer.new
    described_class.configure(enabled: false, io: output)

    task = nil
    described_class.with('Loading') { task = _1 }

    expect(task).not_to be_enabled
    expect(output.string).to be_empty
  end

  it 'marks a failed operation and reraises its error' do
    output = ProgressTtyBuffer.new
    described_class.configure(enabled: true, io: output)

    expect do
      described_class.with('Importing') { raise Mxrb::Error, 'invalid package' }
    end.to raise_error(Mxrb::Error, 'invalid package')
    expect(output.string).to include('FAILED', 'Importing', 'invalid package')
  end

  it 'supports dynamic totals, clamping, nested operations, and every terminal shape' do
    output = ProgressTtyBuffer.new
    task = described_class::Task.new('Loading a dynamic operation', io: output).start
    sleep(described_class::Task::REFRESH_INTERVAL * 2)
    expect(task.update(current: -2, total: 0, detail: 'discovered', force: true)).to equal(task)
    expect(task.update(current: 99, force: true)).to equal(task)
    expect(task.update(force: true)).to equal(task)
    expect(task.add_total(2)).to equal(task)
    expect(task.advance(1, force: true)).to equal(task)
    expect(task.finish('complete')).to equal(task)
    expect(task.finish).to equal(task)
    expect(output.string).to include('discovered', '100%')

    indeterminate = described_class::Task.new('Static spinner', io: ProgressPlainBuffer.new)
    indeterminate.advance
    indeterminate.advance
    indeterminate.add_total(1)
    indeterminate.fail
    expect(indeterminate.fail('ignored')).to equal(indeterminate)
    described_class::Task.new('No known total', io: ProgressPlainBuffer.new).finish

    narrow = ProgressNarrowBuffer.new
    described_class::Task.new('A label that must be truncated', total: 1, io: narrow).start.finish
    expect(narrow.string).to include('...')
    described_class::Task.new(
      'winsize fallback', total: 1, io: ProgressBrokenWinsizeBuffer.new
    ).start.finish
    described_class::Task.new('zero winsize', total: 1, io: ProgressZeroWinsizeBuffer.new).start.finish
    described_class::Task.new('broken output', io: ProgressBrokenWriteBuffer.new).start
  end

  it 'covers automatic enablement, environment opt-out, current task, and nested reuse' do
    output = ProgressTtyBuffer.new
    previous = ENV['MXRB_PROGRESS']
    described_class.reset!
    described_class.configure(io: output)
    expect(described_class).to be_enabled
    ENV['MXRB_PROGRESS'] = 'off'
    expect(described_class).not_to be_enabled
    ENV['MXRB_PROGRESS'] = ''

    described_class.configure(io: Object.new)
    expect(described_class).not_to be_enabled
    described_class.configure(io: output)

    seen = []
    described_class.with('Outer', total: 1) do
      seen << described_class.current
      described_class.with('Inner') { seen << _1 }
    end
    expect(seen.uniq.size).to eq(1)
    expect(described_class.current).to equal(described_class::NullTask.instance)

    described_class.configure(enabled: true)
    described_class.configure(enabled: nil, io: nil)
    expect(described_class).to be_enabled
  ensure
    ENV['MXRB_PROGRESS'] = previous
  end
end
# rubocop:enable Metrics/BlockLength
