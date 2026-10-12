import Decimal from 'decimal.js';
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { clientFunction, clientNumberText, clientToken, isClientFunction } from './clientFunctions';
import { dateLocale, defaultPattern, formatJavaPattern, parseJavaPattern } from './dateFormatting';
import { decimal, quotient } from './decimal';
import { evaluate } from './expression';

// Values measured in the Mendix 11.12.1 client (spec/fixtures/native_nanoflow_functions)
// with the browser in America/New_York.
const zone = process.env.TZ;
beforeAll(() => {
  process.env.TZ = 'America/New_York';
});
afterAll(() => {
  process.env.TZ = zone;
});
afterEach(() => {
  vi.useRealTimers();
  document.documentElement.lang = '';
});

const day = 'dateTime(2024, 3, 5, 14, 7, 9)';
const morning = 'dateTime(2024, 3, 5, 9, 4, 0)';
const value = (source: string) => evaluate(source, null);

describe('client date formatting', () => {
  it('rewrites Java patterns like the Mendix client', () => {
    expect(value(`formatDateTime(${day}, 'yyyy-MM-dd HH:mm:ss')`)).toBe('2024-03-05 14:07:09');
    expect(value(`formatDateTime(${day}, 'EEE, d MMM yy h:mm a')`)).toBe('Tue, 5 Mar 24 2:07 PM');
    expect(value(`formatDateTime(${morning}, 'EEEE MMMM d, y hh:mm a')`)).toBe(
      'Tuesday March 5, 2024 09:04 AM',
    );
    expect(value(`formatDateTime(${day}, 'D w W E u F')`)).toBe('65 10 W Tue 2 F');
    expect(value(`formatDateTime(${day}, 'uu')`)).toBe('02');
    expect(value(`formatDateTime(dateTime(2024, 3, 5, 0, 30, 0), 'k K H h a')`)).toBe('24 0 0 12 AM');
    expect(value(`formatDateTime(addMilliseconds(${day}, 5), 'S SS SSS SSSS')`)).toBe(
      '005 005 005 0005',
    );
    expect(value(`formatDateTime(${day}, '''at'' HH ''o''''clock''')`)).toBe("at 14 o'clock");
    expect(value(`formatDateTime(${day}, 'z|Z|X|XXX|G yyy YYYY MMMMM EEEEEE')`)).toBe(
      'z|Z|X|XXX|AD 2024 2024 March Tuesday',
    );
    expect(value(`formatDateTime(dateTime(2023, 1, 1, 12), 'w ww Y YY D DDD u')`)).toBe(
      '1 01 2023 23 1 001 7',
    );
    expect(() => value(`formatDateTime(${day}, 'Q|A')`)).toThrow('unescaped latin alphabet');
  });

  it('uses the short styles of the session language as defaults', () => {
    expect(value(`formatDateTime(${day})`)).toBe('3/5/24, 2:07 PM');
    expect(value(`formatDateTimeUTC(${day}, 'yyyy-MM-dd HH:mm z')`)).toBe('2024-03-05 19:07 z');
    expect(value(`formatDateTimeUTC(${day})`)).toBe('3/5/24, 7:07 PM');
    expect(value(`formatDate(${day}) + '|' + formatTime(${day})`)).toBe('3/5/24|2:07 PM');
    expect(value(`formatDateUTC(${day}) + '|' + formatTimeUTC(${day})`)).toBe('3/5/24|7:07 PM');
    expect(value(`toString(${day})`)).toBe('3/5/2024, 2:07 PM');
    expect(() => value("formatDateTime($when, 'yyyy')")).toThrow('expects a date');
    expect(() => clientFunction('formatDate', ['2024-03-05T19:07:09.000Z', 'x'])).toThrow(
      'expects one date',
    );
  });

  it('builds the locale, week rules and defaults of other languages', () => {
    document.documentElement.lang = 'de-DE';
    expect(dateLocale().options?.weekStartsOn).toBe(1);
    expect(dateLocale().options?.firstWeekContainsDate).toBe(4);
    expect(defaultPattern('datetime')).toBe('dd.MM.yy, HH:mm');
    expect(defaultPattern('date', true)).toBe('dd.MM.yyyy');
    const date = new Date(2024, 2, 5, 14, 7, 9);
    expect(formatJavaPattern(date, 'EEEE d. MMMM yyyy G a')).toBe('Dienstag 5. März 2024 n. Chr. PM');
    expect(formatJavaPattern(date, 'LLLL MMM EEE aaaaa')).toBe('März März Di. PM');
    expect(parseJavaPattern('dienstag, 5. märz 2024', 'EEEE, d. MMMM yyyy')?.getMonth()).toBe(2);
    expect(parseJavaPattern('5 März 2024 n. Chr.', 'd MMM yyyy G')?.getDate()).toBe(5);
    expect(parseJavaPattern('Di 5 März 24 nachm', 'EEE d LLLL yy a')).toBeUndefined();
    expect(parseJavaPattern('5 Foo 2024', 'd MMM yyyy')).toBeUndefined();
    expect(parseJavaPattern('Xy 5 März 2024', 'EEE d MMMM yyyy')).toBeUndefined();
    document.documentElement.lang = 'pt-BR';
    expect(parseJavaPattern('5 mar. 2024 PM', 'd MMM yyyy a')?.getFullYear()).toBe(2024);
    expect(defaultPattern('time')).toBe('HH:mm');
    document.documentElement.lang = 'th-TH';
    expect(formatJavaPattern(date, 'yyyy yy YYYY YY')).toBe('2567 67 2567 67');
    expect(parseJavaPattern('2567-03-05', 'yyyy-MM-dd')?.getFullYear()).toBe(2024);
    expect(parseJavaPattern('05 y', "dd 'y'")?.getFullYear()).toBe(new Date().getFullYear());
    document.documentElement.lang = 'xx-invalid-tag-!';
    expect(dateLocale().options?.weekStartsOn).toBe(0);
    document.documentElement.lang = 'ko-KR';
    expect(defaultPattern('time')).toContain('a');
  });
});

describe('client date parsing', () => {
  it('parses with date-fns and the two-digit-year and space fallbacks', () => {
    const utc = (source: string) => value(`formatDateTimeUTC(${source}, 'yyyy-MM-dd HH:mm:ss.SSS')`);
    expect(utc("parseDateTime('2024-03-05 14:07', 'yyyy-MM-dd HH:mm')")).toBe('2024-03-05 19:07:00.000');
    expect(utc("parseDateTime('2024-03-10 02:30', 'yyyy-MM-dd HH:mm')")).toBe('2024-03-10 07:30:00.000');
    expect(utc("parseDateTime('tue, 5 MAR 2024 2:07 pm', 'EEE, d MMM yyyy h:mm a')")).toBe(
      '2024-03-05 19:07:00.000',
    );
    expect(utc("parseDateTime('99', 'yy')")).toBe('1999-01-01 05:00:00.000');
    expect(utc("parseDateTimeUTC('1799-01-01', 'yyyy-MM-dd')")).toBe('1799-01-01 00:00:00.000');
    expect(utc("parseDateTime(' 2 ', 'u')")).not.toBeNull();
    expect(utc("parseDateTime('bad', 'yyyy', dateTime(2000))")).toBe('2000-01-01 05:00:00.000');
    expect(parseJavaPattern('3/5/24, 2:07 PM', 'M/d/yy, h:mm\u202fa')?.getHours()).toBe(14);
    expect(value("parseDateTime('bad', 'yyyy', empty)")).toBeNull();
    expect(() => value("parseDateTime('bad', 'yyyy')")).toThrow('Unparseable date: "bad"');
    expect(() => value("parseDateTime('2024-02-30', 'yyyy-MM-dd')")).toThrow('Unparseable');
    expect(() => value("parseDateTime('bad', 'yyyy', 1)")).toThrow('date fallback');
    expect(() => clientFunction('parseDateTime', [1, 'yyyy'])).toThrow('expects a text');
  });
});

describe('client numeric functions', () => {
  it('follows big.js for parsing, extremes, powers and roots', () => {
    expect(value("toString(parseInteger('42')) + '|' + toString(parseInteger('-0'))")).toBe('42|0');
    expect(value("parseInteger('99999999999999999999')")).toEqual(decimal('99999999999999999999'));
    expect(value("parseInteger(' 7', 1)")).toBe(1);
    expect(() => value("parseInteger('4.5')")).toThrow('Not parsable to Integer: 4.5');
    expect(() => clientFunction('parseInteger', [1])).toThrow('expects a string');
    expect(value('max(1, 5, 3)')).toBe(5);
    expect(value('min(4, 2.5)')).toEqual(decimal('2.5'));
    expect(value('min(3, 3.0)')).toBe(3);
    expect(value(`max(${morning}, ${day})`)).toBe('2024-03-05T19:07:09.000Z');
    expect(value(`min(${morning}, ${day})`)).toBe('2024-03-05T14:04:00.000Z');
    expect(() => clientFunction('max', [])).toThrow('requires arguments');
    expect(() => clientFunction('max', [1, 'x'])).toThrow('numbers or dates');
    expect(value('toString(pow(2, 10)) + toString(pow(2, -1)) + toString(pow(10, 30))')).toBe(
      '10240.51e+30',
    );
    expect(value('toString(pow(2, 0.5))')).toBe('1.4142135623730951');
    expect(() => clientFunction('pow', ['2', 1])).toThrow('expects numbers');
    expect(value('toString(sqrt(2)) + toString(sqrt(16))')).toBe('1.41421356237309504884');
    expect(() => value('sqrt(-1)')).toThrow('Operator sqrt not supported');
    const random = value('random()');
    expect(new Decimal((random as { __mxrb_decimal: string }).__mxrb_decimal).lt(1)).toBe(true);
    expect(value("toString(0.0000001) + '|' + toString(1 : 3)")).toBe('1e-7|0.33333333333333333333');
    expect(clientNumberText(decimal('2.50'))).toBe('2.5');
  });

  it('rounds quotients to 20 places exactly', () => {
    expect(quotient(new Decimal(1), new Decimal('3e20')).toFixed()).toBe('0');
    expect(quotient(new Decimal(5), new Decimal('1e21')).toFixed()).toBe('0.00000000000000000001');
    expect(quotient(new Decimal(-5), new Decimal('1e21')).toFixed()).toBe('-0.00000000000000000001');
    expect(quotient(new Decimal(3), new Decimal('-2e20')).toFixed()).toBe('-0.00000000000000000002');
    expect(quotient(new Decimal('2.5'), new Decimal('1e20')).toFixed()).toBe('0.00000000000000000003');
    expect(() => quotient(new Decimal(1), new Decimal(0))).toThrow('Division by zero');
  });

  it('measures date distances like the client', () => {
    expect(value(`toString(daysBetween(${morning}, ${day}))`)).toBe('0.21052083333333333333');
    expect(value(`toString(hoursBetween(${day}, ${morning}))`)).toBe('5.0525');
    expect(value(`toString(minutesBetween(${morning}, ${day}))`)).toBe('303.15');
    expect(value(`toString(secondsBetween(${morning}, ${day}))`)).toBe('18189');
    expect(value(`toString(millisecondsBetween(${morning}, ${day}))`)).toBe('18189000');
    expect(value(`toString(weeksBetween(dateTime(2024, 1, 1), ${day}))`)).toBe('9.2268998015873015873');
    expect(value('toString(hoursBetween(dateTime(2024, 3, 9), dateTime(2024, 3, 11)))')).toBe('47');
    expect(value(`calendarMonthsBetween(${day}, dateTime(2024, 1, 31))`)).toBe(2);
    expect(value(`calendarYearsBetween(dateTime(2020, 6, 1), ${day})`)).toBe(4);
    expect(() => value(`daysBetween(${day}, 'x')`)).toThrow('expects a date');
    expect(isClientFunction('FormatDateTimeUTC')).toBe(true);
    expect(isClientFunction('formatDecimal')).toBe(false);
  });
});

describe('client date tokens', () => {
  it('resolves week, yesterday and tomorrow tokens', () => {
    const now = new Date('2026-03-31T03:30:15.250Z');
    expect(clientToken('BeginOfCurrentWeek', now)).toBe('2026-03-29T04:00:00.000Z');
    expect(clientToken('EndOfCurrentWeekUTC', now)).toBe('2026-04-04T23:59:59.999Z');
    expect(clientToken('BeginOfYesterday', now)).toBe('2026-03-29T04:00:00.000Z');
    expect(clientToken('EndOfTomorrow', now)).toBe('2026-04-01T03:59:59.999Z');
    expect(clientToken('BeginOfTomorrowUTC', now)).toBe('2026-04-01T00:00:00.000Z');
    expect(clientToken('CurrentDecade', now)).toBeUndefined();
    vi.useFakeTimers();
    vi.setSystemTime(now);
    expect(value('[%EndOfYesterday%]')).toBe('2026-03-30T03:59:59.999Z');
  });
});
