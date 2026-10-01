import { createContext } from 'react';
import type { EntityRecord, WidgetOptions } from '../../types';
import { conditionValue } from '../value';

// A nested view may further restrict editing, never unlock its parent.
export const ReadOnlyContext = createContext(false);
export const ReadOnlyStyleContext = createContext<'control' | 'text'>('control');

export function editable(options: WidgetOptions, record: EntityRecord | null): boolean {
  if (options.read_only === true) return false;
  const mode = options.editable ?? 'always';
  if (mode === true || mode === 'always') return true;
  if (mode === false || mode === 'never') return false;
  if (mode !== 'conditional' && mode !== 'conditionally') return false;
  return matchesCondition(options.editability, record);
}

export function matchesCondition(condition: unknown, record: EntityRecord | null): boolean {
  if (!condition || typeof condition !== 'object') return false;
  const rule = condition as Record<string, unknown>;
  // Unknown conditions must not silently grant editing rights.
  if (Object.keys(rule).some((key) => key !== 'expression')) return false;
  try {
    return typeof rule.expression === 'string' && rule.expression.trim() !== ''
      ? conditionValue(rule.expression, record)
      : false;
  } catch {
    return false;
  }
}
