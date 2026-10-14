import Decimal from 'decimal.js';
import decimalConfig from '../decimalConfig';
import { parseDecimalPattern } from './decimalParsing';

export type DecimalValue = { __mxrb_decimal: string };
export const isDecimal = (value: unknown): value is DecimalValue =>
  Boolean(
    value &&
    typeof value === 'object' &&
    Object.keys(value).length === 1 &&
    '__mxrb_decimal' in value &&
    typeof value.__mxrb_decimal === 'string',
  );

const pattern = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
const rounding =
  decimalConfig.rounding === 'HalfEven' ? Decimal.ROUND_HALF_EVEN : Decimal.ROUND_HALF_UP;
const Context = Decimal.clone({ precision: 38, rounding });

export function decimalNumber(value: unknown): Decimal {
  const text = isDecimal(value) ? value.__mxrb_decimal : String(value);
  if (!pattern.test(text)) throw new Error('Expected a finite decimal');
  const result = new Context(text);
  if (!result.isFinite()) throw new Error('Expected a finite decimal');
  return result;
}

export const decimal = (value: unknown): DecimalValue => ({
  __mxrb_decimal: decimalNumber(value).toFixed(),
});
// JSON numbers are exact only up to 2**53 - 1; longer integers stay tagged text.
export const exactInteger = (input: string | number | boolean): number | DecimalValue => {
  const text = String(input).trim();
  const number = Number(text);
  return /^[+-]?\d+$/.test(text) && !Number.isSafeInteger(number) ? decimal(text) : number;
};
export const isNumeric = (value: unknown): value is number | DecimalValue =>
  isDecimal(value) || (typeof value === 'number' && Number.isFinite(value));
export const numericCompare = (left: unknown, right: unknown): number =>
  decimalNumber(left).comparedTo(decimalNumber(right));
export const numericText = (value: unknown): string =>
  isDecimal(value) ? value.__mxrb_decimal : String(value ?? '');

const scaled = (value: Decimal): [bigint, number] => {
  const text = value.toFixed();
  const [whole, fraction = ''] = text.replace('-', '').split('.');
  return [BigInt(whole + fraction) * (text.startsWith('-') ? -1n : 1n), fraction.length];
};

// left / right to 20 decimal places with the application's rounding, exactly.
export function quotient(left: Decimal, right: Decimal): Decimal {
  if (right.isZero()) throw new Error('Division by zero');
  const [a, aScale] = scaled(left);
  const [b, bScale] = scaled(right);
  const sign = a < 0n !== b < 0n ? '-' : '';
  const numerator = (a < 0n ? -a : a) * 10n ** BigInt(bScale + 20);
  const denominator = (b < 0n ? -b : b) * 10n ** BigInt(aScale);
  let digits = numerator / denominator;
  const twice = (numerator % denominator) * 2n;
  const halfway =
    twice === denominator && (rounding === Decimal.ROUND_HALF_UP || digits % 2n === 1n);
  if (twice > denominator || halfway) digits += 1n;
  return new Decimal(`${sign}${digits}e-20`);
}

export function arithmetic(operator: string, left: unknown, right: unknown): number | DecimalValue {
  if (!isNumeric(left) || !isNumeric(right)) throw new Error('Expected a finite number');
  const a = decimalNumber(left);
  const b = decimalNumber(right);
  if (['div', ':', 'mod'].includes(operator) && b.isZero()) throw new Error('Division by zero');
  // Addition/multiplication are exact; division keeps 20 decimal places like
  // big.js in the Mendix client.
  const precision = Math.max(38, a.sd() + b.sd() + Math.abs(a.e - b.e) + 2);
  const Exact = Decimal.clone({ precision, rounding });
  const x = new Exact(a);
  let result: Decimal;
  if (operator === '+') result = x.plus(b);
  else if (operator === '-') result = x.minus(b);
  else if (operator === '*') result = x.times(b);
  else if (operator === 'mod') result = x.mod(b);
  else result = quotient(a, b);
  if (!isDecimal(left) && !isDecimal(right) && !['div', ':'].includes(operator))
    return result.toNumber();
  return decimal(result.toFixed());
}

export const isDecimalFunction = (name: string): boolean =>
  ['parsedecimal', 'round', 'floor', 'ceil', 'abs'].includes(name.toLowerCase());

// parseDecimal(text), (text, default), (text, pattern) and (text, pattern, default).
function parseDecimal(args: unknown[]): DecimalValue | null {
  if (args.length < 1 || args.length > 3)
    throw new Error('parseDecimal requires one to three arguments');
  const [text, ...rest] = args;
  const pattern = typeof rest[0] === 'string' ? String(rest.shift()) : undefined;
  if (rest.length > 1 || (rest.length === 1 && rest[0] !== null && !isNumeric(rest[0])))
    throw new Error('unsupported decimal format');
  let parsed: string | null = null;
  try {
    parsed =
      pattern === undefined ? decimal(text).__mxrb_decimal : parseDecimalPattern(text, pattern);
  } catch (error) {
    if (rest.length === 0) throw error;
  }
  if (parsed !== null) return decimal(parsed);
  if (rest.length === 0) throw new Error(`Cannot parse ${JSON.stringify(text)} as a decimal`);
  return rest[0] === null ? null : decimal(rest[0]);
}

export function decimalFunction(name: string, args: unknown[]): number | DecimalValue | null {
  const operation = name.toLowerCase();
  if (operation === 'parsedecimal') return parseDecimal(args);
  if (!isNumeric(args[0])) throw new Error('Expected a finite number');
  const value = decimalNumber(args[0]);
  if (operation === 'round') {
    if (args.length < 1 || args.length > 2) throw new Error('round requires one or two arguments');
    const places = args.length === 2 ? args[1] : 0;
    if (typeof places !== 'number' || !Number.isInteger(places))
      throw new Error('Precision must be an integer');
    const factor = new Context(10).pow(places);
    // Shifting the exponent is exact, including for negative precision.
    const shifted = new Context(`${value.toFixed()}e${places}`);
    const integer = shifted.toDecimalPlaces(0, rounding);
    const result = new Context(`${integer.toFixed()}e${-places}`);
    if (!factor.isFinite()) throw new Error('Invalid precision');
    return places === 0 ? result.toNumber() : decimal(result.toFixed());
  }
  if (args.length !== 1) throw new Error('Expected one numeric argument');
  if (operation === 'floor') return value.floor().toNumber();
  if (operation === 'ceil') return value.ceil().toNumber();
  return isDecimal(args[0]) ? decimal(value.abs().toFixed()) : value.abs().toNumber();
}
