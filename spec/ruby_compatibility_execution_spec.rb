# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'annotated rule and expression compatibility' do # rubocop:disable Metrics/BlockLength
  before { Mxrb::RubyApp::Registry.reset! }
  after { Mxrb::RubyApp::Registry.reset! }

  it 'executes the same oracle cases directly and from exported Ruby with the MPR unavailable' do
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Application.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.expand_path('fixtures/native_compatibility/project.rb', __dir__)
      cases = JSON.parse(File.read(File.expand_path('fixtures/native_compatibility/cases.json', __dir__)))
      cases << { 'name' => 'VerifyRule', 'expected' => 'passed' }
      Mxrb.open(source) do |project|
        interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
        cases.each { |item| expect_oracle_result(item) { interpreter.call("Compatibility.#{item['name']}") } }
      end
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR is unavailable')
      application = Mxrb::RubyApp::Application.new(target)
      cases.each { |item| expect_oracle_result(item) { application.call_service("Compatibility.#{item['name']}") } }
      rule_path = File.join(target, 'app/services/compatibility/non_empty.rb')
      File.write(rule_path, File.read(rule_path).sub('> 0', '> 100'))
      application.close
      application = Mxrb::RubyApp::Application.new(target)
      expect(application.call_service('Compatibility.VerifyRule')).to eq('failed')
    ensure
      application&.close
    end
  end

  def expect_oracle_result(item, &block)
    if item['expected_error']
      expect(&block).to raise_error(Mxrb::NativeRuntimeError, /substring range/)
    else
      expect(block.call).to eq(item.fetch('expected'))
    end
  end

  it 'validates all branch syntax while evaluating only selected operations' do
    expression = Mxrb::Runtime::Native::Expression.new
    expect(expression.evaluate('$item != empty and $item/Name = \'safe\'', { 'item' => nil })).to be(false)
    expect(expression.evaluate('$item = empty or $item/Name = \'safe\'', { 'item' => nil })).to be(true)
    expect(expression.evaluate('false or false or true', {})).to be(true)
    expect(expression.evaluate('true and true and false', {})).to be(false)
    expect(expression.evaluate('if false then 1 else if true then 2 else 3', {})).to eq(2)
    [
      'if true 1 else 2', 'if true then 1', 'if true then 1 else (2',
      'if 1 then 2 else 3', '1 and true', 'not empty',
      '1 div 0', '1 : 0', '1 mod 0', "'one' div 2", "2 div 'two'", '4 / 2'
    ].each do |source|
      expect { expression.evaluate(source, {}) }.to raise_error(Mxrb::NativeRuntimeError)
    end
  end

  it 'evaluates required temporal additions with signed offsets and rejects malformed calls' do
    expression = Mxrb::Runtime::Native::Expression.new
    value = Time.utc(2026, 10, 5, 12)
    { 'addSeconds' => 1, 'addMinutes' => 60, 'addDays' => 86_400 }.each do |function, seconds|
      expect(expression.evaluate("#{function}($Date, -2)", { 'Date' => value })).to eq(value - (2 * seconds))
    end
    expect(expression.evaluate('trim(empty)', {})).to eq('')
    expect { expression.evaluate('urlDecode()', {}) }.to raise_error(IndexError)
  end
end
