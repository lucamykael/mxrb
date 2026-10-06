import { describe, expect, it } from 'vitest';
import { decimal, decimalNumber } from './decimal';
import { evaluate } from './expression';
import { displayValue, draftValue, sortRecords } from './value';
import { matchesGridFilter } from './components/DataGrid';
import { NanoflowRuntime } from './nanoflow';

describe('decimal transport and expressions', () => {
  it('retains typed decimals through nanoflow parameters, arithmetic and results', () => {
    const runtime = new NanoflowRuntime(
      { Amount: decimal('0.1') },
      {
        name: 'App.Decimal',
        id: 'decimal',
        parameters: [],
      },
    );
    expect(runtime.value('$Amount + 0.2')).toEqual(decimal('0.3'));
    expect(runtime.condition('$Amount + 0.2 = 0.3')).toBe(true);
    expect(runtime.string('$Amount + 0.2')).toBe('0.3');
    expect(runtime.complete(runtime.value('$Amount + 0.2')).result).toEqual(decimal('0.3'));
  });
  it('keeps input digits, arithmetic and JSON exact', () => {
    const value = decimal('9007199254740993.12345678');
    expect(decimalNumber(JSON.parse(JSON.stringify(value))).toFixed()).toBe(
      '9007199254740993.12345678',
    );
    expect(evaluate('toString(0.1 + 0.2)', null)).toBe('0.3');
    expect(evaluate('toString(9007199254740993.00000001 + 0.00000001)', null)).toBe(
      '9007199254740993.00000002',
    );
    expect(evaluate('toString(3 : 7)', null)).toBe('0.42857142857142857142857142857142857143');
    expect(evaluate('ceil((3 : 7) * 7)', null)).toBe(4);
    expect(evaluate('round(-2.5)', null)).toBe(-3);
    expect(evaluate('round(88.725, 2)', null)).toEqual(decimal('88.73'));
    expect(evaluate('round(1250, -2)', null)).toEqual(decimal('1300'));
    expect(evaluate('floor(-1.2)', null)).toBe(-2);
    expect(evaluate('12.5 mod 2', null)).toEqual(decimal('0.5'));
    expect(evaluate("parseDecimal('no', empty)", null)).toBeNull();
    expect(evaluate("parseDecimal('no', 1.25)", null)).toEqual(decimal('1.25'));
    expect(evaluate('0.1 + 0.2 = 0.3', null)).toBe(true);
    expect(evaluate('0.10000000000000000001 > 0.1', null)).toBe(true);
    expect(() => decimal('NaN')).toThrow();
  });

  it('displays, sorts and filters digits beyond binary float precision', () => {
    const a = decimal('9007199254740993.00000001');
    const b = decimal('9007199254740993.00000002');
    expect(displayValue(a)).toBe(a.__mxrb_decimal);
    expect(draftValue(a)).toBe(a.__mxrb_decimal);
    const records = [b, a].map((Amount, index) => ({
      id: String(index),
      type: 'App.Item',
      attributes: { Amount },
    }));
    expect(sortRecords(records, [{ attribute: 'Amount' }]).map((record) => record.id)).toEqual([
      '1',
      '0',
    ]);
    expect(
      matchesGridFilter(b, a.__mxrb_decimal, { type: 'number', operator: 'gt', options: [] }),
    ).toBe(true);
    expect(
      matchesGridFilter(b, a.__mxrb_decimal, { type: 'number', operator: 'equals', options: [] }),
    ).toBe(false);
  });
});
