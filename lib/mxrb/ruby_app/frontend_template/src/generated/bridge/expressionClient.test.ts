import { afterEach, describe, expect, it, vi } from 'vitest';
import type { ApplicationSchema, EntityRecord } from '../types';
import { decimal } from './decimal';
import { evaluate } from './expression';
import { registerExpressionSchema } from './schemaLookup';

const item: EntityRecord = { id: '9', type: 'Probe.Item', attributes: { Name: 'probe' } };
const row: EntityRecord = {
  id: '1',
  type: 'Probe.Special',
  attributes: { Name: 'North', Kind: 'Probe.Kind.Big', Size: 'Small', Row_Item: item, Tags: [item] },
};
const orphan: EntityRecord = { id: '2', type: 'Probe.Row', attributes: { Name: 'Lone', Kind: null, Row_Item: null } };
const variables = { row, orphan, item, copy: { ...item, attributes: {} }, text: 'x' };
const schema = {
  modules: [
    {
      name: 'Probe',
      models: [
        { name: 'Probe.Row', attributes: [{ name: 'Kind', type: 'enumeration', enumeration: 'Probe.Kind' }] },
        {
          name: 'Probe.Special',
          attributes: [{ name: 'Size', type: 'enumeration', enumeration: 'Probe.Size' }],
          generalization: { target: 'Probe.Row' },
        },
      ],
      enumerations: [
        {
          id: 'kind',
          name: 'Probe.Kind',
          values: [
            { name: 'Big', caption: 'Large thing', caption_translations: { pt_BR: 'Coisa grande' } },
            { name: 'Small', caption: 'Small one' },
          ],
        },
      ],
    },
  ],
} as unknown as ApplicationSchema;
const value = (source: string) => evaluate(source, null, variables, { timeZone: 'America/Manaus' });

describe('client expression functions', () => {
  afterEach(() => {
    registerExpressionSchema(null);
    document.documentElement.lang = '';
    vi.useRealTimers();
  });

  it('follows JavaScript string semantics and reads empty as blank', () => {
    expect(value("trim('  a b\t')")).toBe('a b');
    expect(value("toLowerCase('ÀB İ') + toUpperCase('straße')")).toBe('àb i̇STRASSE');
    expect(value("length('ab😀') + length($orphan/Kind)")).toBe(4);
    expect(value("substring('abcdef', 2) + substring('abcdef', 1, 3) + substring('abc', 5)")).toBe('cdefbcd');
    expect(value("substring('abc', -2) + substring('abc', 1, -1) + substring('abc', 1, 9)")).toBe('bcbc');
    expect(value("find('abcabc', 'c', 3) + findLast('abcabc', 'c') + findLast('abcabc', 'c', 4)")).toBe(12);
    expect(value("find($orphan/Kind, 'a')")).toBe(-1);
    expect(value("contains('Hello', 'ELL') or startsWith('Hello', 'He') and endsWith('Hello', 'lo')")).toBe(true);
    expect(value("startsWith($orphan/Kind, '')")).toBe(true);
    expect(value("replaceAll('a.b', '.', '$&') + replaceFirst('aaa', 'a', '$1') + replaceAll('ab', 'x*', '-')")).toBe(
      '$&$&$&$1aa-a-b-',
    );
    expect(value("isMatch('abc', 'b|abc') and not(isMatch('abc', 'b'))")).toBe(true);
    expect(value("urlEncode('a b&ç~*') + '|' + urlDecode('a+b%20%C3%A7')")).toBe('a%20b%26%C3%A7~*|a b ç');
    expect(() => value("isMatch('ABC', '(?i)abc')")).toThrow('Invalid regular expression');
    expect(() => value('trim(1)')).toThrow('String function requires a string');
    expect(() => value("substring('abc', 1.5)")).toThrow('Expected an integer');
    expect(() => value("trim('a', 'b')")).toThrow('trim expects 1 to 1 arguments');
  });

  it('concatenates text with empty values and numbers and compares objects by identity', () => {
    expect(value("'a' + 1 + '|' + 'b' + 1.5 + $orphan/Kind + empty")).toBe('a1|b1.5');
    expect(value("toString(1 + 2) + 'c'")).toBe('3c');
    expect(() => value("'a' + true")).toThrow('Only text and numbers can be concatenated');
    expect(value('$row/Probe.Row_Item = $item and $row/Probe.Row_Item != $orphan')).toBe(true);
    expect(value('$copy = $item and $orphan/Probe.Row_Item = empty and $row/Missing = empty')).toBe(true);
    expect(value("$row = $orphan or 'a' = empty")).toBe(false);
  });

  it('follows association paths through embedded objects', () => {
    expect(value('$row/Probe.Row_Item/Probe.Item/Name')).toBe('probe');
    expect(value('$row/Probe.Row_Item/Probe.Item')).toBe(item);
    expect(value('$orphan/Probe.Row_Item/Probe.Item/Name')).toBeNull();
    expect(value('$row/Probe.Tags/Probe.Item/Name')).toBeUndefined();
    expect(value('$text/Name')).toBeUndefined();
    expect(evaluate('$currentObject/Name', row)).toBe('North');
  });

  it('reads enumeration keys and translated captions from the schema', () => {
    registerExpressionSchema(schema);
    expect(value("getCaption($row/Kind) + '|' + getKey($row/Kind) + '|' + toString($row/Kind)")).toBe(
      'Large thing|Big|Big',
    );
    expect(value("getCaption(Probe.Kind.Small) + '|' + getCaption($row/Size) + '|' + getCaption('Plain')")).toBe(
      'Small one|Small|Plain',
    );
    expect(value("'[' + getCaption($orphan/Kind) + getKey($orphan/Kind) + ']'")).toBe('[]');
    expect(value('$row/Kind = Probe.Kind.Big')).toBe(true);
    expect(value('$row/Kind')).toBe('Big');
    document.documentElement.lang = 'pt-BR';
    expect(value('getCaption($row/Kind)')).toBe('Coisa grande');
    registerExpressionSchema(null);
    expect(value('getCaption($row/Kind)')).toBe('Probe.Kind.Big');
    expect(() => value('getCaption($row/Kind, 1)')).toThrow('getCaption requires one enumeration value');
  });

  it('resolves date tokens in the session time zone', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-03-31T03:30:15.250Z'));
    expect(value('[%CurrentDateTime%]')).toBe('2026-03-31T03:30:15.250Z');
    expect(value('[%BeginOfCurrentDay%]')).toBe('2026-03-30T04:00:00.000Z');
    expect(value('[%EndOfCurrentDay%]')).toBe('2026-03-31T03:59:59.999Z');
    expect(value('[%BeginOfCurrentDayUTC%]')).toBe('2026-03-31T00:00:00.000Z');
    expect(value('[%EndOfCurrentMonthUTC%]')).toBe('2026-03-31T23:59:59.999Z');
    expect(value('[%BeginOfCurrentHour%] < [%EndOfCurrentMinute%]')).toBe(true);
    expect(value('[%BeginOfCurrentYear%]')).toBe('2026-01-01T04:00:00.000Z');
    expect(value('[%BeginOfCurrentWeek%]')).toBe('2026-03-29T04:00:00.000Z');
    expect(value('[%EndOfCurrentWeek%]')).toBe('2026-04-05T03:59:59.999Z');
    expect(value('[%BeginOfCurrentWeekUTC%]')).toBe('2026-03-29T00:00:00.000Z');
    expect(value('[%BeginOfYesterday%]')).toBe('2026-03-29T04:00:00.000Z');
    expect(value('[%EndOfTomorrow%]')).toBe('2026-04-01T03:59:59.999Z');
    expect(value('[%EndOfYesterdayUTC%]')).toBe('2026-03-30T23:59:59.999Z');
    expect(() => value('[%BeginOfCurrentDecade%]')).toThrow('Unsupported token');
    expect(() => value('[%CurrentUser%]')).toThrow('Unsupported token');
  });
});
