import type { ApplicationSchema, EntityRecord, RuntimeValue } from '../types';
import type { JavaScriptAction } from './nanoflow';
import { decimalNumber, isDecimal } from './decimal';
import { isEntityRecord, memberName } from './value';

let schema: ApplicationSchema | null = null;

export const registerObjectStorageSchema = (value: ApplicationSchema | null): void => {
  schema = value;
};

const reference = (value: RuntimeValue | undefined): RuntimeValue => {
  if (value == null) return null;
  if (Array.isArray(value)) return value.map(reference);
  if (typeof value === 'object' && 'id' in value && typeof value.id === 'string') return value.id;
  if (typeof value === 'string') return value;
  throw new Error('Object storage requires reference identifiers');
};

export function serializeStorageObject(record: EntityRecord): Record<string, RuntimeValue> {
  const models =
    schema?.modules.flatMap((module) => [...(module.models || []), ...(module.dtos || [])]) || [];
  const model = models.find((entry) => entry.name === record.type);
  if (!model) throw new Error(`Object storage schema is unavailable for ${record.type}`);
  const members = Object.fromEntries(
    Object.entries(record.attributes).map(([key, value]) => [memberName(key), value]),
  );
  const result: Record<string, RuntimeValue> = { guid: record.id };
  const serialized = new Set<string>();
  for (const attribute of model.attributes || []) {
    const name = memberName(attribute.name);
    const value = members[name];
    if (value === undefined) throw new Error(`Object storage requires a loaded attribute: ${name}`);
    serialized.add(name);
    if (value === null) {
      result[name] = null;
    } else if (attribute.type.toLowerCase() === 'datetime') {
      const time = typeof value === 'number' ? value : Date.parse(String(value));
      if (!Number.isFinite(time)) throw new Error(`Invalid storage date: ${name}`);
      result[name] = time;
    } else if (['integer', 'long', 'autonumber'].includes(attribute.type.toLowerCase())) {
      if (typeof value === 'number' && !Number.isSafeInteger(value))
        throw new Error(`Storage integer exceeds exact frontend range: ${name}`);
      const number = decimalNumber(value);
      if (!number.isInteger()) throw new Error(`Invalid storage integer: ${name}`);
      result[name] = number.toString();
    } else if (attribute.type.toLowerCase() === 'decimal' || isDecimal(value)) {
      result[name] = decimalNumber(value).toString();
    } else {
      result[name] = value;
    }
  }
  const ancestors = new Set<string>();
  let current = model;
  while (!ancestors.has(current.name)) {
    ancestors.add(current.name);
    const parent = models.find((entry) => entry.name === current.generalization?.target);
    if (!parent) break;
    current = parent;
  }
  for (const association of schema?.modules.flatMap((module) => module.associations || []) || []) {
    if (!ancestors.has(association.from_entity)) continue;
    serialized.add(memberName(association.name));
    const value = members[memberName(association.name)];
    result[association.name] = reference(
      value ?? (association.type === 'ReferenceSet' ? [] : null),
    );
  }
  const unknown = Object.keys(members).find(
    (name) => !serialized.has(name) && members[name] !== undefined,
  );
  if (unknown) throw new Error(`Object storage schema does not expose member: ${unknown}`);
  return result;
}

export const writeStorageObject: JavaScriptAction = async ({ Key, Value }) => {
  if (!Key) throw new Error("Input parameter 'Key' is required");
  if (!Value) throw new Error("Input parameter 'Value' is required");
  if (!isEntityRecord(Value)) throw new TypeError('Storage value must be an application record');
  window.localStorage.setItem(String(Key), JSON.stringify(serializeStorageObject(Value)));
};
