# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Mendix UTF-16 string positions' do
  let(:expression) { Mxrb::Runtime::Native::Expression.new }

  it 'finds code units with offsets, empty needles and no match' do
    {
      "find('😀abc😀', '😀', 1)" => 5,
      "find('abc', 'z')" => -1,
      "find('abc', 'a', 10)" => -1,
      "find('abc', '', 1)" => 1,
      "findLast('abc', '')" => 3,
      "findLast('abc', 'z')" => -1,
      "findLast('a', 'abc')" => -1,
      "findLast('', '')" => 0
    }.each { |source, expected| expect(expression.evaluate(source, {})).to eq(expected) }
  end

  it 'preserves complete surrogate pairs when slicing and rejects invalid ranges' do
    expect(expression.evaluate("substring('a😀b', 1, 2)", {})).to eq('😀')
    expect(expression.evaluate("substring('', 0)", {})).to eq('')
    expect { expression.evaluate("substring('abc', 1, -1)", {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /substring range/)
    expect { expression.evaluate("substring('abc', 9, 0)", {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /substring range/)
    expect { expression.evaluate("substring('😀', 0, 1)", {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /unsupported Mendix expression/)
  end
end
