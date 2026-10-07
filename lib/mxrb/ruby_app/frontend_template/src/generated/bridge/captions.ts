import { useContext, useSyncExternalStore } from 'react';
import type { ApplicationSchema, AttributeDefinition, EntityRecord, RuntimeValue } from '../types';
import { isDecimal, numericText } from './decimal';
import {
  LocalVariables,
  PageParameters,
  PageParameterBindings,
  SnippetParameterBindings,
} from './PageVariables';
import { VariableScope, WidgetObjectScope } from './components/VariableScope';
import { useSelections } from './components/SelectionScope';
import {
  eventArguments,
  expressionValue,
  isEntityRecord,
  memberName,
  type EventArgumentSources,
} from './value';

export interface CaptionEnvironment extends EventArgumentSources {
  locale: string;
  schema?: ApplicationSchema;
}
const locale = () => document.documentElement.lang || navigator.language || 'en-US';
const subscribeLocale = (notify: () => void) => {
  const observer = new MutationObserver(notify);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['lang'] });
  return () => observer.disconnect();
};

export function useCaptionEnvironment(schema?: ApplicationSchema): CaptionEnvironment {
  const selections = useSelections();
  return {
    locale: useSyncExternalStore(subscribeLocale, locale),
    schema,
    pageParameters: { ...useContext(PageParameters), ...useContext(PageParameterBindings).values },
    snippetParameters: {
      ...useContext(VariableScope),
      ...useContext(SnippetParameterBindings).values,
    },
    localVariables: useContext(LocalVariables).values,
    widgetValues: { ...useContext(WidgetObjectScope), ...selections.records, ...selections.lists },
  };
}

const object = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
const normalizedLocale = (value: string) => value.replaceAll('_', '-').toLowerCase();
const translated = (text: string, translations: unknown, locale: string): string =>
  (Object.entries(object(translations)).find(
    ([language]) => normalizedLocale(language) === normalizedLocale(locale),
  )?.[1] as string) ?? text;

function attributeDefinition(
  schema: ApplicationSchema | undefined,
  record: EntityRecord,
  attribute: string,
): AttributeDefinition | undefined {
  const entities = (schema?.modules ?? []).flatMap((module) => [
    ...(module.models ?? []),
    ...(module.dtos ?? []),
  ]);
  let entity = entities.find((item) => item.name === record.type);
  const seen = new Set<string>();
  while (entity && !seen.has(entity.name)) {
    seen.add(entity.name);
    const member = entity.attributes?.find((item) => item.name === memberName(attribute));
    if (member) return member;
    const parent = entity.generalization?.target;
    entity = entities.find((item) => item.name === parent);
  }
}

export function captionDate(
  value: string,
  format: Record<string, unknown>,
  locale: string,
  localize = true,
): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) throw new Error('Caption date is invalid');
  const zone = localize ? {} : { timeZone: 'UTC' };
  const part = (options: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat(locale, { ...zone, ...options }).format(date);
  const field = (local: number, utc: number) => (localize ? local : utc);
  const year = field(date.getFullYear(), date.getUTCFullYear());
  const month = field(date.getMonth(), date.getUTCMonth()) + 1;
  const day = field(date.getDate(), date.getUTCDate());
  const hour = field(date.getHours(), date.getUTCHours());
  const minute = field(date.getMinutes(), date.getUTCMinutes());
  const second = field(date.getSeconds(), date.getUTCSeconds());
  const pad = (number: number, length = 2) => String(number).padStart(length, '0');
  const kind = String(format.date_format ?? 'Date');
  if (kind !== 'Custom')
    return part({
      ...(kind !== 'Time' ? ({ year: 'numeric', month: 'numeric', day: 'numeric' } as const) : {}),
      ...(kind !== 'Date'
        ? ({ hour: 'numeric', minute: '2-digit', second: '2-digit' } as const)
        : {}),
    });
  const tokens: Record<string, string> = {
    y: String(year),
    yy: pad(year % 100),
    yyyy: pad(year, 4),
    M: String(month),
    MM: pad(month),
    MMM: part({ month: 'short' }),
    MMMM: part({ month: 'long' }),
    d: String(day),
    dd: pad(day),
    E: part({ weekday: 'short' }),
    EEE: part({ weekday: 'short' }),
    EEEE: part({ weekday: 'long' }),
    H: String(hour),
    HH: pad(hour),
    h: String(hour % 12 || 12),
    hh: pad(hour % 12 || 12),
    m: String(minute),
    mm: pad(minute),
    s: String(second),
    ss: pad(second),
    SSS: pad(date.getMilliseconds(), 3),
    a:
      new Intl.DateTimeFormat(locale, { ...zone, hour: 'numeric', hour12: true })
        .formatToParts(date)
        .find((item) => item.type === 'dayPeriod')?.value ?? '',
  };
  return String(format.custom_date_format ?? '').replace(
    /'(?:[^']|'')*'|([A-Za-z])\1*/g,
    (token) => {
      if (token === "''") return "'";
      if (token.startsWith("'")) return token.slice(1, -1).replaceAll("''", "'");
      if (!(token in tokens)) throw new Error(`Unsupported caption date token: ${token}`);
      return tokens[token];
    },
  );
}

function formatted(
  value: RuntimeValue | undefined,
  format: Record<string, unknown>,
  definition: AttributeDefinition | undefined,
  environment: CaptionEnvironment,
): string {
  if (value === null || value === undefined) return '';
  const locale = environment.locale.replaceAll('_', '-');
  const type = definition?.type.toLowerCase();
  if (type === 'datetime' || format.date_format || format.custom_date_format)
    return captionDate(String(value), format, locale, definition?.localize_date !== false);
  if (type === 'enumeration') {
    const enumeration = environment.schema?.modules
      .flatMap((module) => module.enumerations ?? [])
      .find((item) => item.name === definition?.enumeration || item.id === definition?.enumeration);
    const item = enumeration?.values.find((item) => item.name === value);
    return item ? translated(item.caption, item.caption_translations, locale) : String(value);
  }
  if (isDecimal(value) || typeof value === 'number' || ['decimal', 'integer', 'long'].includes(type ?? '')) {
    const precision = Number(
      format.decimal_precision ?? (type === 'integer' || type === 'long' ? 0 : 2),
    );
    const formatter = new Intl.NumberFormat(locale, {
      minimumFractionDigits: precision,
      maximumFractionDigits: precision,
      useGrouping: format.group_digits === true,
    });
    // Intl accepts decimal strings without first rounding them to binary numbers.
    return Reflect.apply(formatter.format, formatter, [numericText(value)]);
  }
  return String(value);
}

export function chartCaption(
  value: unknown,
  context: EntityRecord | null | undefined,
  environment: CaptionEnvironment = { locale: 'en-US' },
): string {
  if (value === undefined || value === null) return '';
  if (typeof value === 'string') return value;
  const template = object(value);
  if (
    typeof template.text !== 'string' ||
    (template.parameters !== undefined && !Array.isArray(template.parameters))
  )
    throw new Error('Chart caption requires text and expression parameters');
  let missing = false;
  const parameters = ((template.parameters as unknown[]) ?? []).map((raw) => {
    if (typeof raw === 'string') {
      const value = expressionValue(raw, context ?? null, {
        ...environment.pageParameters,
        ...environment.snippetParameters,
        ...environment.localVariables,
      });
      const definition =
        context && raw.startsWith('$currentObject/')
          ? attributeDefinition(environment.schema, context, raw.slice('$currentObject/'.length))
          : undefined;
      return definition ? formatted(value, {}, definition, environment) : numericText(value);
    }
    if (!raw || typeof raw !== 'object' || Array.isArray(raw))
      throw new Error('Chart caption requires text and expression parameters');
    const parameter = object(raw);
    if ((typeof parameter.expression !== 'string') === (typeof parameter.attribute !== 'string'))
      throw new Error('Chart caption parameter requires exactly one expression or attribute');
    const selected = parameter.source
      ? eventArguments(
          {
            event: 'caption',
            kind: 'caption',
            handler: '',
            arguments: { value: parameter.source as RuntimeValue },
          },
          context ?? null,
          environment,
        ).value
      : context;
    if (parameter.expression !== undefined)
      return numericText(
        expressionValue(
          String(parameter.expression),
          isEntityRecord(selected ?? undefined) ? (selected as EntityRecord) : null,
          {
            ...environment.pageParameters,
            ...environment.snippetParameters,
            ...environment.localVariables,
          },
        ) ?? '',
      );
    if (!isEntityRecord(selected ?? undefined)) {
      missing = true;
      return '';
    }
    const record = selected as EntityRecord;
    return formatted(
      record.attributes[memberName(String(parameter.attribute))],
      object(parameter.format),
      attributeDefinition(environment.schema, record, String(parameter.attribute)),
      environment,
    );
  });
  if (missing && typeof template.fallback === 'string') return template.fallback;
  const text = translated(template.text, template.translations, environment.locale);
  return text.replace(
    /\{(\d+)\}/g,
    (placeholder, index: string) => parameters[Number(index) - 1] ?? placeholder,
  );
}
