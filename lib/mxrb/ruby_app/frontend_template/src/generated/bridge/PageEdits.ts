import { createContext } from 'react';
import type { ApplicationSchema, EntityRecord, RuntimeVariables, WidgetEvent } from '../types';

const key = (record: EntityRecord) => `${record.type}/${record.id}`;

// A page with Save/Cancel owns its drafts. Pages without these actions retain
// the existing immediate-write contract. Only edited members enter a commit.
export class PageEdits {
  readonly originals = new Map<string, EntityRecord>();
  readonly records = new Map<string, EntityRecord>();
  readonly changes = new Map<string, RuntimeVariables>();
  readonly fields = new Set<() => Promise<unknown>>();
  constructor(readonly deferred: boolean) {}

  resolve(record: EntityRecord | null | undefined): EntityRecord | null {
    return record ? this.records.get(key(record)) || record : null;
  }

  stage(record: EntityRecord, changes: RuntimeVariables): EntityRecord {
    const id = key(record);
    if (!this.originals.has(id)) this.originals.set(id, record);
    const current = this.resolve(record)!;
    const updated = { ...current, attributes: { ...current.attributes, ...changes } };
    this.records.set(id, updated);
    this.changes.set(id, { ...this.changes.get(id), ...changes });
    return updated;
  }

  async flush() {
    for (const field of this.fields) await field();
  }

  pending() {
    return [...this.changes].flatMap(([id, attributes]) => {
      const record = this.records.get(id)!;
      return record.transient ? [] : [{ type: record.type, id: record.id, attributes }];
    });
  }

  accept(records: EntityRecord[], submitted = new Map(this.changes)) {
    const responses = new Map(records.map((record) => [key(record), record]));
    for (const [id, attributes] of submitted) {
      const original = this.originals.get(id)!;
      const committed = responses.get(id) || {
        ...original,
        attributes: { ...original.attributes, ...attributes },
      };
      const remaining = Object.fromEntries(
        Object.entries(this.changes.get(id) || {}).filter(
          ([member, value]) => value !== attributes[member],
        ),
      );
      this.originals.set(id, committed);
      this.records.set(id, { ...committed, attributes: { ...committed.attributes, ...remaining } });
      if (Object.keys(remaining).length) this.changes.set(id, remaining);
      else this.changes.delete(id);
    }
  }

  forget(record: EntityRecord) {
    const id = key(record);
    this.originals.delete(id);
    this.records.delete(id);
    this.changes.delete(id);
  }

  cancel() {
    for (const [id, record] of this.originals) this.records.set(id, record);
    this.changes.clear();
  }
}

// Include actions inside shared snippets/layouts/menus, with cycle protection.
export function hasPageEdits(page: unknown, schema: ApplicationSchema): boolean {
  const visited = new Set<unknown>();
  const visit = (value: unknown): boolean => {
    if (!value || typeof value !== 'object' || visited.has(value)) return false;
    visited.add(value);
    if (Array.isArray(value)) return value.some(visit);
    const node = value as Record<string, unknown>;
    if (node.kind === 'action' && ['save_changes', 'cancel_changes'].includes(String(node.handler)))
      return true;
    for (const reference of ['snippet', 'menu', 'layout']) {
      if (typeof node[reference] === 'string' && visit(schema.presentation?.[node[reference]]))
        return true;
    }
    return Object.values(node).some(visit);
  };
  return visit(page);
}

export const ClientActions = createContext<{
  edits: PageEdits;
  reset: number;
  run: (event: WidgetEvent, record: EntityRecord | null) => Promise<unknown>;
} | null>(null);
