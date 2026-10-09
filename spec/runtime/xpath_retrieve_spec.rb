# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Mxrb::Runtime::XPath do
  let(:fixture) { 'spec/fixtures/native_xpath_retrieve' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'XPath.mpr')
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  it 'retrieves the same objects as the native Mendix 11.12.1 Runtime, comparing strings without case' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h do |line|
      name, values = line.delete_prefix('ORACLE ').split('=', 2)
      [name, values.delete_suffix(',')]
    end
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end
end
