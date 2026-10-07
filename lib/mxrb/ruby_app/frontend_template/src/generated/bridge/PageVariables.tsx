import { isDecimal, decimalNumber } from './decimal';
import { createContext, useRef, useState, type ReactNode } from 'react';
import type {
  ApplicationSchema,
  EntityRecord,
  RuntimeValue,
  RuntimeVariables,
  ValueDefinition,
  ValueType,
} from '../types';
import { evaluate } from './expression';
import { isEntityRecord, memberName } from './value';
import { VariableScope } from './components/VariableScope';

export function assignable(actual: string, expected: string, schema: ApplicationSchema): boolean {
  const entities = schema.modules.flatMap((module) => [
    ...(module.models || []),
    ...(module.dtos || []),
  ]);
  const visited = new Set<string>();
  while (actual && !visited.has(actual)) {
    if (actual === expected) return true;
    visited.add(actual);
    actual = entities.find((entity) => entity.name === actual)?.generalization?.target || '';
  }
  return false;
}

export function validateValue(
  value: RuntimeValue | undefined,
  type: ValueType | undefined,
  schema: ApplicationSchema,
  name: string,
) {
  if (value == null || !type || type.kind === 'unknown') return;
  let valid = false;
  switch (type.kind.toLowerCase()) {
    case 'string':
      valid = typeof value === 'string';
      break;
    case 'boolean':
      valid = typeof value === 'boolean';
      break;
    case 'integer':
    case 'long':
      valid =
        typeof value === 'number'
          ? Number.isSafeInteger(value)
          : typeof value === 'string' && /^-?\d+$/.test(value);
      break;
    case 'decimal':
      if (isDecimal(value)) {
        valid = decimalNumber(value).isFinite();
        break;
      }
    // Legacy numeric and textual callers remain supported.
    case 'float':
      valid =
        typeof value === 'number'
          ? Number.isFinite(value)
          : typeof value === 'string' && /^-?\d+(?:\.\d+)?$/.test(value);
      break;
    case 'datetime':
    case 'date_time':
      valid = typeof value === 'string' && !Number.isNaN(Date.parse(value));
      break;
    case 'object':
      valid =
        isEntityRecord(value) && (!type.entity || assignable(value.type, type.entity, schema));
      break;
    case 'list':
      valid =
        Array.isArray(value) &&
        value.every(
          (entry) =>
            isEntityRecord(entry) && (!type.entity || assignable(entry.type, type.entity, schema)),
        );
      break;
    case 'enumeration': {
      const enumeration = schema.modules
        .flatMap((module) => module.enumerations || [])
        .find((entry) => entry.name === type.enumeration || entry.id === type.enumeration);
      valid =
        typeof value === 'string' &&
        !!enumeration?.values.some(
          (entry) => entry.name === value || `${enumeration.name}.${entry.name}` === value,
        );
      break;
    }
  }
  if (!valid) throw new Error(`Invalid ${type.kind} value for ${name}`);
}

export function resolveParameters(
  definitions: Array<string | ValueDefinition> = [],
  supplied: RuntimeVariables = {},
  context: EntityRecord | null,
  schema: ApplicationSchema,
): RuntimeVariables {
  const parameters: ValueDefinition[] = definitions.map((definition) =>
    typeof definition === 'string' ? { name: definition, required: true } : definition,
  );
  const values: RuntimeVariables = {};
  for (const [name, value] of Object.entries(supplied)) {
    const local = memberName(name);
    if (Object.hasOwn(values, local)) throw new Error(`Duplicate page argument ${local}`);
    values[local] = value;
  }
  const objects = parameters.filter((parameter) => parameter.type?.kind === 'object');
  if (objects.length === 1 && context && !Object.hasOwn(values, objects[0].name))
    values[objects[0].name] = context;
  const result: RuntimeVariables = {};
  for (const definition of parameters) {
    const name = definition.name;
    if (Object.hasOwn(values, name)) result[name] = values[name];
    else if (definition.required !== false) throw new Error(`Missing required parameter: ${name}`);
    else
      result[name] = evaluate(definition.default || '', context, { ...values, ...result }) ?? null;
    validateValue(result[name], definition.type, schema, name);
  }
  return definitions.length ? result : values;
}

export function initializeVariables(
  definitions: ValueDefinition[],
  parameters: RuntimeVariables,
  context: EntityRecord | null,
  schema: ApplicationSchema,
) {
  const values: RuntimeVariables = {};
  const pending = new Map(definitions.map((definition) => [definition.name, definition]));
  if (pending.size !== definitions.length) throw new Error('Duplicate local variable');
  while (pending.size) {
    const before = pending.size;
    for (const [name, definition] of pending) {
      const dependencies = [
        ...(definition.default || '').replace(/'(?:[^']|'')*'/g, '').matchAll(/\$([A-Za-z_]\w*)/g),
      ].map((match) => match[1]);
      if (dependencies.some((dependency) => pending.has(dependency))) continue;
      values[name] =
        evaluate(definition.default || '', context, { ...parameters, ...values }) ?? null;
      validateValue(values[name], definition.type, schema, name);
      pending.delete(name);
    }
    if (pending.size === before)
      throw new Error(`Cyclic local variables: ${[...pending.keys()].join(', ')}`);
  }
  return values;
}

export const PageParameters = createContext<RuntimeVariables>({});

// A page argument and its active context can be separate JSON snapshots of
// the same object. Keep named references current after saves and flow results.
export function liveParameters(
  parameters: RuntimeVariables,
  context: EntityRecord | null,
): RuntimeVariables {
  const replace = (value: RuntimeValue | undefined): RuntimeValue | undefined => {
    if (Array.isArray(value)) return value.map(replace) as RuntimeValue;
    return context &&
      isEntityRecord(value) &&
      value.type === context.type &&
      value.id === context.id
      ? context
      : value;
  };
  return Object.fromEntries(
    Object.entries(parameters).map(([name, value]) => [name, replace(value)]),
  );
}

export const PageParameterBindings = createContext<{
  values: RuntimeVariables;
  types?: Record<string, ValueType | undefined>;
  set: (name: string, value: RuntimeValue | undefined) => void;
}>({ values: {}, set: () => {} });
export const SnippetParameterBindings = createContext<{
  values: RuntimeVariables;
  types?: Record<string, ValueType | undefined>;
  set: (name: string, value: RuntimeValue | undefined) => void;
}>({ values: {}, set: () => {} });
export const LocalVariables = createContext<{
  values: RuntimeVariables;
  types?: Record<string, ValueType | undefined>;
  set: (name: string, value: RuntimeValue | undefined) => void;
}>({ values: {}, set: () => {} });

export function VariableEnvironment({
  parameters,
  definitions = [],
  parameterDefinitions = [],
  scope = 'page',
  context,
  schema,
  children,
}: {
  parameters: RuntimeVariables;
  definitions?: ValueDefinition[];
  parameterDefinitions?: Array<string | ValueDefinition>;
  scope?: 'page' | 'snippet';
  context: EntityRecord | null;
  schema: ApplicationSchema;
  children: ReactNode;
}) {
  const [parameterChanges, setParameterChanges] = useState<RuntimeVariables>({});
  const parameterValues = { ...parameters, ...parameterChanges };
  const latestParameters = useRef(parameterValues);
  latestParameters.current = parameterValues;
  const setParameter = (name: string, value: RuntimeValue | undefined) => {
    const local = memberName(name);
    if (!Object.hasOwn(parameters, local)) throw new Error(`Unknown parameter ${name}`);
    const definition = parameterDefinitions.find((entry) =>
      typeof entry === 'string' ? entry === local : entry.name === local,
    );
    validateValue(
      value,
      typeof definition === 'object' ? definition.type : undefined,
      schema,
      name,
    );
    latestParameters.current = { ...latestParameters.current, [local]: value };
    setParameterChanges((current) => ({ ...current, [local]: value }));
  };
  const [values, setValues] = useState(() =>
    initializeVariables(definitions, parameters, context, schema),
  );
  const latestValues = useRef(values);
  latestValues.current = values;
  const set = (name: string, value: RuntimeValue | undefined) => {
    const definition = definitions.find((entry) => entry.name === memberName(name));
    if (!definition) throw new Error(`Unknown local variable ${name}`);
    validateValue(value, definition.type, schema, name);
    latestValues.current = { ...latestValues.current, [definition.name]: value };
    setValues(latestValues.current);
  };
  const content = (
    <LocalVariables.Provider
      value={{
        get values() {
          return latestValues.current;
        },
        set,
        types: Object.fromEntries(definitions.map((entry) => [entry.name, entry.type])),
      }}
    >
      <VariableScope.Provider value={{ ...parameterValues, ...values }}>
        {children}
      </VariableScope.Provider>
    </LocalVariables.Provider>
  );
  const bindings = {
    get values() {
      return latestParameters.current;
    },
    set: setParameter,
    types: Object.fromEntries(
      parameterDefinitions
        .filter((entry): entry is ValueDefinition => typeof entry !== 'string')
        .map((entry) => [entry.name, entry.type]),
    ),
  };
  return scope === 'page' ? (
    <PageParameters.Provider value={parameterValues}>
      <PageParameterBindings.Provider value={bindings}>{content}</PageParameterBindings.Provider>
    </PageParameters.Provider>
  ) : (
    <SnippetParameterBindings.Provider value={bindings}>
      {content}
    </SnippetParameterBindings.Provider>
  );
}
