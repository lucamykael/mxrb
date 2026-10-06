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
type Expression = () => Value;
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
            : a === b;
    return operator === '=' ? equal : !equal;
  }
  if (operator === '+' && typeof a === 'string' && typeof b === 'string') return a + b;
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
      /^(?:'(?:[^']|'')*'|\$[A-Za-z_]\w*(?:\/[A-Za-z_][\w.]*)?|\d+(?:\.\d+)?|[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*|!=|>=|<=|[()=<>+*,:\-])/,
    );
    if (!match) throw new Error(`Unsupported expression syntax: ${remaining}`);
    tokens.push(match[0]);
    remaining = remaining.slice(match[0].length).trimStart();
  }
  let cursor = 0;
  const consume = (expected: string) => {
    if (tokens[cursor++] !== expected) throw new Error(`Expected ${expected} in expression`);
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
    if (token.startsWith('$')) {
      const [name, member] = token.slice(1).split('/');
      return () => {
        const value = Object.hasOwn(variables, name) ? variables[name] : context;
        if (!member) return value;
        if (!value || typeof value !== 'object' || !('attributes' in value)) return undefined;
        const attributes = value.attributes as Record<string, Value>;
        return attributes[member.split('.').at(-1) || member];
      };
    }
    if (isCalendarFunction(token) || isDecimalFunction(token)) {
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
    if (['contains', 'starts-with', 'startsWith', 'endsWith'].includes(token)) {
      consume('(');
      const left = parse(1);
      consume(',');
      const right = parse(1);
      consume(')');
      return () => {
        const value = left();
        const search = right();
        if (typeof value !== 'string' || typeof search !== 'string')
          throw new Error('String predicate requires two strings');
        if (token === 'contains') return value.includes(search);
        return token === 'endsWith' ? value.endsWith(search) : value.startsWith(search);
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
