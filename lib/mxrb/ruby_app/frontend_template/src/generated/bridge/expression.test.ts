import { afterEach, describe, expect, it } from 'vitest';
import { decimal } from './decimal';
import { evaluate, evaluateCondition, registerClientConstants } from './expression';
import { editable, matchesCondition } from './components/FieldPolicy';
import type { EntityRecord } from '../types';

const record: EntityRecord = {
  id: '1',
  type: 'App.Item',
  attributes: { Active: true, Amount: 12, Name: 'and or >', Status: 'Ready' },
};

describe('presentation expressions', () => {
  afterEach(() => registerClientConstants({}));
  it('resolves exposed constants with typed values and replaces stale registrations', () => {
    const values = { 'App.Key': 'storage-key', 'App.Enabled': false, 'App.Amount': decimal('9007199254740993.125') };
    registerClientConstants(values);
    values['App.Key'] = 'changed outside runtime';
    expect(evaluate("@App.Key + ':value'", null)).toBe('storage-key:value');
    expect(evaluateCondition('not(@App.Enabled)', null)).toBe(true);
    expect(evaluate('@App.Amount + 0.125', null)).toEqual(decimal('9007199254740993.25'));
    expect(() => evaluate('@App.Private', null)).toThrow('Client constant is unavailable: App.Private');
    expect(evaluate("'@App.Private'", null)).toBe('@App.Private');
    registerClientConstants({});
    expect(() => evaluate('@App.Key', null)).toThrow('Client constant is unavailable');
  });
  it('combines exact module roles with expressions and rejects unknown conditions', () => {
    const condition = { roles: ['App.Editor'], expression: '$currentObject/Active' };
    expect(matchesCondition(condition, record, ['App.Editor'])).toBe(true);
    expect(matchesCondition(condition, record, ['Other.Editor'])).toBe(false);
    expect(
      matchesCondition(condition, { ...record, attributes: { Active: false } }, ['App.Editor']),
    ).toBe(false);
    expect(matchesCondition({ roles: ['App.Editor'] }, null, ['App.Editor'])).toBe(true);
    expect(matchesCondition({ roles: ['App.Editor'] }, null)).toBe(false);
    expect(matchesCondition({ roles: ['App.Editor'], ignore_security: true }, null)).toBe(true);
    for (const invalid of [
      { roles: 'App.Editor' },
      { roles: [true] },
      { ignore_security: 'true' },
      { expression: true },
      { roles: [], extra: true },
    ])
      expect(matchesCondition(invalid, record, ['App.Editor'])).toBe(false);
    expect(
      editable({ editable: 'conditional', editability: condition }, record, ['App.Editor']),
    ).toBe(true);
  });

  it('compares qualified and bare enum members without conflating different enum types', () => {
    for (const status of ['Ready', 'App.Status.Ready']) {
      const current = { ...record, attributes: { Status: status } };
      expect(evaluateCondition('$currentObject/Status = App.Status.Ready', current)).toBe(true);
      expect(evaluateCondition('App.Status.Ready != $currentObject/Status', current)).toBe(false);
    }
    expect(evaluateCondition('Other.Status.Ready = App.Status.Ready', record)).toBe(false);
    expect(evaluateCondition("'Other.Status.Ready' = App.Status.Ready", record)).toBe(false);
    expect(evaluateCondition('App.Status.Ready = App.Status.Ready', record)).toBe(true);
    expect(evaluate('App.Status.Ready', record)).toBe('Ready');
    expect(evaluate('toString(App.Status.Ready)', record)).toBe('Ready');
  });
  it('preserves grouping, precedence, numeric types, and quoted operators', () => {
    expect(evaluateCondition('($currentObject/Amount = 12 or false) and not(false)', record)).toBe(
      true,
    );
    expect(evaluateCondition("$currentObject/Name = 'and or >'", record)).toBe(true);
    expect(evaluateCondition('false and true or true', record)).toBe(true);
    expect(evaluateCondition('$currentObject/Status = App.Status.Ready', record)).toBe(true);
    expect(evaluate('toString(2 + 3 * 4)', record)).toBe('14');
    expect(evaluate("'it''s' + ' editable'", record)).toBe("it's editable");
    expect(evaluate('-12 div 5', record)).toEqual(decimal('-2.4'));
    expect(evaluate('12 mod 5', record)).toBe(2);
    expect(evaluate('$Item', record, { Item: null })).toBeNull();
  });

  it('evaluates conditional branches lazily and preserves decimal division', () => {
    expect(evaluate('if true then 3 div 5 else 1 div 0', record)).toEqual(decimal('0.6'));
    expect(evaluate('if false then 1 div 0 else 12 : 5', record)).toEqual(decimal('2.4'));
    expect(evaluate('if true then if false then 1 else 2 else 3', record)).toBe(2);
    expect(evaluate('2 + (if false then 4 else 6) * 3', record)).toBe(20);
    expect(evaluate('false and 1 div 0 = 0', record)).toBe(false);
    expect(evaluate('true or 1 div 0 = 0', record)).toBe(true);
    expect(evaluate('-12 mod 5', record)).toBe(-2);
    for (const invalid of [
      'if 1 then 2 else 3',
      'if true 2 else 3',
      'if true then 2',
      'if true then 2 else (3',
      '4 / 2',
    ])
      expect(() => evaluate(invalid, record)).toThrow();
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
