import { describe, expect, it } from 'vitest';
import { evaluate } from './expression';

const run = (source: string, timeZone = 'UTC') => evaluate(source, null, {}, { timeZone });

describe('calendar expressions', () => {
  it('clamps months and leap years without losing milliseconds', () => {
    expect(run('addMonthsUTC(dateTimeUTC(2024, 1, 31, 12), 1)')).toBe('2024-02-29T12:00:00.000Z');
    expect(run('addYearsUTC(dateTimeUTC(2024, 2, 29), 1)')).toBe('2025-02-28T00:00:00.000Z');
    expect(run('subtractQuartersUTC(dateTimeUTC(2024, 5, 31), 1)')).toBe(
      '2024-02-29T00:00:00.000Z',
    );
    expect(run('addWeeksUTC(dateTimeUTC(2024, 12, 25), 1)')).toBe('2025-01-01T00:00:00.000Z');
    expect(
      run(
        'subtractMilliseconds(addMonthsUTC(addMilliseconds(dateTimeUTC(2024, 1, 31), 123), 1), 1)',
      ),
    ).toBe('2024-02-29T00:00:00.122Z');
  });

  it('preserves local calendar days across DST and distinguishes elapsed hours', () => {
    const zone = 'America/New_York';
    expect(run('addDays(dateTime(2024, 3, 9, 12), 1)', zone)).toBe('2024-03-10T16:00:00.000Z');
    expect(run('addHours(dateTime(2024, 3, 9, 12), 24)', zone)).toBe('2024-03-10T17:00:00.000Z');
    expect(run('addDaysUTC(dateTime(2024, 3, 9, 12), 1)', zone)).toBe('2024-03-10T17:00:00.000Z');
    expect(run('subtractDays(dateTime(2024, 11, 3, 12), 1)', zone)).toBe(
      '2024-11-02T16:00:00.000Z',
    );
    expect(run('dateTime(2024, 11, 3, 1, 30)', zone)).toBe('2024-11-03T06:30:00.000Z');
    expect(run('addDays(dateTime(2024, 11, 2, 1, 30), 1)', zone)).toBe('2024-11-03T05:30:00.000Z');
    expect(run('addDays(dateTime(2024, 3, 9, 2, 30), 1)', zone)).toBe('2024-03-10T06:30:00.000Z');
  });

  it('resolves half-hour and skipped-day transitions', () => {
    expect(run('dateTime(2024, 10, 6, 2, 15)', 'Australia/Lord_Howe')).toBe(
      '2024-10-05T15:45:00.000Z',
    );
    expect(run('dateTime(2011, 12, 30, 12)', 'Pacific/Apia')).toBe('2011-12-30T22:00:00.000Z');
    expect(run('addDays(dateTime(2024, 10, 5, 2, 15), 1)', 'Australia/Lord_Howe')).toBe(
      '2024-10-05T15:15:00.000Z',
    );
    expect(run('addDays(dateTime(2011, 12, 29, 12), 1)', 'Pacific/Apia')).toBe(
      '2011-12-30T22:00:00.000Z',
    );
    expect(run('subtractDays(dateTime(2024, 3, 11, 2, 30), 1)', 'America/New_York')).toBe(
      '2024-03-10T07:30:00.000Z',
    );
    expect(run('addMonths(dateTime(2024, 2, 10, 2, 30), 1)', 'America/New_York')).toBe(
      '2024-03-10T07:30:00.000Z',
    );
    expect(run('addMonths(dateTime(2024, 10, 3, 1, 30), 1)', 'America/New_York')).toBe(
      '2024-11-03T06:30:00.000Z',
    );
  });

  it('trims using the selected zone and roundtrips negative epoch milliseconds', () => {
    const source = 'addMilliseconds(dateTimeUTC(2024, 11, 3, 5, 45, 30), 123)';
    const expected = {
      Seconds: '2024-11-03T06:45:30.000Z',
      Minutes: '2024-11-03T06:45:00.000Z',
      Hours: '2024-11-03T06:00:00.000Z',
      Days: '2024-11-03T04:00:00.000Z',
      Months: '2024-11-01T04:00:00.000Z',
      Years: '2024-01-01T05:00:00.000Z',
    };
    for (const [unit, value] of Object.entries(expected))
      expect(run(`trimTo${unit}(${source})`, 'America/New_York')).toBe(value);
    expect(run(`trimToDaysUTC(${source})`, 'America/New_York')).toBe('2024-11-03T00:00:00.000Z');
    expect(run('dateTimeToEpoch(epochToDateTime(-123))')).toBe(-123);
  });

  it('rejects invalid inputs and evaluates date expressions lazily', () => {
    for (const source of [
      'dateTimeUTC()',
      'dateTimeUTC(2024, 1, 1, 0, 0, 0, 0)',
      'dateTimeUTC(2023, 2, 29)',
      'dateTimeUTC(1799)',
      'dateTimeUTC(2024, 1, 1, 24)',
      "dateTimeUTC('2024')",
      'epochToDateTime(1.5)',
      'addDays(empty, 1)',
      'trimToDays()',
      'dateTimeToEpoch()',
      'epochToDateTime()',
      'addDays(dateTimeUTC(2024))',
    ])
      expect(() => run(source)).toThrow();
    expect(() => run('dateTime(2024)', 'invalid-zone')).toThrow();
    expect(run('if true then dateTimeUTC(2024) else dateTimeUTC(2023, 2, 29)')).toBe(
      '2024-01-01T00:00:00.000Z',
    );
  });
});
