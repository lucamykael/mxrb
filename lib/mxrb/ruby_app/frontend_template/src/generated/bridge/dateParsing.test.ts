import { afterEach, describe, expect, it, vi } from 'vitest';
import { evaluate } from './expression';
import { clientFunction } from './clientFunctions';

const parseDateTimeUTC = (args: unknown[]) => clientFunction('parseDateTimeUTC', args);

const cases = [
  {
    name: 'Standard',
    input: '2026-01-02 03:04:05',
    format: 'yyyy-MM-dd HH:mm:ss',
    expected: '1767323045000',
    client_expected: '1767323045000',
  },
  {
    name: 'Quoted',
    input: '2026-01-02T03:04:05.123',
    format: "yyyy-MM-dd'T'HH:mm:ss.SSS",
    expected: '1767323045123',
    client_expected: '1767323045123',
  },
  {
    name: 'DateOnly',
    input: '2/1/2026',
    format: 'dd/MM/yyyy',
    expected: '1767312000000',
    client_expected: '1767312000000',
  },
  {
    name: 'Compact',
    input: '20260102',
    format: 'yyyyMMdd',
    expected: '1767312000000',
    client_expected: '1767312000000',
  },
  {
    name: 'OverflowDay',
    input: '35-11-2015',
    format: 'dd-MM-yyyy',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'OverflowMonth',
    input: '2024-13-01',
    format: 'yyyy-MM-dd',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'LeapOverflow',
    input: '2023-02-29',
    format: 'yyyy-MM-dd',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'OverflowTime',
    input: '2024-01-01 25:61:62',
    format: 'yyyy-MM-dd HH:mm:ss',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'ShortMillis',
    input: '2024-01-01 00:00:00.1',
    format: 'yyyy-MM-dd HH:mm:ss.SSS',
    expected: '1704067200001',
    client_expected: '1704067200001',
  },
  {
    name: 'LongMillis',
    input: '2024-01-01 00:00:00.1234',
    format: 'yyyy-MM-dd HH:mm:ss.SSS',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'Trailing',
    input: '2024-01-02 trailing',
    format: 'yyyy-MM-dd',
    expected: '1704153600000',
    client_expected: '946684800000',
  },
  {
    name: 'LeadingSpace',
    input: ' 2024-01-02',
    format: 'yyyy-MM-dd',
    expected: '1704153600000',
    client_expected: '1704153600000',
  },
  {
    name: 'NegativeDay',
    input: '2024-01--1',
    format: 'yyyy-MM-dd',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'TimeOnly',
    input: '12:34:56',
    format: 'HH:mm:ss',
    expected: '45296000',
    client_uses_current_date: true,
  },
  {
    name: 'NotDate',
    input: 'invalid',
    format: 'yyyy-MM-dd',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'EmptyInput',
    input: '',
    format: 'yyyy-MM-dd',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'WrongDelimiter',
    input: '2024/01/02',
    format: 'yyyy-MM-dd',
    expected: '946684800000',
    client_expected: '946684800000',
  },
  {
    name: 'OffsetColon',
    input: '2024-01-02T03:04:05+02:30',
    format: "yyyy-MM-dd'T'HH:mm:ssXXX",
    expected: '1704155645000',
    client_expected: '946684800000',
  },
  {
    name: 'OffsetCompact',
    input: '2024-01-02T03:04:05-0230',
    format: "yyyy-MM-dd'T'HH:mm:ssZ",
    expected: '1704173645000',
    client_expected: '946684800000',
  },
  {
    name: 'Zulu',
    input: '2024-01-02T03:04:05Z',
    format: "yyyy-MM-dd'T'HH:mm:ssX",
    expected: '1704164645000',
    client_expected: '946684800000',
  },
];
const literal = (value: string) => "'" + value.replace(/'/g, "''") + "'";
afterEach(() => vi.useRealTimers());

describe('native UTC date parsing', () => {
  it('matches native nanoflow parsing, including its differences from microflows', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-07T08:00:00Z'));
    for (const item of cases) {
      const source =
        'dateTimeToEpoch(parseDateTimeUTC(' +
        literal(item.input) +
        ', ' +
        literal(item.format) +
        ', dateTimeUTC(2000)))';
      const expected = item.client_uses_current_date
        ? Date.UTC(2026, 9, 7, 12, 34, 56)
        : Number(item.client_expected);
      expect(evaluate(source, null, {}, { timeZone: 'America/New_York' }), item.name).toBe(
        expected,
      );
    }
  });
  it('throws without a fallback and preserves an explicit empty fallback', () => {
    expect(() => parseDateTimeUTC(['bad', 'yyyy-MM-dd'])).toThrow('Unparseable date: "bad"');
    expect(parseDateTimeUTC(['bad', 'yyyy-MM-dd', null])).toBeNull();
    expect(() => parseDateTimeUTC(['bad', 'yyyy-MM-dd', 42])).toThrow('date fallback');
  });
  it('rejects arguments that are not text', () => {
    for (const args of [[], ['date'], [null, 'yyyy'], ['2024', null]])
      expect(() => parseDateTimeUTC(args)).toThrow('expects a text and a pattern');
  });
  it('preserves literal quotes and validates calendar components', () => {
    expect(parseDateTimeUTC(["2024 o'clock 12", "yyyy 'o''clock' HH"])).toBe(
      '2024-01-01T12:00:00.000Z',
    );
    expect(parseDateTimeUTC(["2024'01", "yyyy''MM"])).toBe('2024-01-01T00:00:00.000Z');
    expect(parseDateTimeUTC(['1799-01-01', 'yyyy-MM-dd'])).toBe('1799-01-01T00:00:00.000Z');
    for (const source of ['2024-00-01', '2024-01-00', '2024-02-30', '10000-01-01'])
      expect(parseDateTimeUTC([source, 'yyyy-MM-dd', null])).toBeNull();
  });
});
