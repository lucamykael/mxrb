import type { EntityRecord, NanoflowParameters, RuntimeValue } from '../types';
import type { JavaScriptAction } from './nanoflow';
import { api } from './api';
import { decimal, decimalNumber } from './decimal';
import { isEntityRecord, memberName } from './value';
import {
  cachedStorageObject,
  objectStorageSchema,
  rememberStorageObject,
  serializeStorageObject,
} from './objectStorage';

function contextObject(id: string, variables: NanoflowParameters): EntityRecord | undefined {
  const visited = new Set<object>();
  const find = (value: RuntimeValue | undefined): EntityRecord | undefined => {
    if (!value || typeof value !== 'object' || visited.has(value)) return;
    visited.add(value);
    if (isEntityRecord(value) && value.id === id) return value;
    for (const child of Object.values(value)) {
      const found = find(child as RuntimeValue);
      if (found) return found;
    }
  };
  for (const value of Object.values(variables)) {
    const found = find(value);
    if (found) return found;
  }
}

function attributes(
  entity: string,
  stored: Record<string, RuntimeValue>,
): Record<string, RuntimeValue> {
  const schema = objectStorageSchema();
  const models =
    schema?.modules.flatMap((module) => [...(module.models || []), ...(module.dtos || [])]) || [];
  const model = models.find((entry) => entry.name === entity);
  if (!model) throw new Error('Object storage schema is unavailable for ' + entity);
  const members = new Map(
    (model.attributes || []).map((attribute) => [memberName(attribute.name), attribute]),
  );
  const ancestors = new Set<string>();
  let current = model;
  while (!ancestors.has(current.name)) {
    ancestors.add(current.name);
    const parent = models.find((entry) => entry.name === current.generalization?.target);
    if (!parent) break;
    current = parent;
  }
  const associations = schema?.modules.flatMap((module) => module.associations || []) || [];
  const result: Record<string, RuntimeValue> = {};
  for (const [key, value] of Object.entries(stored)) {
    if (key === 'guid') continue;
    const name = memberName(key);
    const attribute = members.get(name);
    if (attribute) {
      const type = attribute.type.toLowerCase();
      if (value === null) result[name] = null;
      else if (type === 'decimal') result[name] = decimal(value);
      else if (['integer', 'long', 'autonumber'].includes(type)) {
        const number = decimalNumber(value);
        if (!number.isInteger() || !Number.isSafeInteger(number.toNumber()))
          throw new Error('Storage integer exceeds exact frontend range: ' + name);
        result[name] = number.toNumber();
      } else if (type === 'datetime') {
        const date = new Date(Number(value));
        if (!Number.isFinite(date.getTime())) throw new Error('Invalid storage date: ' + name);
        result[name] = date.toISOString();
      } else result[name] = value;
      continue;
    }
    const association = associations.find(
      (entry) => entry.name === key && ancestors.has(entry.from_entity),
    );
    if (!association) throw new Error('Object storage schema does not expose member: ' + key);
    const reference = (id: RuntimeValue): RuntimeValue => {
      if (typeof id !== 'string') throw new Error('Storage reference requires an identifier');
      return { id, type: association.to_entity };
    };
    result[name] =
      value === null ? null : Array.isArray(value) ? value.map(reference) : reference(value);
  }
  return result;
}

export const readStorageObject: JavaScriptAction = async ({ Key, Entity }, variables = {}) => {
  if (!Key) throw new Error("Input parameter 'Key' is required");
  if (!Entity) throw new Error("Input parameter 'Entity' is required");
  const source = window.localStorage.getItem(String(Key));
  if (source === null) throw new Error("Storage item '" + String(Key) + "' does not exist");
  const stored: unknown = JSON.parse(source);
  if (
    !stored ||
    typeof stored !== 'object' ||
    Array.isArray(stored) ||
    !('guid' in stored) ||
    typeof stored.guid !== 'string' ||
    !stored.guid
  )
    throw new Error('Storage object requires a guid');
  const entity = String(Entity);
  let record = contextObject(stored.guid, variables) || cachedStorageObject(stored.guid);
  if (!record) {
    try {
      record = await api<EntityRecord>(
        '/api/entities/' + encodeURIComponent(entity) + '/' + encodeURIComponent(stored.guid),
      );
    } catch (error) {
      if (!(error instanceof Error) || !('status' in error) || error.status !== 404) throw error;
    }
  }
  if (!record) {
    record = await api<EntityRecord>('/api/records/restore', {
      method: 'POST',
      body: JSON.stringify({
        type: entity,
        attributes: attributes(entity, stored as Record<string, RuntimeValue>),
      }),
    });
  }
  window.localStorage.setItem(String(Key), JSON.stringify(serializeStorageObject(record)));
  return rememberStorageObject(record);
};
