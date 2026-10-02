import { describe, expect, it } from 'vitest';
import { evaluate, evaluateCondition } from './expression';
import { editable } from './components/FieldPolicy';
import type { EntityRecord } from '../types';

const record: EntityRecord = {
  id: '1',
  type: 'App.Item',
  attributes: { Active: true, Amount: 12, Name: 'and or >', Status: 'Ready' },
};

describe('presentation expressions', () => {
  it('preserves grouping, precedence, numeric types, and quoted operators', () => {
    expect(evaluateCondition('($currentObject/Amount = 12 or false) and not(false)', record)).toBe(
      true,
    );
    expect(evaluateCondition("$currentObject/Name = 'and or >'", record)).toBe(true);
    expect(evaluateCondition('false and true or true', record)).toBe(true);
    expect(evaluateCondition('$currentObject/Status = App.Status.Ready', record)).toBe(true);
    expect(evaluate('toString(2 + 3 * 4)', record)).toBe('14');
    expect(evaluate("'it''s' + ' editable'", record)).toBe("it's editable");
    expect(evaluate('-12 div 5', record)).toBe(-2);
    expect(evaluate('12 mod 5', record)).toBe(2);
    expect(evaluate('$Item', record, { Item: null })).toBeNull();
  });

  it('rejects unsupported syntax and nonboolean conditions without evaluating code', () => {
    for (const source of [
      'unknown',
      'true trailing',
      '(true',
      '1',
      "'true'",
      '1 = 1; alert(1)',
      'toString(false)',
      '$currentObject/Missing',
    ]) {
      expect(() => evaluateCondition(source, record)).toThrow();
      expect(
        editable({ editable: 'conditional', editability: { expression: source } }, record),
      ).toBe(false);
    }
    expect(() => evaluate('1 div 0', record)).toThrow('Division by zero');
  });

  it('does not turn opaque or missing editability into permission to edit', () => {
    expect(
      editable(
        { editable: 'conditional', editability: { expression: '$currentObject/Active' } },
        record,
      ),
    ).toBe(true);
    expect(
      editable(
        {
          editable: 'conditional',
          editability: { expression: 'true', unknown_native: { Future: true } },
        },
        record,
      ),
    ).toBe(false);
    expect(editable({ editable: 'conditional' }, record)).toBe(false);
    expect(editable({ editable: 'never' }, record)).toBe(false);
    expect(editable({ editable: 'always', read_only: true }, record)).toBe(false);
  });
});
