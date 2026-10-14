import Big from 'big.js';
import { describe, expect, it } from 'vitest';
import * as filters from './mendixFilters';

const { attribute, literal, matchesFilter } = filters;

const values: Record<string, filters.FilterValue> = {
  name: 'Gearbox',
  count: new Big(5),
  at: new Date(2026, 9, 14, 15, 30),
  active: true,
  empty: undefined,
};
const matches = (condition: filters.FilterCondition) =>
  matchesFilter(condition, (id) => values[id]);

describe('mendix/filters/builders', () => {
  it('builds the conditions widget builds pass to ListValue.setFilter', () => {
    expect(filters.equals(attribute('name'), literal('x'))).toEqual({
      type: 'function',
      name: '=',
      args: [
        { type: 'attribute', attributeId: 'name' },
        { type: 'literal', value: 'x' },
      ],
    });
    expect(filters.association('App.Owner')).toEqual({
      type: 'association',
      associationId: 'App.Owner',
    });
    expect(filters.empty()).toEqual({ type: 'literal', value: undefined });
  });

  it('evaluates text, number, date and logical conditions in the browser', () => {
    expect(matches(filters.contains(attribute('name'), literal('BOX')))).toBe(true);
    expect(matches(filters.startsWith(attribute('name'), literal('gear')))).toBe(true);
    expect(matches(filters.endsWith(attribute('name'), literal('gear')))).toBe(false);
    expect(matches(filters.greaterThan(attribute('count'), literal(new Big(4))))).toBe(true);
    expect(matches(filters.greaterThanOrEqual(attribute('count'), literal(5)))).toBe(true);
    expect(matches(filters.lessThan(attribute('count'), literal(5)))).toBe(false);
    expect(matches(filters.lessThanOrEqual(attribute('count'), literal(5)))).toBe(true);
    expect(matches(filters.notEqual(attribute('name'), literal('gearbox')))).toBe(false);
    expect(matches(filters.equals(attribute('active'), literal(true)))).toBe(true);
    expect(matches(filters.equals(attribute('empty'), filters.empty()))).toBe(true);
    expect(matches(filters.equals(attribute('name'), literal('')))).toBe(false);
    expect(matches(filters.greaterThan(attribute('empty'), literal(1)))).toBe(false);
    const day = new Date(2026, 9, 14);
    expect(matches(filters.dayEquals(attribute('at'), literal(day)))).toBe(true);
    expect(matches(filters.dayNotEqual(attribute('at'), literal(day)))).toBe(false);
    expect(matches(filters.dayGreaterThan(attribute('at'), literal(day)))).toBe(false);
    expect(matches(filters.dayGreaterThanOrEqual(attribute('at'), literal(day)))).toBe(true);
    expect(matches(filters.dayLessThan(attribute('at'), literal(day)))).toBe(false);
    expect(matches(filters.dayLessThanOrEqual(attribute('count'), literal(5)))).toBe(true);
    expect(matches(filters.greaterThan(attribute('at'), literal(day)))).toBe(true);
    const named = filters.contains(attribute('name'), literal('gear'));
    expect(
      matches(filters.and(named, filters.not(filters.equals(attribute('count'), literal(1))))),
    ).toBe(true);
    expect(
      matches(filters.or(filters.not(named), filters.equals(attribute('count'), literal(1)))),
    ).toBe(false);
    expect(matches(attribute('active'))).toBe(true);
    expect(matches(filters.association('App.Owner'))).toBe(false);
    expect(matches(filters.equals(filters.association('App.Owner'), filters.empty()))).toBe(true);
  });
});
