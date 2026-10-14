// mendix/filters/builders for the project's own widget builds: the conditions
// they pass to ListValue.setFilter, which the pluggable host evaluates in the browser.
import Big from 'big.js';

export type FilterValue = string | number | boolean | Date | Big | undefined;
export type FilterCondition =
  | { type: 'function'; name: string; args: FilterCondition[] }
  | { type: 'attribute'; attributeId: string }
  | { type: 'association'; associationId: string }
  | { type: 'literal'; value: FilterValue };

const call =
  (name: string) =>
  (...args: FilterCondition[]): FilterCondition => ({ type: 'function', name, args });

export const attribute = (attributeId: string): FilterCondition => ({
  type: 'attribute',
  attributeId,
});
export const association = (associationId: string): FilterCondition => ({
  type: 'association',
  associationId,
});
export const literal = (value: FilterValue): FilterCondition => ({ type: 'literal', value });
export const empty = (): FilterCondition => literal(undefined);
export const and = call('and');
export const or = call('or');
export const not = call('not');
export const equals = call('=');
export const notEqual = call('!=');
export const greaterThan = call('>');
export const greaterThanOrEqual = call('>=');
export const lessThan = call('<');
export const lessThanOrEqual = call('<=');
export const contains = call('contains');
export const startsWith = call('starts-with');
export const endsWith = call('ends-with');
export const dayEquals = call('day:=');
export const dayNotEqual = call('day:!=');
export const dayGreaterThan = call('day:>');
export const dayGreaterThanOrEqual = call('day:>=');
export const dayLessThan = call('day:<');
export const dayLessThanOrEqual = call('day:<=');

const comparable = (value: FilterValue): string | number | undefined => {
  if (value === undefined || value === null || value === '') return undefined;
  if (value instanceof Big) return Number(value.toString());
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'boolean') return value ? 1 : 0;
  return typeof value === 'string' ? value.toLowerCase() : value;
};
const day = (value: FilterValue): number | undefined => {
  if (!(value instanceof Date)) return comparable(value) as number | undefined;
  return new Date(value.getFullYear(), value.getMonth(), value.getDate()).getTime();
};
const text = (value: FilterValue): string => String(comparable(value) ?? '').toLowerCase();

function order(name: string, left: FilterValue, right: FilterValue): boolean {
  const byDay = name.startsWith('day:');
  const a = byDay ? day(left) : comparable(left);
  const b = byDay ? day(right) : comparable(right);
  const operator = byDay ? name.slice(4) : name;
  if (operator === '=') return a === b;
  if (operator === '!=') return a !== b;
  if (a === undefined || b === undefined) return false;
  if (operator === '>') return a > b;
  if (operator === '>=') return a >= b;
  if (operator === '<') return a < b;
  return a <= b;
}

// Whether an object matches a condition; read(attributeId) gives its value.
export function matchesFilter(
  condition: FilterCondition,
  read: (attributeId: string) => FilterValue,
): boolean {
  const value = (operand: FilterCondition): FilterValue =>
    operand.type === 'attribute'
      ? read(operand.attributeId)
      : operand.type === 'literal'
        ? operand.value
        : undefined;
  if (condition.type !== 'function') return Boolean(value(condition));
  const [left, right] = condition.args;
  switch (condition.name) {
    case 'and':
      return condition.args.every((item) => matchesFilter(item, read));
    case 'or':
      return condition.args.some((item) => matchesFilter(item, read));
    case 'not':
      return !matchesFilter(left, read);
    case 'contains':
      return text(value(left)).includes(text(value(right)));
    case 'starts-with':
      return text(value(left)).startsWith(text(value(right)));
    case 'ends-with':
      return text(value(left)).endsWith(text(value(right)));
    default:
      return order(condition.name, value(left), value(right));
  }
}
