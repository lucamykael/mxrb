# frozen_string_literal: true

require 'stringio'
require 'spec_helper'

ProgressTtyBuffer = Class.new(StringIO) do
  def tty? = true
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
end
# rubocop:enable Metrics/BlockLength
