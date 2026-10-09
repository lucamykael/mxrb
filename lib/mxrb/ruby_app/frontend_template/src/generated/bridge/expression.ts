import type { EntityRecord, RuntimeValue, RuntimeVariables } from '../types';
import {
  arithmetic,
  decimal,
  decimalFunction,
  isDecimal,
  isDecimalFunction,
  isNumeric,
  numericCompare,
  numericText,
} from './decimal';
import { calendarFunction, isCalendarFunction } from './calendar';
import { parseDateTimeUTC } from './dateParsing';
import { attributeDefinition, enumerationDefinition, expressionSchema, translated } from './schemaLookup';

// Keep enum identity until comparison. Backend records can contain either the
// qualified literal or the bare member used by model defaults.
class EnumLiteral {
  constructor(readonly qualified: string) {}
  get member(): string {
    return this.qualified.split('.').at(-1)!;
  }
  matches(value: Value): boolean {
    return value instanceof EnumLiteral
      ? this.qualified === value.qualified
      : value === this.qualified || value === this.member;
  }
}
type Value = RuntimeValue | undefined | EnumLiteral;
let clientConstants: Record<string, RuntimeValue> = {};
export const registerClientConstants = (values: Record<string, RuntimeValue>): void => {
  clientConstants = structuredClone(values);
};
type Expression = () => Value;
const isRecord = (value: Value): value is EntityRecord =>
  !!value && typeof value === 'object' && !Array.isArray(value) && 'attributes' in value && 'id' in value;
const empty = (value: Value): boolean => value === null || value === undefined;

// Nanoflows run in the Mendix client, so string functions follow JavaScript:
// trim removes all Unicode blanks, substring takes a start and a length and
// never fails, regular expressions use JavaScript syntax (isMatch must match
// the whole text) and replacements are literal. Empty arguments read as ''.
const text = (value: Value): string => {
  if (empty(value)) return '';
  if (typeof value !== 'string') throw new Error('String function requires a string');
  return value;
};
const index = (value: Value): number => {
  if (typeof value !== 'number' || !Number.isInteger(value)) throw new Error('Expected an integer');
  return value;
};
const optionalIndex = (values: Value[], position: number) =>
  values.length > position ? index(values[position]) : undefined;
const substring = (value: string, start: number, length?: number): string => {
  const first = start < 0 ? Math.max(value.length + start, 0) : start;
  return value.slice(first, length === undefined ? undefined : first + Math.max(length, 0));
};
const stringFunctions: Record<string, [number, number, (values: Value[]) => Value]> = {
  trim: [1, 1, ([value]) => text(value).trim()],
  tolowercase: [1, 1, ([value]) => text(value).toLowerCase()],
  touppercase: [1, 1, ([value]) => text(value).toUpperCase()],
  length: [1, 1, ([value]) => text(value).length],
  substring: [2, 3, (values) => substring(text(values[0]), index(values[1]), optionalIndex(values, 2))],
  find: [2, 3, (values) => text(values[0]).indexOf(text(values[1]), optionalIndex(values, 2))],
  findlast: [
    2,
    3,
    (values) =>
      values.length > 2
        ? text(values[0]).lastIndexOf(text(values[1]), index(values[2]))
        : text(values[0]).lastIndexOf(text(values[1])),
  ],
  contains: [2, 2, ([value, search]) => text(value).includes(text(search))],
  startswith: [2, 2, ([value, search]) => text(value).startsWith(text(search))],
  endswith: [2, 2, ([value, search]) => text(value).endsWith(text(search))],
  replaceall: [
    3,
    3,
    ([value, pattern, replacement]) =>
      text(value).replace(new RegExp(text(pattern), 'g'), () => text(replacement)),
  ],
  replacefirst: [
    3,
    3,
    ([value, pattern, replacement]) =>
      text(value).replace(new RegExp(text(pattern)), () => text(replacement)),
  ],
  ismatch: [2, 2, ([value, pattern]) => new RegExp(`^(${text(pattern)})$`).test(text(value))],
  urlencode: [1, 1, ([value]) => encodeURIComponent(text(value))],
  urldecode: [1, 1, ([value]) => decodeURIComponent(text(value).replaceAll('+', ' '))],
};

// [%BeginOfCurrentDay%] and friends: the start of the period in the session
// time zone (or UTC), and its end one millisecond before the next period.
const tokenUnits = ['Minute', 'Hour', 'Day', 'Month', 'Year'];
function dateToken(token: string, timeZone?: string): string {
  const name = token.slice(2, -2);
  const now = new Date().toISOString();
  if (name === 'CurrentDateTime') return now;
  const match = /^(BeginOf|EndOf)Current(\w+?)(UTC)?$/.exec(name);
  if (!match || !tokenUnits.includes(match[2])) throw new Error(`Unsupported token: ${token}`);
  const [, edge, unit, utc = ''] = match;
  const begin = String(calendarFunction(`trimTo${unit}s${utc}`, [now], timeZone));
  if (edge === 'BeginOf') return begin;
  const next = Date.parse(String(calendarFunction(`add${unit}s${utc}`, [begin, 1], timeZone)));
  return new Date(next - 1).toISOString();
}

const locale = () =>
  (typeof document !== 'undefined' && document.documentElement.lang) ||
  (typeof navigator !== 'undefined' && navigator.language) ||
  'en-US';
const precedence: Record<string, number> = {
  or: 1,
  and: 2,
  '=': 3,
  '!=': 3,
  '>': 3,
  '<': 3,
  '>=': 3,
  '<=': 3,
  '+': 4,
  '-': 4,
  '*': 5,
  div: 5,
  ':': 5,
  mod: 5,
};

function boolean(value: Value): boolean {
  if (typeof value !== 'boolean') throw new Error('Condition must evaluate to a boolean');
  return value;
}

// Text concatenation reads empty as '' and writes numbers as toString does.
function concatenated(value: Value): string {
  if (empty(value)) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || isDecimal(value)) return numericText(value);
  throw new Error('Only text and numbers can be concatenated');
}

function binary(operator: string, left: Expression, right: Expression): Value {
  if (operator === 'and') return boolean(left()) && boolean(right());
  if (operator === 'or') return boolean(left()) || boolean(right());
  const a = left();
  const b = right();
  if (operator === '=' || operator === '!=') {
    const equal =
      a instanceof EnumLiteral
        ? a.matches(b)
        : b instanceof EnumLiteral
          ? b.matches(a)
          : isNumeric(a) && isNumeric(b)
            ? numericCompare(a, b) === 0
            : isRecord(a) && isRecord(b)
              ? a.id === b.id
              : (a ?? null) === (b ?? null);
    return operator === '=' ? equal : !equal;
  }
  if (operator === '+' && (typeof a === 'string' || typeof b === 'string'))
    return concatenated(a) + concatenated(b);
  if (['>', '<', '>=', '<='].includes(operator)) {
    if (isNumeric(a) && isNumeric(b)) {
      const order = numericCompare(a, b);
      return operator === '>'
        ? order > 0
        : operator === '<'
          ? order < 0
          : operator === '>='
            ? order >= 0
            : order <= 0;
    }
    if (!(
      (typeof a === 'number' && typeof b === 'number') ||
      (typeof a === 'string' && typeof b === 'string')
    )) {
      throw new Error('Comparison operands must have matching types');
    }
    if (operator === '>') return a > b;
    if (operator === '<') return a < b;
    if (operator === '>=') return a >= b;
    return a <= b;
  }
  return arithmetic(operator, a, b);
}

// A small explicit expression grammar, never JavaScript eval. Unsupported
// syntax is an error instead of a truthy string that enables an input.
export function evaluate(
  source: string,
  context: EntityRecord | null,
  variables: RuntimeVariables = {},
  options: { timeZone?: string } = {},
): RuntimeValue | undefined {
  const tokens: string[] = [];
  let remaining = source.trim();
  while (remaining) {
    const match = remaining.match(
      /^(?:'(?:[^']|'')*'|\[%[A-Za-z]+%\]|\$[A-Za-z_]\w*(?:\/[A-Za-z_][\w.]*)*|@[A-Za-z_]\w*\.[A-Za-z_]\w*|\d+(?:\.\d+)?|[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*|!=|>=|<=|[()=<>+*,:\-])/,
    );
    if (!match) throw new Error(`Unsupported expression syntax: ${remaining}`);
    tokens.push(match[0]);
    remaining = remaining.slice(match[0].length).trimStart();
  }
  let cursor = 0;
  const consume = (expected: string) => {
    if (tokens[cursor++] !== expected) throw new Error(`Expected ${expected} in expression`);
  };
  const callArguments = (): Expression[] => {
    consume('(');
    const arguments_: Expression[] = [];
    if (tokens[cursor] !== ')') {
      arguments_.push(parse(1));
      while (tokens[cursor] === ',') {
        consume(',');
        arguments_.push(parse(1));
      }
    }
    consume(')');
    return arguments_;
  };
  // $variable/Module.Association/Module.Entity/Attribute over the associated
  // objects embedded in records; a missing object makes the rest empty.
  // Enumeration attributes become literals so captions and keys are known.
  const path = (token: string): Value => {
    const [name, ...members] = token.slice(1).split('/');
    let value: Value = Object.hasOwn(variables, name) ? variables[name] : context;
    let owner: EntityRecord | null = null;
    let afterAssociation = false;
    for (const member of members) {
      if (empty(value)) return null;
      if (afterAssociation && member.includes('.')) {
        afterAssociation = false;
        continue;
      }
      if (!isRecord(value)) return undefined;
      afterAssociation = member.includes('.');
      owner = value;
      value = (value.attributes as Record<string, Value>)[member.split('.').at(-1) || member];
    }
    if (members.length && value === undefined) return null;
    const enumeration =
      owner && typeof value === 'string'
        ? attributeDefinition(expressionSchema(), owner.type, members.at(-1)!)?.enumeration
        : undefined;
    if (!enumeration) return value;
    return new EnumLiteral(
      (value as string).startsWith(`${enumeration}.`) ? (value as string) : `${enumeration}.${value}`,
    );
  };
  // getCaption and getKey of an enumeration literal or attribute.
  const enumerationText = (call: string, value: Value): string => {
    if (empty(value)) return '';
    if (!(value instanceof EnumLiteral)) return String(value);
    if (call === 'getkey') return value.member;
    const enumeration = value.qualified.split('.').slice(0, -1).join('.');
    const item = enumerationDefinition(expressionSchema(), enumeration)?.values.find(
      (candidate) => candidate.name === value.member,
    );
    return item ? translated(item.caption, item.caption_translations, locale()) : value.member;
  };
  const atom = (): Expression => {
    const token = tokens[cursor++];
    if (!token) throw new Error('Incomplete expression');
    if (token === '(') {
      const value = parse(1);
      consume(')');
      return value;
    }
    if (token === 'if') {
      const condition = parse(1);
      consume('then');
      const consequent = parse(1);
      consume('else');
      const alternative = parse(1);
      return () => (boolean(condition()) ? consequent() : alternative());
    }
    if (token === 'not' || token === '-') {
      const value = atom();
      return () => (token === 'not' ? !boolean(value()) : arithmetic('*', value(), -1));
    }
    if (token.startsWith("'")) return () => token.slice(1, -1).replaceAll("''", "'");
    if (/^\d/.test(token)) return () => (token.includes('.') ? decimal(token) : Number(token));
    if (token === 'true' || token === 'false') return () => token === 'true';
    if (token === 'empty') return () => null;
    if (token.startsWith('@'))
      return () => {
        const name = token.slice(1);
        if (!Object.hasOwn(clientConstants, name))
          throw new Error(`Client constant is unavailable: ${name}`);
        return clientConstants[name];
      };
    if (token.startsWith('[%')) return () => dateToken(token, options.timeZone);
    if (token.startsWith('$')) return () => path(token);
    if (
      isCalendarFunction(token) ||
      isDecimalFunction(token) ||
      token.toLowerCase() === 'parsedatetimeutc'
    ) {
      const arguments_ = callArguments();
      if (token.toLowerCase() === 'parsedatetimeutc')
        return () => parseDateTimeUTC(arguments_.map((argument) => argument()));
      if (isDecimalFunction(token))
        return () =>
          decimalFunction(
            token,
            arguments_.map((argument) => argument()),
          );
      return () =>
        calendarFunction(
          token,
          arguments_.map((argument) => argument()),
          options.timeZone,
        );
    }
    const call = token.toLowerCase();
    if (Object.hasOwn(stringFunctions, call) || call === 'getcaption' || call === 'getkey') {
      const arguments_ = callArguments();
      if (call === 'getcaption' || call === 'getkey') {
        if (arguments_.length !== 1) throw new Error(`${token} requires one enumeration value`);
        return () => enumerationText(call, arguments_[0]());
      }
      const [minimum, maximum, implementation] = stringFunctions[call];
      if (arguments_.length < minimum || arguments_.length > maximum)
        throw new Error(`${token} expects ${minimum} to ${maximum} arguments`);
      return () => implementation(arguments_.map((argument) => argument()));
    }
    if (token === 'toString') {
      consume('(');
      const value = parse(1);
      consume(')');
      return () => {
        const result = value();
        return result instanceof EnumLiteral
          ? result.member
          : isDecimal(result)
            ? numericText(result)
            : String(result ?? '');
      };
    }
    if (/^\w+\.\w+\.\w+$/.test(token)) return () => new EnumLiteral(token);
    throw new Error(`Unsupported expression: ${token}`);
  };
  const parse = (minimum: number): Expression => {
    let result = atom();
    while ((precedence[tokens[cursor]] || 0) >= minimum) {
      const operator = tokens[cursor++];
      const left = result;
      const right = parse(precedence[operator] + 1);
      result = () => binary(operator, left, right);
    }
    return result;
  };
  if (!tokens.length) return undefined;
  const result = parse(1);
  if (cursor !== tokens.length) throw new Error(`Unexpected expression token: ${tokens[cursor]}`);
  const value = result();
  return value instanceof EnumLiteral ? value.member : value;
}

export const evaluateCondition = (
  source: string,
  context: EntityRecord | null,
  variables: RuntimeVariables = {},
): boolean => boolean(evaluate(source, context, variables));
