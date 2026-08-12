import type { CSSProperties } from 'react';
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
): RuntimeValue | undefined => {
  const text = (source || '').trim();
  const wrapped = text.match(/^toString\((.*)\)$/);
  if (wrapped) return String(expressionValue(wrapped[1], context, variables) ?? '');
  if (text === '$currentObject') return context;
  const variable = text.match(/^\$([A-Za-z_]\w*)$/);
  if (variable) return variables[variable[1]] ?? context;
  const member = text.match(/^\$([A-Za-z_]\w*)\/([A-Za-z_][\w.]*)$/);
  if (member) return attributes(variables[member[1]] ?? context)[memberName(member[2])];
  if (text === 'empty') return null;
  if (text === 'true') return true;
  if (text === 'false') return false;
  if (/^'.*'$/.test(text)) return text.slice(1, -1).replaceAll("''", "'");
  return text;
};

export const conditionValue = (
  source: string | undefined,
  context: EntityRecord | null,
  variables: RuntimeVariables = {},
): boolean => {
  const text = (source || '').trim().replace(/^\((.*)\)$/, '$1');
  const orParts = text.split(/\s+or\s+/);
  if (orParts.length > 1) return orParts.some((part) => conditionValue(part, context, variables));
  const andParts = text.split(/\s+and\s+/);
  if (andParts.length > 1)
    return andParts.every((part) => conditionValue(part, context, variables));
  const comparison = text.match(/^(.*?)\s*(=|!=|>=|<=|>|<)\s*(.*?)$/);
  if (!comparison) return Boolean(expressionValue(text, context, variables));
  const left = expressionValue(comparison[1], context, variables);
  const right = expressionValue(comparison[3], context, variables);
  if (comparison[2] === '=') return left === right;
  if (comparison[2] === '!=') return left !== right;
  const comparable = (value: RuntimeValue | undefined): string | number =>
    typeof value === 'number' ? value : String(value ?? '');
  if (comparison[2] === '>') return comparable(left) > comparable(right);
  if (comparison[2] === '<') return comparable(left) < comparable(right);
  if (comparison[2] === '>=') return comparable(left) >= comparable(right);
  return comparable(left) <= comparable(right);
};

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
    (_match: string, member: string) => String(attributes(context)[memberName(member)] ?? ''),
  );
  text = text.replace(/\$[A-Za-z_]\w*\/([A-Za-z_][\w.]*)/g, (_match: string, member: string) =>
    String(attributes(context)[memberName(member)] ?? ''),
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
): string => {
  let value = options.caption || widget.caption || widget.name;
  (options.parameters || []).forEach((parameter, index) => {
    value = value.replaceAll(`{${index + 1}}`, String(expressionValue(parameter, context) ?? ''));
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

export const eventArguments = (
  event: WidgetEvent | undefined,
  context: EntityRecord | null,
): RuntimeVariables =>
  Object.fromEntries(
    Object.entries(event?.arguments || {}).map(([name, expression]) => [
      name,
      expressionValue(expression, context),
    ]),
  );

export const recordValue = (
  record: EntityRecord | null,
  attribute: string | undefined,
): RuntimeValue | undefined => attributes(record || undefined)[memberName(attribute)];

export const displayValue = (value: RuntimeValue | undefined): string | number | boolean => {
  if (value == null) return '';
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
  return ['string', 'number', 'boolean'].includes(typeof value)
    ? (value as string | number | boolean)
    : '';
};

export const apiFailure = (failure: unknown): ApiFailure =>
  failure instanceof Error ? (failure as ApiFailure) : new Error(String(failure));

export const sortRecords = (
  records: EntityRecord[],
  sortings: Array<{ attribute: string; direction?: string }> = [],
): EntityRecord[] => {
  const result = records.slice();
  sortings
    .slice()
    .reverse()
    .forEach((sorting) => {
      const member = memberName(sorting.attribute);
      const direction = sorting.direction === 'Descending' ? -1 : 1;
      result.sort(
        (left, right) =>
          direction *
          String(left.attributes?.[member] ?? '').localeCompare(
            String(right.attributes?.[member] ?? ''),
            undefined,
            { numeric: true },
          ),
      );
    });
  return result;
};
