# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/protocol'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::Protocol do
  def raised(error)
    raise error
  rescue StandardError, ScriptError => e
    e
  end

  it 'maps MXRB and Ruby failures onto protocol codes a client can act on' do
    {
      described_class::Failure.new(described_class::BUSY, 'x') => described_class::BUSY,
      Mxrb::Studio::Cancelled.new => described_class::REQUEST_CANCELLED,
      Mxrb::Studio::Conflict.new => described_class::CONFLICT,
      Mxrb::Studio::Busy.new => described_class::BUSY,
      NotImplementedError.new => described_class::TOOLCHAIN,
      Mxrb::ToolchainError.new => described_class::TOOLCHAIN,
      Errno::ENOENT.new => described_class::TOOLCHAIN,
      Mxrb::Studio::RubySourceError.new('x') => described_class::RUBY_SOURCE,
      SyntaxError.new('x') => described_class::RUBY_SOURCE,
      LoadError.new('x') => described_class::RUBY_SOURCE,
      ArgumentError.new => described_class::INVALID_PARAMS,
      TypeError.new => described_class::INVALID_PARAMS,
      JSON::ParserError.new => described_class::INVALID_PARAMS,
      Mxrb::ValidationError.new => described_class::VALIDATION,
      RuntimeError.new => described_class::INTERNAL_ERROR
    }.each { |error, code| expect(described_class.code_for(error)).to eq(code), error.class.name }
    expect(described_class::KINDS.keys).to include(described_class::PARSE_ERROR, described_class::UNSUPPORTED_PROTOCOL)
  end

  it 'builds error objects with the failure data or the error type' do
    failure = described_class::Failure.new(described_class::UNSUPPORTED_PROTOCOL, 'old', { supported: [2] })
    expect(described_class.error_object(failure)).to eq(
      code: described_class::UNSUPPORTED_PROTOCOL, message: 'old',
      data: { kind: 'unsupported_protocol', supported: [2] }
    )
    expect(described_class.error_object(Mxrb::Studio::Conflict.new('changed'))).to eq(
      code: described_class::CONFLICT, message: 'changed', data: { kind: 'conflict', type: 'Mxrb::Studio::Conflict' }
    )
    plain = described_class::Failure.new(described_class::BUSY, 'busy')
    expect(plain.data).to eq({})
  end

  it 'keeps explicit locations, file:line messages and backtrace frames inside the workspace roots' do
    located = Mxrb::Studio::RubySourceError.new('bad', locations: [{ file: 'a.rb', line: 3 }])
    expect(described_class.error_object(located)[:data][:locations]).to eq([{ file: 'a.rb', line: 3 }])

    syntax = SyntaxError.new("/work/app/model.rb:4: syntax error\n./relative.rb:7: again\nnot a location")
    expect(described_class.locations_for(syntax, [])).to eq(
      [{ file: '/work/app/model.rb', line: 4 }, { file: File.expand_path('./relative.rb'), line: 7 }]
    )
    unlocated = Mxrb::Studio::RubySourceError.new('bad', locations: nil)
    expect(described_class.locations_for(unlocated, [])).to eq([])

    error = raised(RuntimeError.new('boom'))
    roots = [__dir__, nil]
    expect(described_class.locations_for(error, roots)).to include(file: __FILE__, line: be_a(Integer))
    expect(described_class.locations_for(error, ['/nowhere'])).to eq([])
    expect(described_class.error_object(error, roots: ['/nowhere'])[:data]).not_to have_key(:locations)

    evaluated = begin
      eval('raise "inside eval"', binding, '(generated)', 1) # rubocop:disable Style/EvalWithLocation
    rescue RuntimeError => e
      e
    end
    expect(described_class.backtrace_locations(evaluated).map { _1[:file] }).not_to include('(generated)')
    expect(described_class.backtrace_locations(RuntimeError.new('never raised'))).to eq([])
  end
end
# rubocop:enable Metrics
