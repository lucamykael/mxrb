import type { ApplicationSchema, AttributeDefinition } from '../types';

// Schema lookups shared by captions and expressions, without React or
// expression dependencies so both can import them.
let registered: ApplicationSchema | null = null;
export const registerExpressionSchema = (value: ApplicationSchema | null): void => {
  registered = value;
};
export const expressionSchema = (): ApplicationSchema | null => registered;

const object = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
const normalizedLocale = (value: string) => value.replaceAll('_', '-').toLowerCase();
export const translated = (text: string, translations: unknown, locale: string): string =>
  (Object.entries(object(translations)).find(
    ([language]) => normalizedLocale(language) === normalizedLocale(locale),
  )?.[1] as string) ?? text;

// The attribute of an entity or one of its generalizations.
export function attributeDefinition(
  schema: ApplicationSchema | null | undefined,
  type: string,
  attribute: string,
): AttributeDefinition | undefined {
  const entities = (schema?.modules ?? []).flatMap((module) => [
    ...(module.models ?? []),
    ...(module.dtos ?? []),
  ]);
  const name = attribute.split(/[./]/).pop() || '';
  let entity = entities.find((item) => item.name === type);
  const seen = new Set<string>();
  while (entity && !seen.has(entity.name)) {
    seen.add(entity.name);
    const member = entity.attributes?.find((item) => item.name === name);
    if (member) return member;
    const parent = entity.generalization?.target;
    entity = entities.find((item) => item.name === parent);
  }
}

export const enumerationDefinition = (schema: ApplicationSchema | null | undefined, name: string) =>
  schema?.modules
    .flatMap((module) => module.enumerations ?? [])
    .find((item) => item.name === name || item.id === name);
