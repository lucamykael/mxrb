import type {
  EntityRecord,
  NanoflowExecution,
  NanoflowEnvironment,
  NanoflowMetadata,
  NanoflowMicroflowInvoker,
  NanoflowParameters,
  RegisteredNanoflow,
  RuntimeValue,
} from '../types';

import { evaluate, evaluateCondition } from './expression';
import { arithmetic, numericCompare, numericText, isDecimal } from './decimal';
import { api } from './api';
import { compareSortValues, entityCollectionPath } from './value';

type SortSpec = Array<{ attribute: string; direction: string }>;
type RetrieveSpec = {
  source: string;
  entity?: string;
  xpath?: string;
  sort?: SortSpec;
  single?: boolean;
  limit?: string;
  offset?: string;
  start?: string;
  association?: string;
  from?: string;
  to?: string;
  kind?: string;
};
type ListOperationSpec = {
  operation: string;
  list: string;
  second: string;
  expression: string;
  attribute: string;
  sort: SortSpec;
  result_variable: string;
};
type AggregateSpec = { list: string; function: string; attribute: string; result_variable: string };
type LoopSpec = { kind: string; list?: string; condition?: string };

type ChangeExpressions = Record<string, string>;
// Expressions and decimals share the same evaluator as page bindings.
export type JavaScriptAction = (
  parameters: NanoflowParameters,
  variables?: NanoflowParameters,
  environment?: NanoflowEnvironment,
) => RuntimeValue | undefined | Promise<RuntimeValue | undefined>;

let nanoflowRegistry: Record<string, RegisteredNanoflow> = {};
let javaScriptActions: Record<string, JavaScriptAction> = {};

export const registerNanoflows = (values: Record<string, RegisteredNanoflow>): void => {
  nanoflowRegistry = { ...values };
};

export const registerJavaScriptActions = (values: Record<string, JavaScriptAction>): void => {
  javaScriptActions = { ...values };
};

const isRecord = (value: RuntimeValue | undefined): value is EntityRecord => {
  return Boolean(
    value && typeof value === 'object' && 'id' in value && 'type' in value && 'attributes' in value,
  );
};

export class NanoflowRuntime<P extends NanoflowParameters = NanoflowParameters> {
  readonly variables: NanoflowParameters;
  readonly #changes = new Map<string, EntityRecord>();
  readonly #messages: Array<{ message: string; level: string; blocking: boolean }> = [];
  readonly #effects: Array<{
    type: string;
    page?: string;
    arguments?: NanoflowParameters;
    count?: number;
    context?: EntityRecord;
    location?: 'content' | 'modal' | 'popup';
    title?: string;
  }> = [];
  readonly #validation: Array<{ variable: string; member: string; message: string }> = [];

  constructor(
    parameters: P,
    readonly metadata: NanoflowMetadata,
    readonly microflowInvoker?: NanoflowMicroflowInvoker,
    readonly environment: NanoflowEnvironment = {},
  ) {
    this.variables = structuredClone(parameters);
  }

  value(source: string | undefined, context: EntityRecord | null = null): RuntimeValue | undefined {
    return evaluate(source || '', context, this.variables);
  }

  condition(source: string | undefined, context: EntityRecord | null = null): boolean {
    return evaluateCondition(source || '', context, this.variables);
  }

  boolean(source: string | undefined, context: EntityRecord | null = null): boolean {
    return this.condition(source, context);
  }

  number(source: string | undefined, context: EntityRecord | null = null): number {
    const value = this.value(source, context);
    if (isDecimal(value)) throw new Error('Decimal cannot be returned as Integer');
    return Number(value);
  }

  string(source: string | undefined, context: EntityRecord | null = null): string {
    return numericText(this.value(source, context));
  }

  set(name: string, value: RuntimeValue | undefined): void {
    this.variables[name] = value;
  }

  log(message: string, parameters: string[] = []): void {
    const text = message.replace(/\{(\d+)\}/g, (_placeholder, index) =>
      this.string(parameters[Number(index) - 1]),
    );
    console.info(`[nanoflow] ${text || this.metadata.name}`);
  }

  // Database retrieves run on the server, which applies XPath, sorting and access rules.
  async retrieve(variable: string, spec: RetrieveSpec): Promise<void> {
    if (spec.source === 'association') {
      this.set(variable, await this.#associated(spec));
      return;
    }
    const query = new URLSearchParams();
    if (spec.xpath) {
      query.set('xpath', spec.xpath);
      const variables = this.#xpathVariables(spec.xpath);
      if (Object.keys(variables).length) query.set('xpath_variables', JSON.stringify(variables));
    }
    query.set('sort', JSON.stringify(spec.sort ?? []));
    const limit = spec.single ? 1 : spec.limit ? this.number(spec.limit) : 0;
    if (limit > 0) query.set('limit', String(limit));
    if (spec.offset) query.set('offset', String(this.number(spec.offset)));
    const response = await api<{ records: EntityRecord[] }>(
      `/api/entities/${encodeURIComponent(spec.entity ?? '')}?${query}`,
    );
    this.set(variable, spec.single ? (response.records[0] ?? null) : response.records);
  }

  async #associated(spec: RetrieveSpec): Promise<RuntimeValue> {
    const start = this.variables[spec.start ?? ''];
    const forward = isRecord(start) && start.type === spec.from;
    const single = forward && spec.kind === 'Reference';
    if (!isRecord(start)) return single ? null : [];
    const target = forward ? spec.to : spec.from;
    const response = await api<{ records: EntityRecord[] }>(
      entityCollectionPath(target ?? '', spec.association, start),
    );
    return single ? (response.records[0] ?? null) : response.records;
  }

  #xpathVariables(xpath: string): Record<string, RuntimeValue | undefined> {
    const names = [...xpath.matchAll(/\$([A-Za-z_]\w*)/g)].map((match) => match[1]);
    return Object.fromEntries(
      names
        .filter((name) => name !== 'currentObject' && name in this.variables)
        .map((name) => {
          const value = this.variables[name];
          return [name, isRecord(value) ? { type: value.type, id: value.id } : value];
        }),
    );
  }

  async commit(variable: string): Promise<void> {
    const records = this.#records(variable);
    if (!records.length) return;
    const response = await api<{ records: EntityRecord[] }>('/api/records/commit', {
      method: 'POST',
      body: JSON.stringify({
        records: records.map((record) => ({
          type: record.type,
          id: record.id,
          attributes: record.attributes,
          ...(record.transient ? { new_record: true } : {}),
        })),
      }),
    });
    response.records.forEach((saved, index) => {
      const record = records[index];
      this.#changes.delete(`${record.type}:${record.id}`);
      record.id = saved.id;
      record.attributes = { ...saved.attributes };
      delete record.transient;
    });
  }

  async delete(variable: string): Promise<void> {
    const records = this.#records(variable).filter((record) => !record.transient);
    if (records.length)
      await api('/api/records/delete', {
        method: 'POST',
        body: JSON.stringify({ records: records.map(({ type, id }) => ({ type, id })) }),
      });
  }

  // Restores the stored values of committed objects.
  async rollback(variable: string): Promise<void> {
    for (const record of this.#records(variable).filter((item) => !item.transient)) {
      const stored = await api<EntityRecord>(
        `/api/entities/${encodeURIComponent(record.type)}/${encodeURIComponent(record.id)}`,
      );
      record.attributes = { ...stored.attributes };
      this.#changes.delete(`${record.type}:${record.id}`);
    }
  }

  #records(variable: string): EntityRecord[] {
    const value = this.variables[variable];
    return (Array.isArray(value) ? value : [value]).filter(isRecord);
  }

  listOperation(spec: ListOperationSpec): void {
    const list = this.#list(spec.list);
    const second = this.variables[spec.second];
    const others = Array.isArray(second) ? second.filter(isRecord) : [];
    const has = (items: EntityRecord[], record: EntityRecord) =>
      items.some((item) => item.type === record.type && item.id === record.id);
    let result: RuntimeValue | undefined;
    switch (spec.operation) {
      case 'Head':
        result = list[0] ?? null;
        break;
      case 'Tail':
        result = list.slice(1);
        break;
      case 'Union':
        result = [...list, ...others.filter((record) => !has(list, record))];
        break;
      case 'Intersect':
        result = list.filter((record) => has(others, record));
        break;
      case 'Subtract':
        result = list.filter((record) => !has(others, record));
        break;
      case 'Contains':
        result = isRecord(second) && has(list, second);
        break;
      case 'Sort':
        result = sortList(list, spec.sort);
        break;
      default:
        result = this.#select(spec, list);
    }
    this.set(spec.result_variable, result);
  }

  #select(spec: ListOperationSpec, list: EntityRecord[]): RuntimeValue {
    const byExpression = spec.operation.endsWith('ByExpression');
    const expected = byExpression ? undefined : this.value(spec.expression);
    const matches = (record: EntityRecord) =>
      byExpression
        ? evaluateCondition(spec.expression, record, { ...this.variables, currentObject: record })
        : compareSortValues(record.attributes[spec.attribute], expected) === 0;
    if (spec.operation.startsWith('Find')) return list.find(matches) ?? null;
    if (spec.operation.startsWith('Filter')) return list.filter(matches);
    throw this.unsupported(spec.operation);
  }

  #list(name: string): EntityRecord[] {
    const list = this.variables[name];
    if (!Array.isArray(list)) throw new Error(`Nanoflow list $${name} is missing`);
    return list.filter(isRecord);
  }

  aggregate(spec: AggregateSpec): void {
    const list = this.#list(spec.list);
    if (spec.function === 'Count') {
      this.set(spec.result_variable, list.length);
      return;
    }
    const values = list
      .map((record) => record.attributes[spec.attribute])
      .filter((value) => value !== null && value !== undefined);
    this.set(spec.result_variable, aggregateValues(spec.function, values));
  }

  *loop(spec: LoopSpec): Generator<RuntimeValue | undefined> {
    if (spec.kind === 'while') {
      for (let iteration = 0; iteration < 10_000; iteration += 1) {
        if (!this.condition(spec.condition)) return;
        yield undefined;
      }
      throw this.exceeded();
    }
    yield* [...this.#list(spec.list ?? '')];
  }

  changeList(variable: string, operation: string, expression: string): void {
    const list = this.variables[variable];
    if (!Array.isArray(list)) throw new Error(`Nanoflow list $${variable} is missing`);
    const kind = operation.toLowerCase();
    if (kind === 'clear') {
      list.splice(0);
      return;
    }
    if (kind !== 'add' && kind !== 'remove')
      throw new Error(`Unsupported list change: ${operation}`);
    const value = this.value(expression);
    if (!isRecord(value)) throw new Error('List changes require an object');
    const index = list.findIndex(
      (item) => isRecord(item) && item.id === value.id && item.type === value.type,
    );
    if (kind === 'add' && index < 0) list.push(value);
    if (kind === 'remove' && index >= 0) list.splice(index, 1);
  }

  change(variable: string, expressions: ChangeExpressions): void {
    const record = this.variables[variable];
    if (!isRecord(record)) throw new Error(`Nanoflow object $${variable} is missing`);
    Object.entries(expressions).forEach(([member, expression]) => {
      record.attributes[member] = this.value(expression, record);
    });
    this.#changes.set(`${record.type}:${record.id}`, record);
  }

  create(variable: string, type: string, expressions: ChangeExpressions): EntityRecord {
    const record: EntityRecord = {
      id: crypto.randomUUID(),
      type,
      attributes: {},
      transient: true,
    };
    this.variables[variable] = record;
    Object.entries(expressions).forEach(([member, expression]) => {
      record.attributes[member] = this.value(expression, record);
    });
    this.#changes.set(`${record.type}:${record.id}`, record);
    return record;
  }

  async callMicroflow(
    name: string,
    expressions: Record<string, string>,
  ): Promise<RuntimeValue | undefined> {
    if (!this.microflowInvoker) {
      throw new Error(`Nanoflow ${this.metadata.name} cannot call ${name}: invoker is unavailable`);
    }
    const parameters = Object.fromEntries(
      Object.entries(expressions).map(([key, expression]) => [key, this.value(expression)]),
    );
    const response = await this.microflowInvoker(name, parameters);
    if (response && typeof response === 'object' && 'result' in response) {
      return (response as { result?: RuntimeValue }).result;
    }
    return response as RuntimeValue | undefined;
  }

  async callNanoflow(
    name: string,
    expressions: Record<string, string>,
  ): Promise<RuntimeValue | undefined> {
    const definition = nanoflowRegistry[name];
    if (!definition) throw new Error(`Nanoflow frontend not found: ${name}`);
    const parameters = Object.fromEntries(
      Object.entries(expressions).map(([key, expression]) => [key, this.value(expression)]),
    );
    const execution = await definition.execute(parameters, this.microflowInvoker, this.environment);
    execution.changes.forEach((record) => this.#changes.set(`${record.type}:${record.id}`, record));
    this.#messages.push(...execution.messages);
    this.#effects.push(...execution.effects);
    this.#validation.push(...execution.validation);
    return execution.result;
  }

  async callJavaScript(
    name: string,
    expressions: Record<string, string>,
  ): Promise<RuntimeValue | undefined> {
    const action = javaScriptActions[name];
    if (!action) throw new Error(`JavaScript action frontend adapter not found: ${name}`);
    const parameters = Object.fromEntries(
      Object.entries(expressions).map(([key, expression]) => [key, this.value(expression)]),
    );
    const records = Object.values(parameters).filter(isRecord);
    const before = records.map((record) => JSON.stringify(record.attributes));
    try {
      return await action(parameters, this.variables, this.environment);
    } finally {
      records.forEach((record, index) => {
        if (JSON.stringify(record.attributes) !== before[index])
          this.#changes.set(`${record.type}:${record.id}`, record);
      });
    }
  }

  showMessage(message: string, level = 'information', blocking = false): void {
    this.#messages.push({ message, level, blocking });
  }

  showPage(
    page: string,
    expressions: Record<string, string>,
    settings: {
      close?: string;
      context?: string;
      location?: 'content' | 'modal' | 'popup';
      title?: string;
      title_parameters?: string[];
    } = {},
  ): void {
    const argumentsValue = Object.fromEntries(
      Object.entries(expressions).map(([key, expression]) => [key, this.value(expression)]),
    );
    if (settings.close) this.closePage(settings.close);
    const title = settings.title?.replace(/\\{(\\d+)\\}/g, (_placeholder, index) =>
      this.string(settings.title_parameters?.[Number(index) - 1] || "''"),
    );
    const context = settings.context ? this.value('$' + settings.context) : undefined;
    if (context != null && !isRecord(context)) throw new Error('Page context must be an object');
    this.#effects.push({
      type: 'open_page',
      page,
      arguments: argumentsValue,
      ...(settings.location ? { location: settings.location } : {}),
      ...(title !== undefined ? { title } : {}),
      ...(isRecord(context) ? { context } : {}),
    });
  }

  closePage(expression = '1'): void {
    const count = this.value(expression || '1');
    if (typeof count !== 'number' || !Number.isInteger(count) || count < 0)
      throw new Error('Number of pages to close must be a non-negative integer');
    this.#effects.push({ type: 'close_page', count });
  }

  validationFeedback(variable: string, member: string, message: string): void {
    this.#validation.push({ variable, member, message });
  }

  complete<R>(result: R): NanoflowExecution<R> {
    return {
      result,
      variables: this.variables,
      changes: [...this.#changes.values()],
      messages: [...this.#messages],
      effects: [...this.#effects],
      validation: [...this.#validation],
    };
  }

  missing(current: string | null): Error {
    return new Error(
      `Nanoflow ${this.metadata.name} points to missing object ${current || '(none)'}`,
    );
  }

  stopped(type: string): Error {
    return new Error(`Nanoflow ${this.metadata.name} stops at ${type}`);
  }

  unsupported(type: string): Error {
    return new Error(`Unsupported frontend nanoflow action: ${type || '(empty)'}`);
  }

  exceeded(): Error {
    return new Error(`Nanoflow ${this.metadata.name} exceeded 10000 steps`);
  }
}

export const defineNanoflow = <P extends NanoflowParameters, R extends RuntimeValue | undefined>(
  metadata: NanoflowMetadata,
  compiled: (runtime: NanoflowRuntime<P>) => NanoflowExecution<R> | Promise<NanoflowExecution<R>>,
): RegisteredNanoflow => ({
  ...metadata,
  execute: async (parameters, invokeMicroflow, environment) =>
    compiled(new NanoflowRuntime(parameters as P, metadata, invokeMicroflow, environment)),
});

// The client list Sort places empty values last in both directions.
const sortList = (list: EntityRecord[], sort: SortSpec): EntityRecord[] =>
  list
    .map((record, index) => ({ record, index }))
    .sort((left, right) => {
      for (const { attribute, direction } of sort) {
        const a = left.record.attributes[attribute];
        const b = right.record.attributes[attribute];
        const missing =
          Number(a === null || a === undefined) - Number(b === null || b === undefined);
        const comparison = missing || compareSortValues(a, b, direction === 'Descending');
        if (comparison !== 0) return comparison;
      }
      return left.index - right.index;
    })
    .map(({ record }) => record);

const aggregateValues = (kind: string, values: RuntimeValue[]): RuntimeValue => {
  if (!values.length) return kind === 'Sum' ? 0 : null;
  if (kind === 'Minimum' || kind === 'Maximum') {
    const sign = kind === 'Minimum' ? -1 : 1;
    return values.reduce((best, value) => (sign * numericCompare(value, best) > 0 ? value : best));
  }
  const sum = values.reduce((total, value) => arithmetic('+', total, value));
  return kind === 'Sum' ? sum : arithmetic(':', sum, values.length);
};
