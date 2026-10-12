import Decimal from 'decimal.js';
import {
  addDays,
  endOfDay,
  endOfWeek,
  startOfDay,
  startOfWeek,
  subDays,
  type Locale,
} from 'date-fns';
import decimalConfig from '../decimalConfig';
import {
  decimal,
  decimalNumber,
  isDecimal,
  isNumeric,
  quotient,
  type DecimalValue,
} from './decimal';
import {
  dateLocale,
  defaultPattern,
  delocalized,
  formatJavaPattern,
  localized,
  parseJavaPattern,
} from './dateFormatting';

// Expression functions of the Mendix client that follow big.js and date-fns:
// quotients and roots keep 20 decimal places, *Between results are absolute.
const rounding =
  decimalConfig.rounding === 'HalfEven' ? Decimal.ROUND_HALF_EVEN : Decimal.ROUND_HALF_UP;
const places = 20;

const isoDate = /^\d{4,}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/;
export const isDateValue = (value: unknown): value is string =>
  typeof value === 'string' && isoDate.test(value) && Number.isFinite(Date.parse(value));
function date(value: unknown, name: string): Date {
  if (!isDateValue(value)) throw new Error(`Operator ${name} expects a date and time`);
  return new Date(value);
}
const iso = (value: Date) => value.toISOString();

const Precise = Decimal.clone({ precision: 80, rounding: Decimal.ROUND_DOWN });
const fixed = (value: Decimal) => value.toDecimalPlaces(places, rounding);
const numeric = (value: Decimal): number | DecimalValue =>
  value.isInteger() && Math.abs(value.toNumber()) <= Number.MAX_SAFE_INTEGER
    ? value.toNumber() + 0
    : decimal(value.toFixed());

const betweenScales: Record<string, number> = {
  millisecondsbetween: 1,
  secondsbetween: 1000,
  minutesbetween: 60000,
  hoursbetween: 3600000,
  daysbetween: 86400000,
  weeksbetween: 604800000,
};

function extremum(name: string, values: unknown[]): unknown {
  if (!values.length) throw new Error(`${name} requires arguments`);
  const better = name === 'max' ? 1 : -1;
  if (values.every(isNumeric))
    return values.reduce((best, value) =>
      decimalNumber(value).comparedTo(decimalNumber(best)) === better ? value : best,
    );
  if (values.every(isDateValue))
    return values.reduce((best, value) =>
      Math.sign(Date.parse(value as string) - Date.parse(best as string)) === better ? value : best,
    );
  throw new Error(`Operator ${name} expects numbers or dates`);
}

function power(base: unknown, exponent: unknown): number | DecimalValue {
  if (!isNumeric(base) || !isNumeric(exponent)) throw new Error('Operator pow expects numbers');
  const x = decimalNumber(base);
  const n = decimalNumber(exponent);
  if (!n.isInteger()) return decimal(String(Math.pow(x.toNumber(), n.toNumber())));
  const magnitude = new Decimal(x).pow(n.abs());
  return numeric(n.isNegative() ? quotient(new Decimal(1), magnitude) : magnitude);
}

function parseInteger(values: unknown[]): number | DecimalValue | unknown {
  const [text, fallback] = values;
  if (typeof text !== 'string') throw new Error('Operator parseInteger expects a string');
  if (/^-?\d+$/.test(text)) return numeric(new Decimal(text));
  if (values.length < 2) throw new Error(`Not parsable to Integer: ${text}`);
  return fallback;
}

function formatted(name: string, values: unknown[]): string {
  const utc = name.endsWith('utc');
  const kind = name.replace(/^format/, '').replace(/utc$/, '');
  const value = date(values[0], name);
  const shown = utc ? localized(value) : value;
  if (kind === 'datetime' && typeof values[1] === 'string')
    return formatJavaPattern(shown, values[1]);
  if (kind !== 'datetime' && values.length !== 1) throw new Error(`${name} expects one date`);
  return formatJavaPattern(shown, defaultPattern(kind as 'date' | 'time' | 'datetime'));
}

function parsed(name: string, values: unknown[]): string | null {
  const [text, pattern, fallback] = values;
  if (typeof text !== 'string' || typeof pattern !== 'string')
    throw new Error(`Operator ${name} expects a text and a pattern`);
  const result = parseJavaPattern(text.trim(), pattern.trim());
  if (result) return iso(name.endsWith('utc') ? delocalized(result) : result);
  if (values.length === 3) {
    if (fallback === null) return null;
    if (isDateValue(fallback)) return fallback;
    throw new Error('Expected a date fallback');
  }
  throw new Error(`Unparseable date: "${text}"`);
}

const named = (name: string) => name.toLowerCase();
const dateFunctions = /^(format(datetime|date|time)|parsedatetime)(utc)?$/;
const others = new Set([
  'max',
  'min',
  'pow',
  'sqrt',
  'random',
  'parseinteger',
  'calendarmonthsbetween',
  'calendaryearsbetween',
  ...Object.keys(betweenScales),
]);
export const isClientFunction = (name: string): boolean =>
  dateFunctions.test(named(name)) || others.has(named(name));

export function clientFunction(name: string, values: unknown[]): unknown {
  const operation = named(name);
  if (operation.startsWith('format')) return formatted(operation, values);
  if (operation.startsWith('parsedatetime')) return parsed(operation, values);
  if (operation === 'max' || operation === 'min') return extremum(operation, values);
  if (operation === 'pow') return power(values[0], values[1]);
  if (operation === 'random') return decimal(String(Math.random()));
  if (operation === 'parseinteger') return parseInteger(values);
  if (operation === 'sqrt') {
    if (!isNumeric(values[0]) || decimalNumber(values[0]).isNegative())
      throw new Error(`Operator sqrt not supported in expression sqrt(${String(values[0])})`);
    return numeric(fixed(new Precise(decimalNumber(values[0])).sqrt()));
  }
  const [first, second] = [date(values[0], name), date(values[1], name)];
  if (operation in betweenScales)
    return decimal(
      quotient(
        new Decimal(Math.abs(first.getTime() - second.getTime())),
        new Decimal(betweenScales[operation]),
      ).toFixed(),
    );
  const months = (value: Date) => value.getFullYear() * 12 + value.getMonth();
  return Math.abs(
    operation === 'calendarmonthsbetween'
      ? months(first) - months(second)
      : first.getFullYear() - second.getFullYear(),
  );
}

// [%BeginOfCurrentWeek%], [%BeginOfYesterday%] and friends. UTC variants use
// date-fns defaults, so their weeks start on Sunday whatever the language.
const tokenFunctions: Record<string, (value: Date, locale?: { locale: Locale }) => Date> = {
  BeginOfCurrentWeek: startOfWeek,
  EndOfCurrentWeek: endOfWeek,
  BeginOfYesterday: (value) => subDays(startOfDay(value), 1),
  EndOfYesterday: (value) => subDays(endOfDay(value), 1),
  BeginOfTomorrow: (value) => addDays(startOfDay(value), 1),
  EndOfTomorrow: (value) => addDays(endOfDay(value), 1),
};
export function clientToken(name: string, now = new Date()): string | undefined {
  const utc = name.endsWith('UTC');
  const operation = tokenFunctions[utc ? name.slice(0, -3) : name];
  if (!operation) return undefined;
  return iso(
    utc ? delocalized(operation(localized(now))) : operation(now, { locale: dateLocale() }),
  );
}

// big.js text: exponential notation from 1e21 and below 1e-6.
export const clientNumberText = (value: number | DecimalValue): string =>
  isDecimal(value) ? new Decimal(value.__mxrb_decimal).toString() : String(value);
