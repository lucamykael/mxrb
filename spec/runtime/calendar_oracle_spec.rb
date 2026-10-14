# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Runs the calendar oracle fixture in the Ruby interpreter. The expected values were
# logged by the Mendix 11.12.1 Runtime (docs/evidence/calendar-functions-2026-10-14.json).
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Calendar functions against the native Runtime' do
  let(:fixture) { 'spec/fixtures/native_calendar_functions' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'Calendar.mpr')
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  it 'evaluates distances, calendar boundaries, UTC formats and boundary tokens as the native Runtime' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h { _1.delete_prefix('ORACLE ').split('=', 2) }
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'rejects wrong arities and non-date arguments' do
    expression = Mxrb::Runtime::Native::Expression.new
    ['daysBetween([%CurrentDateTime%])', "calendarMonthsBetween('a', 'b')", 'beginOfDay()',
     'max([%CurrentDateTime%], 1)', "formatDateUTC([%CurrentDateTime%], 'yyyy')"].each do |text|
      expect { expression.evaluate(text, {}) }.to raise_error(Mxrb::NativeRuntimeError), text
    end
  end
end
# rubocop:enable Metrics/BlockLength
