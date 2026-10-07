import type { NanoflowParameters, RuntimeValue } from '../types';
import type { JavaScriptAction } from './nanoflow';

const required = (parameters: NanoflowParameters, name: string): string => {
  const value = parameters[name];
  if (!value) throw new Error(`Input parameter '${name}' is required`);
  return String(value);
};

const readString: JavaScriptAction = async (parameters) => {
  const key = required(parameters, 'localStorageKey');
  const member = required(parameters, 'objectItemKey');
  const value = JSON.parse(window.localStorage.getItem(key) ?? 'null') as Record<string, RuntimeValue> | null;
  return value?.[member] ?? null;
};

const readShowEmail: JavaScriptAction = async (parameters) => {
  const key = required(parameters, 'localStorageKey');
  const member = required(parameters, 'objectItemKey');
  const source = window.localStorage.getItem(key);
  if (!source) return true;
  let value: Record<string, unknown> | null;
  try {
    value = JSON.parse(source) as Record<string, unknown> | null;
  } catch {
    return true;
  }
  const result = value?.[member];
  return typeof result === 'boolean' ? result : true;
};

const writeImage: JavaScriptAction = async (parameters) => {
  const key = required(parameters, 'localStorageKey');
  const source = window.localStorage.getItem(key);
  let value: Record<string, RuntimeValue | undefined> = {};
  if (source) {
    try {
      value = JSON.parse(source) as Record<string, RuntimeValue | undefined>;
    } catch (error) {
      console.warn('Failed to parse existing localStorage data. Overwriting.', error);
    }
  }
  value.ImageB64 = parameters.imageDataB64;
  window.localStorage.setItem(key, JSON.stringify(value));
};

const handlers: Record<string, JavaScriptAction> = {
  JS_GetSingleStringLocalStorageObjectItem: readString,
  JS_GetShowEmailBooleanLocalStorageObjectItem: readShowEmail,
  JS_SetSingleLocalStorageObjectItem: writeImage,
};

export const feedbackStorageActions = (names: string[]): Record<string, JavaScriptAction> =>
  Object.fromEntries(names.map((name) => {
    const action = handlers[name];
    if (!action) throw new Error(`Unknown Feedback storage action: ${name}`);
    return [`FeedbackModule.${name}`, action];
  }));
