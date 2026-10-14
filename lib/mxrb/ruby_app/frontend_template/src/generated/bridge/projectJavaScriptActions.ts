// The project's own JavaScript actions (javascriptsource/<module>/actions), run
// as the Mendix client runs them: objects as MxObject, numbers as Big, dates as
// Date, with window.mx answered by the runtime. Changes the action makes to
// its objects reach the nanoflow that called it.
import Big from 'big.js';
import { api } from './api';
import { decimal, isDecimal } from './decimal';
import { installMx, MxObject, type MxStore } from './legacy/mx';
import type { JavaScriptAction } from './nanoflow';
import { expressionSchema } from './schemaLookup';
import type { ApiRequest, EntityRecord, RuntimeValue } from '../types';

export interface ProjectJavaScriptAction {
  // The source file under the registered root and its exported function.
  path: string;
  function: string;
  // Parameter names in call order with their JSDoc types (MxObject, Big, …).
  parameters: Array<{ name: string; type: string }>;
}

type ActionModule = Record<string, unknown>;

const isRecord = (value: unknown): value is EntityRecord =>
  Boolean(value) &&
  typeof value === 'object' &&
  'id' in (value as object) &&
  'type' in (value as object);

function argument(value: RuntimeValue | undefined, type: string, store: MxStore): unknown {
  if (value === null || value === undefined) return type === 'MxObject[]' ? [] : undefined;
  if (Array.isArray(value)) return value.filter(isRecord).map((record) => store.remember(record));
  if (isRecord(value)) return store.remember(value);
  if (type === 'Big') return new Big(isDecimal(value) ? value.__mxrb_decimal : Number(value));
  if (type === 'Date' && typeof value === 'string') return new Date(value);
  return value;
}

// The action's result in the runtime's representation.
function result(value: unknown): RuntimeValue | undefined {
  if (value instanceof MxObject) return value.toRecord();
  if (Array.isArray(value)) return value.map((item) => result(item)) as RuntimeValue;
  if (value instanceof Big) {
    const text = value.toString();
    return /[.eE]/.test(text) ? decimal(text) : Number(text);
  }
  if (value instanceof Date) return value.toISOString();
  return value as RuntimeValue | undefined;
}

// Writes what the action changed on an object back into the nanoflow's record.
function applyChanges(value: RuntimeValue | undefined, store: MxStore) {
  const records = Array.isArray(value) ? value.filter(isRecord) : isRecord(value) ? [value] : [];
  for (const record of records) {
    const changed = store.record(record.id);
    if (changed && changed !== record) Object.assign(record.attributes, changed.attributes);
  }
}

export function projectJavaScriptActions(
  modules: Record<string, () => Promise<unknown>>,
  root: string,
  actions: Record<string, ProjectJavaScriptAction>,
): Record<string, JavaScriptAction> {
  return Object.fromEntries(
    Object.entries(actions).map(([name, definition]) => {
      const action: JavaScriptAction = async (parameters, _variables, environment) => {
        const load = modules[`${root}${definition.path}`];
        if (!load) throw new Error(`JavaScript action source not found: ${name}`);
        const module = (await load()) as ActionModule;
        const run = module[definition.function];
        if (typeof run !== 'function')
          throw new Error(`${definition.path} exports no ${definition.function}`);
        const store = installMx({
          schema: expressionSchema() ?? undefined,
          request: api as ApiRequest,
          session: { roles: environment?.userRoles },
          locale: navigator.language || 'en-US',
        });
        const values = definition.parameters.map(({ name: key, type }) =>
          argument(parameters[key], type, store),
        );
        try {
          return result(await (run as (...values: unknown[]) => unknown)(...values));
        } finally {
          Object.values(parameters).forEach((value) => applyChanges(value, store));
        }
      };
      return [name, action];
    }),
  );
}
