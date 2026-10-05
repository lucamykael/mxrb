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
        cases.each { expect(interpreter.call("Compatibility.#{_1['name']}")).to eq(_1['expected']) }
      end
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR is unavailable')
      application = Mxrb::RubyApp::Application.new(target)
      cases.each { expect(application.call_service("Compatibility.#{_1['name']}")).to eq(_1['expected']) }
      rule_path = File.join(target, 'app/services/compatibility/non_empty.rb')
      File.write(rule_path, File.read(rule_path).sub('> 0', '> 100'))
      application.close
      application = Mxrb::RubyApp::Application.new(target)
      expect(application.call_service('Compatibility.VerifyRule')).to eq('failed')
    ensure
      application&.close
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
