import { createContext } from 'react';
import type { EntityRecord, RuntimeVariables, WidgetOptions } from '../../types';
import { conditionValue, isEntityRecord, memberName, recordValue } from '../value';

// A nested view may further restrict editing, never unlock its parent.
export const ReadOnlyContext = createContext(false);
export const ReadOnlyStyleContext = createContext<'control' | 'text'>('control');
// A data view's label width (out of 12) lays its fields out horizontally;
// 0 keeps labels above them.
export const LabelWidthContext = createContext(0);

export function editable(
  options: WidgetOptions,
  record: EntityRecord | null,
  moduleRoles: string[] = [],
  widgetObjects: RuntimeVariables = {},
): boolean {
  if (options.read_only === true) return false;
  const mode = options.editable ?? 'always';
  if (mode === true || mode === 'always') return true;
  if (mode === false || mode === 'never') return false;
  if (mode !== 'conditional' && mode !== 'conditionally') return false;
  return matchesCondition(options.editability, record, moduleRoles, widgetObjects);
}

const CONDITION_KEYS = ['expression', 'roles', 'ignore_security', 'attribute', 'conditions', 'source_variable'];

// The object a condition reads: the surrounding object, or a named data widget's.
function conditionSubject(
  source: unknown,
  record: EntityRecord | null,
  widgetObjects: RuntimeVariables,
): EntityRecord | null | undefined {
  if (source === undefined) return record;
  if (!source || typeof source !== 'object') return undefined;
  const { kind, name } = source as { kind?: unknown; name?: unknown };
  if (kind === 'current') return record;
  if (kind !== 'widget' || typeof name !== 'string') return undefined;
  if (!Object.hasOwn(widgetObjects, name)) return undefined;
  const object = widgetObjects[name];
  return isEntityRecord(object) ? object : null;
}

// Attribute values as MxBuild compiles them: the attribute equals one of the
// matching values, where "(empty)" stands for no value.
function matchesAttributeValues(
  attribute: unknown,
  conditions: unknown,
  subject: EntityRecord | null,
): boolean {
  if (typeof attribute !== 'string' || !attribute || !Array.isArray(conditions)) return false;
  const value = recordValue(subject, attribute);
  const text = value === null || value === undefined || value === '' ? null : memberName(String(value));
  return conditions.some((condition) => {
    if (!condition || typeof condition !== 'object') return false;
    const { AttributeValue: expected, EditableVisible: matches } = condition as Record<string, unknown>;
    if (matches !== true || typeof expected !== 'string') return false;
    return expected === '(empty)' ? text === null : text === expected;
  });
}

export function matchesCondition(
  condition: unknown,
  record: EntityRecord | null,
  moduleRoles: string[] = [],
  widgetObjects: RuntimeVariables = {},
): boolean {
  if (!condition || typeof condition !== 'object') return false;
  const rule = condition as Record<string, unknown>;
  // Unknown conditions must not silently grant editing rights.
  if (Object.keys(rule).some((key) => !CONDITION_KEYS.includes(key))) return false;
  if (rule.ignore_security !== undefined && typeof rule.ignore_security !== 'boolean') return false;
  if (rule.roles !== undefined) {
    if (!Array.isArray(rule.roles) || rule.roles.some((role) => typeof role !== 'string')) return false;
    if (rule.roles.length && !rule.ignore_security && !rule.roles.some((role) => moduleRoles.includes(role)))
      return false;
  }
  const subject = conditionSubject(rule.source_variable, record, widgetObjects);
  if (subject === undefined) return false;
  if (rule.attribute !== undefined || rule.conditions !== undefined)
    return matchesAttributeValues(rule.attribute, rule.conditions, subject);
  try {
    if (rule.expression !== undefined && typeof rule.expression !== 'string') return false;
    if (typeof rule.expression === 'string' && rule.expression.trim() !== '')
      return conditionValue(rule.expression, subject);
    return (Array.isArray(rule.roles) && rule.roles.length > 0) || rule.ignore_security === true;
  } catch {
    return false;
  }
}
