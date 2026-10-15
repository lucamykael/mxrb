# frozen_string_literal: true

require 'spec_helper'

# Expectations recorded from java.util.regex by script/java_regex_oracle.
RSpec.describe Mxrb::Runtime::JavaRegex do
  let(:cases) { JSON.parse(File.read('spec/fixtures/java_regex/cases.json')) }
  let(:expected) { JSON.parse(File.read('spec/fixtures/java_regex/expected.json')) }
  # Java constructs with no faithful Ruby reading fail instead of matching otherwise.
  let(:unsupported) { ['\p{javaLowerCase}', '(?U)\w'] }
  # Java block aliases with no Ruby block name, such as InGreek for Greek and Coptic.
  let(:unknown) { ['\p{InGreek}+'] }

  it 'matches and replaces as java.util.regex does' do
    cases.each_with_index do |(pattern, input), index|
      result = expected.fetch(index.to_s)
      if unsupported.include?(pattern)
        expect { described_class.regexp(pattern) }.to raise_error(ArgumentError, /not supported/)
      elsif unknown.include?(pattern) || result == 'error'
        expect { described_class.regexp(pattern) }.to raise_error(ArgumentError, /invalid regular expression/)
      else
        actual = [described_class.matches?(pattern, input), input.gsub(described_class.regexp(pattern)) { '#' }]
        expect(actual).to eq(result), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it 'rejects what it cannot read' do
    expect { described_class.translate('a\\') }.to raise_error(ArgumentError, /end with a backslash/)
    expect { described_class.translate('\\x{41') }.to raise_error(ArgumentError, /unterminated/)
    expect { described_class.translate('\\p{L') }.to raise_error(ArgumentError, /unterminated/)
    expect { described_class.translate('[\\H]') }.to raise_error(ArgumentError, /negated/)
    expect(described_class.translate('(?-i)a(?is-x:b)\\xff\\pL\\Q')).to eq('(?-i)a(?i-x:b)\\xff\\p{L}')
  end
end
