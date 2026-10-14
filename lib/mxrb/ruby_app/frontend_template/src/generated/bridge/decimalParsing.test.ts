import { describe, expect, it } from 'vitest';
import { decimal, decimalFunction } from './decimal';

// Values logged by the Mendix 11.12.1 Runtime (docs/evidence/decimal-edges-2026-10-14.json).
const parse = (...args: unknown[]) => decimalFunction('parseDecimal', args);

describe('parseDecimal with Java DecimalFormat patterns', () => {
  it.each([
    ['3,241.98', '#,###.##', '3241.98'],
    ['3241.98', '#,###.##', '3241.98'],
    ['1,2,3.5', '#,##0.00', '123.5'],
    ['12.5%', '0.0%', '0.125'],
    ['$1,234.50', '$#,##0.00', '1234.5'],
    ['12abc', '#,##0.00', '12'],
    ['-1,000.125', '#,##0.00', '-1000.125'],
    ['1.5E3', '0.###E0', '1500'],
    ['(5.00)', '#,##0.00;(#,##0.00)', '-5'],
    ['1 234,5', '#,##0.0', '1'],
    ['0.1234567890123456789', '0.0', '0.1234567890123456789'],
    ['1,000', '0', '1'],
    ['5.5', '', '5.5'],
    ['12.5‰', '0.0‰', '0.0125'],
    ['1.2.3', '0.0', '1.2'],
    ['123,456,789,012,345,678.987654321', '#,##0.###', '123456789012345678.987654321'],
    ['5 kg', '0 kg', '5'],
    ['42', '0.00', '42'],
  ])('parses %j with %j as the native Runtime', (text, pattern, expected) => {
    expect(parse(text, pattern)).toEqual(decimal(expected));
  });

  it('returns the default, or fails without one, when nothing parses', () => {
    expect(parse('1,234.50', '$#,##0.00', 7)).toEqual(decimal('7'));
    expect(parse('abc', '#,##0.00', decimal('5.05'))).toEqual(decimal('5.05'));
    expect(parse(' 12.5', '0.0', 9)).toEqual(decimal('9'));
    expect(parse('', '0.00', 3)).toEqual(decimal('3'));
    expect(parse('+5', '0', 1)).toEqual(decimal('1'));
    expect(parse('x', '0', null)).toBeNull();
    expect(parse('abc', 2.5)).toEqual(decimal('2.5'));
    expect(parse('3.45')).toEqual(decimal('3.45'));
    expect(() => parse('x', '0')).toThrow();
    expect(() => parse('x', '0', 'y')).toThrow(/unsupported decimal format/);
    expect(() => parse()).toThrow(/one to three/);
  });
});
