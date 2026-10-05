import { createContext } from 'react';
import type { EntityRecord, WidgetOptions } from '../../types';
import { conditionValue } from '../value';

// A nested view may further restrict editing, never unlock its parent.
export const ReadOnlyContext = createContext(false);
export const ReadOnlyStyleContext = createContext<'control' | 'text'>('control');

export function editable(
  options: WidgetOptions,
  record: EntityRecord | null,
  moduleRoles: string[] = [],
): boolean {
  if (options.read_only === true) return false;
  const mode = options.editable ?? 'always';
  if (mode === true || mode === 'always') return true;
  if (mode === false || mode === 'never') return false;
  if (mode !== 'conditional' && mode !== 'conditionally') return false;
  return matchesCondition(options.editability, record, moduleRoles);
}

export function matchesCondition(
  condition: unknown,
  record: EntityRecord | null,
  moduleRoles: string[] = [],
): boolean {
  if (!condition || typeof condition !== 'object') return false;
  const rule = condition as Record<string, unknown>;
  // Unknown conditions must not silently grant editing rights.
  if (Object.keys(rule).some((key) => !['expression', 'roles', 'ignore_security'].includes(key)))
    return false;
  if (rule.ignore_security !== undefined && typeof rule.ignore_security !== 'boolean') return false;
  if (rule.roles !== undefined) {
    if (!Array.isArray(rule.roles) || rule.roles.some((role) => typeof role !== 'string')) return false;
    if (rule.roles.length && !rule.ignore_security && !rule.roles.some((role) => moduleRoles.includes(role)))
      return false;
  }
  try {
    if (rule.expression !== undefined && typeof rule.expression !== 'string') return false;
    if (typeof rule.expression === 'string' && rule.expression.trim() !== '')
      return conditionValue(rule.expression, record);
    return (Array.isArray(rule.roles) && rule.roles.length > 0) || rule.ignore_security === true;
  } catch {
    return false;
  }
}
