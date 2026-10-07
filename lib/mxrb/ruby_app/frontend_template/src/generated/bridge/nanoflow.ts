import type {
  EntityRecord,
  NanoflowExecution,
  NanoflowMetadata,
  NanoflowMicroflowInvoker,
  NanoflowParameters,
  RegisteredNanoflow,
  RuntimeValue,
} from '../types';

import { evaluate, evaluateCondition } from './expression';
import { numericText, isDecimal } from './decimal';

type ChangeExpressions = Record<string, string>;
// Expressions and decimals share the same evaluator as page bindings.
export type JavaScriptAction = (
  parameters: NanoflowParameters,
  variables?: NanoflowParameters,
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

  log(message: string): void {
    console.info(`[nanoflow] ${message || this.metadata.name}`);
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
    const execution = await definition.execute(parameters, this.microflowInvoker);
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
    return action(parameters, this.variables);
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
  execute: async (parameters, invokeMicroflow) =>
    compiled(new NanoflowRuntime(parameters as P, metadata, invokeMicroflow)),
});
