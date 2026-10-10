import { isDecimal, isNumeric, numericCompare, numericText } from './decimal';
import type { CSSProperties } from 'react';
import { evaluate, evaluateCondition } from './expression';
import type {
  ApiFailure,
  EntityRecord,
  RuntimeValue,
  RuntimeVariables,
  WidgetDefinition,
  WidgetEvent,
  WidgetOptions,
} from '../types';

export const classes = (...values: Array<string | false | null | undefined>): string =>
  values.filter(Boolean).join(' ');

export const isEntityRecord = (value: RuntimeValue | undefined): value is EntityRecord =>
  Boolean(
    value &&
    typeof value === 'object' &&
    !Array.isArray(value) &&
    'id' in value &&
    'type' in value &&
    'attributes' in value,
  );

export const attributes = (
  object: RuntimeValue | undefined,
): Record<string, RuntimeValue | undefined> => (isEntityRecord(object) ? object.attributes : {});

export const memberName = (value: string | undefined): string =>
  (value || '').split(/[./]/).pop() || '';

export const entityCollectionPath = (
  entity: string,
  association: string | undefined,
  context: EntityRecord | null,
): string => {
  const path = `/api/entities/${encodeURIComponent(entity)}`;
  if (!association || !context?.type || !context.id) return path;
  const query = new URLSearchParams({
    association,
    context_type: context.type,
    context_id: context.id,
  });
  return `${path}?${query}`;
};

export const expressionValue = (
  source: string | undefined,
  context: EntityRecord | null,
  variables: RuntimeVariables = {},
): RuntimeValue | undefined => evaluate(source || '', context, variables);

export const conditionValue = (
  source: string | undefined,
  context: EntityRecord | null,
  variables: RuntimeVariables = {},
): boolean => evaluateCondition(source || '', context, variables);

export const isVisible = (
  source: string | boolean | undefined,
  context: EntityRecord | null,
): boolean => (typeof source === 'boolean' ? source : !source || conditionValue(source, context));

export const dynamicClass = (source: string | undefined, context: EntityRecord | null): string => {
  let text = source || '';
  text = text.replace(
    /\(?if\s+(.+?)\s+then\s+'([^']*)'\s+else\s+'([^']*)'\)?/g,
    (_match: string, condition: string, yes: string, no: string) =>
      conditionValue(condition, context) ? yes : no,
  );
  text = text.replace(
    /toString\(\$[A-Za-z_]\w*\/([A-Za-z_][\w.]*)\)/g,
    (_match: string, member: string) => numericText(attributes(context)[memberName(member)]),
  );
  text = text.replace(/\$[A-Za-z_]\w*\/([A-Za-z_][\w.]*)/g, (_match: string, member: string) =>
    numericText(attributes(context)[memberName(member)]),
  );
  return text
    .replace(/[+()']/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
};

export const caption = (
  widget: WidgetDefinition,
  options: WidgetOptions,
  context: EntityRecord | null,
  variables: RuntimeVariables = {},
): string => {
  let value = options.caption || widget.caption || widget.name;
  (options.parameters || []).forEach((parameter, index) => {
    value = value.replaceAll(
      `{${index + 1}}`,
      String(expressionValue(parameter, context, variables) ?? ''),
    );
  });
  return value;
};

export const inlineStyle = (value: string | undefined): CSSProperties =>
  Object.fromEntries(
    (value || '')
      .split(';')
      .filter(Boolean)
      .map((rule: string) => {
        const [property, ...parts] = rule.split(':');
        const name = property
          .trim()
          .replace(/-([a-z])/g, (_match: string, letter: string) => letter.toUpperCase());
        return [name, parts.join(':').trim()];
      }),
  );

export interface EventArgumentSources {
  pageParameter?: EntityRecord | null;
  pageParameters?: RuntimeVariables;
  widgetValues?: RuntimeVariables;
  localVariables?: RuntimeVariables;
  snippetParameters?: RuntimeVariables;
}

const namedEventArgument = (
  source: RuntimeVariables | undefined,
  kind: string,
  name: string,
): RuntimeValue | undefined => {
  if (!source || !Object.prototype.hasOwnProperty.call(source, name)) {
    throw new Error(`Cannot resolve ${kind} event argument ${name || '(unnamed)'}`);
  }
  return source[name];
};

const structuredEventArgument = (
  argument: RuntimeValue | undefined,
  context: EntityRecord | null,
  sources: EventArgumentSources,
): RuntimeValue | undefined => {
  if (
    !argument ||
    typeof argument !== 'object' ||
    Array.isArray(argument) ||
    !('kind' in argument)
  ) {
    return argument;
  }

  const descriptor = argument as Record<string, RuntimeValue>;
  const kind = typeof descriptor.kind === 'string' ? descriptor.kind : '';
  const normalizedKind = kind.replace(/[^a-z]/gi, '').toLowerCase();
  const name = typeof descriptor.name === 'string' ? descriptor.name : '';
  switch (normalizedKind) {
    case 'current':
      return context;
    case 'pageparameter':
      if (sources.pageParameters && Object.hasOwn(sources.pageParameters, memberName(name)))
        return sources.pageParameters[memberName(name)];
      if (!Object.prototype.hasOwnProperty.call(sources, 'pageParameter')) {
        throw new Error(`Cannot resolve PageParameter event argument ${name || '(unnamed)'}`);
      }
      return sources.pageParameter;
    case 'widget':
      return namedEventArgument(sources.widgetValues, 'Widget', name);
    case 'localvariable':
      return namedEventArgument(sources.localVariables, 'LocalVariable', name);
    case 'snippetparameter':
      return namedEventArgument(sources.snippetParameters, 'SnippetParameter', memberName(name));
    default:
      throw new Error(`Unsupported event argument source ${kind || '(missing kind)'}`);
  }
};

export const eventArguments = (
  event: WidgetEvent | undefined,
  context: EntityRecord | null,
  sources: EventArgumentSources = {},
): RuntimeVariables =>
  Object.fromEntries(
    Object.entries(event?.arguments || {}).map(([name, argument]) => [
      name,
      typeof argument === 'string'
        ? expressionValue(argument, context, {
            ...sources.pageParameters,
            ...sources.localVariables,
            ...sources.snippetParameters,
          })
        : structuredEventArgument(argument, context, sources),
    ]),
  );

export const recordValue = (
  record: EntityRecord | null,
  attribute: string | undefined,
): RuntimeValue | undefined => attributes(record || undefined)[memberName(attribute)];

export const displayValue = (value: RuntimeValue | undefined): string | number | boolean => {
  if (value == null) return '';
  if (isDecimal(value)) return numericText(value);
  if (Array.isArray(value)) return value.map(displayValue).join(', ');
  if (isEntityRecord(value))
    return (
      (Object.values(value.attributes).find((item) =>
        ['string', 'number', 'boolean'].includes(typeof item),
      ) as string | number | boolean) || value.id
    );
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
};

export const choiceValue = (value: RuntimeValue, key: string): RuntimeValue | undefined => {
  if (isEntityRecord(value)) return key === 'id' ? value.id : value.attributes[key];
  if (value && typeof value === 'object' && !Array.isArray(value)) return value[key];
  return undefined;
};

export const draftValue = (value: RuntimeValue | undefined): string | number | boolean => {
  if (isEntityRecord(value)) return value.id;
  if (isDecimal(value)) return numericText(value);
  return ['string', 'number', 'boolean'].includes(typeof value)
    ? (value as string | number | boolean)
    : '';
};

export const apiFailure = (failure: unknown): ApiFailure =>
  failure instanceof Error ? (failure as ApiFailure) : new Error(String(failure));

// Mendix 11.12.1 database order: NULL first in both directions, strings without
// regard to case and without numeric collation, false before true.
export const compareSortValues = (
  left: RuntimeValue | undefined,
  right: RuntimeValue | undefined,
  descending = false,
): number => {
  if (left == null || right == null) return left == null ? (right == null ? 0 : -1) : 1;
  let result: number;
  if (isNumeric(left) && isNumeric(right)) result = numericCompare(left, right);
  else if (typeof left === 'boolean' && typeof right === 'boolean') result = Number(left) - Number(right);
  else {
    const a = numericText(left).toLowerCase();
    const b = numericText(right).toLowerCase();
    result = a < b ? -1 : a > b ? 1 : 0;
  }
  return descending ? -result : result;
};

export const sortRecords = (
  records: EntityRecord[],
  sortings: Array<{ attribute: string; direction?: string }> = [],
): EntityRecord[] => {
  const keys = sortings.map((sorting) => ({
    member: memberName(sorting.attribute),
    descending: sorting.direction === 'Descending',
  }));
  return records
    .map((record, index) => ({ record, index }))
    .sort((left, right) => {
      for (const { member, descending } of keys) {
        const comparison = compareSortValues(
          left.record.attributes?.[member],
          right.record.attributes?.[member],
          descending,
        );
        if (comparison !== 0) return comparison;
      }
      return left.index - right.index;
    })
    .map(({ record }) => record);
};
