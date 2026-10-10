import type { NanoflowParameters, RuntimeValue } from '../types';
import type { JavaScriptAction } from './nanoflow';
import { writeStorageObject } from './objectStorage';
import { readStorageObject } from './objectRestore';
import { feedbackStrictMode, feedbackMetadataAction } from './feedbackMetadata';
import type { FeedbackMetadataVariant } from './feedbackMetadata';
import { feedbackScreenshot, feedbackAnnotate } from './feedbackCapture';
import {
  recalculateModalErrorZindex,
  revokeUploadedFileFromMemory,
  uploadAndConvertToFileBlobURL,
} from './feedbackFiles';

const required = (parameters: NanoflowParameters, name: string, label = name): string => {
  const value = parameters[name];
  if (!value) throw new Error(`Input parameter '${label}' is required`);
  return String(value);
};

const readString: JavaScriptAction = async (parameters) => {
  const key = required(parameters, 'LocalStorageKey', 'localStorageKey');
  const member = required(parameters, 'ObjectItemKey', 'objectItemKey');
  const value = JSON.parse(window.localStorage.getItem(key) ?? 'null') as Record<
    string,
    RuntimeValue
  > | null;
  return value?.[member] ?? null;
};

const readLegacy: JavaScriptAction = async (parameters) => (await readString(parameters)) ?? '';

const readShowEmail: JavaScriptAction = async (parameters) => {
  const key = required(parameters, 'LocalStorageKey', 'localStorageKey');
  const member = required(parameters, 'ObjectItemKey', 'objectItemKey');
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
  JS_ToggleFeedbackScreenshotWidget: feedbackScreenshot,
  JS_ToggleFeedbackAnnotateWidget: feedbackAnnotate,
  JS_isStrictMode: feedbackStrictMode,
  JS_GetFeedbackStorageObject: ({ key, entity }, variables) =>
    readStorageObject({ Key: key, Entity: entity }, variables),
  GetStorageItemObject: readStorageObject,
  JS_SetFeedbackStorageObject: ({ key, value }) => writeStorageObject({ Key: key, Value: value }),
  SetStorageItemObject: writeStorageObject,
  JS_GetSingleLocalStorageObjectItem: readLegacy,
  JS_GetSingleStringLocalStorageObjectItem: readString,
  JS_GetShowEmailBooleanLocalStorageObjectItem: readShowEmail,
  JS_SetSingleLocalStorageObjectItem: writeImage,
  JS_UploadAndConvertToFileBlobURL: uploadAndConvertToFileBlobURL,
  JS_RevokeUploadedFileFromMemory: revokeUploadedFileFromMemory,
  JS_Recalculate_MendixModal_Error_PopUp_Zindex: recalculateModalErrorZindex,
};

export const feedbackStorageActions = (
  names: string[],
  metadataVariant: FeedbackMetadataVariant = 'legacy',
): Record<string, JavaScriptAction> =>
  Object.fromEntries(
    names.map((name) => {
      const action =
        name === 'JS_PopulateFeedbackMetadata'
          ? feedbackMetadataAction(metadataVariant)
          : handlers[name];
      if (!action) throw new Error(`Unknown Feedback storage action: ${name}`);
      return [`FeedbackModule.${name}`, action];
    }),
  );
