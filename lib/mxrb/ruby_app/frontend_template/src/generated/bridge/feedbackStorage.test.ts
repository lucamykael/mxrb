import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { feedbackStorageActions } from './feedbackStorage';
import { NanoflowRuntime, registerJavaScriptActions } from './nanoflow';

const readName = 'JS_GetSingleStringLocalStorageObjectItem';
const showName = 'JS_GetShowEmailBooleanLocalStorageObjectItem';
const writeName = 'JS_SetSingleLocalStorageObjectItem';
const legacyName = 'JS_GetSingleLocalStorageObjectItem';
const actions = feedbackStorageActions([readName, showName, writeName, legacyName]);
const legacy = actions[`FeedbackModule.${legacyName}`];
const read = actions[`FeedbackModule.${readName}`];
const show = actions[`FeedbackModule.${showName}`];
const write = actions[`FeedbackModule.${writeName}`];
const parameters = { LocalStorageKey: 'feedback-test', ObjectItemKey: 'ShowEmail' };

beforeEach(() => {
  const data = new Map<string, string>();
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => { data.set(key, value); },
    clear: () => data.clear(),
  });
});

afterEach(() => {
  localStorage.clear();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  registerJavaScriptActions({});
});

describe('verified Feedback storage actions', () => {
  it('preserves the legacy empty-string fallback and native model parameter names', async () => {
    registerJavaScriptActions(actions);
    const runtime = new NanoflowRuntime({}, { name: 'Feedback.Test', id: 'test', parameters: [] });
    const expressions = { LocalStorageKey: "'feedback-test'", ObjectItemKey: "'ShowEmail'" };
    expect(await runtime.callJavaScript(`FeedbackModule.${legacyName}`, expressions)).toBe('');
    for (const value of [null, '', false, 0, 'text', ['item'], { nested: true }]) {
      localStorage.setItem('feedback-test', JSON.stringify({ ShowEmail: value }));
      expect(await runtime.callJavaScript(`FeedbackModule.${legacyName}`, expressions)).toEqual(value ?? '');
    }
    localStorage.setItem('feedback-test', 'invalid');
    await expect(legacy({ LocalStorageKey: 'feedback-test', ObjectItemKey: 'ShowEmail' })).rejects.toThrow(SyntaxError);
    await expect(legacy({})).rejects.toThrow("'localStorageKey' is required");
    await expect(legacy({ LocalStorageKey: 'feedback-test' })).rejects.toThrow("'objectItemKey' is required");
  });
  it('runs registered actions through the nanoflow expression and parameter bridge', async () => {
    registerJavaScriptActions(actions);
    const runtime = new NanoflowRuntime({}, { name: 'Feedback.Test', id: 'test', parameters: [] });
    await runtime.callJavaScript(`FeedbackModule.${writeName}`, {
      localStorageKey: "'feedback-test'", imageDataB64: "'from nanoflow'",
    });
    expect(await runtime.callJavaScript(`FeedbackModule.${readName}`, {
      LocalStorageKey: "'feedback-test'", ObjectItemKey: "'ImageB64'",
    })).toBe('from nanoflow');
  });
  it('preserves values and the native boolean fallback', async () => {
    expect(await read(parameters)).toBeNull();
    expect(await show(parameters)).toBe(true);
    for (const value of [false, true, 'false', null, 0]) {
      localStorage.setItem('feedback-test', JSON.stringify({ ShowEmail: value }));
      expect(await read(parameters)).toEqual(value);
      expect(await show(parameters)).toBe(typeof value === 'boolean' ? value : true);
    }
    localStorage.setItem('feedback-test', 'invalid JSON');
    await expect(read(parameters)).rejects.toThrow();
    expect(await show(parameters)).toBe(true);
  });

  it('writes an image without dropping stored attributes and exposes invalid primitive values', async () => {
    localStorage.setItem('feedback-test', '{"ShowEmail":false}');
    await write({ localStorageKey: 'feedback-test', imageDataB64: 'synthetic-image' });
    expect(JSON.parse(localStorage.getItem('feedback-test')!)).toEqual({ ShowEmail: false, ImageB64: 'synthetic-image' });
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    localStorage.setItem('feedback-test', 'invalid JSON');
    await write({ localStorageKey: 'feedback-test', imageDataB64: '' });
    expect(warn).toHaveBeenCalledOnce();
    expect(localStorage.getItem('feedback-test')).toBe('{"ImageB64":""}');
    localStorage.setItem('feedback-test', 'null');
    await expect(write({ localStorageKey: 'feedback-test', imageDataB64: 'x' })).rejects.toThrow(TypeError);
  });

  it('rejects missing parameters and unrecognized action names', async () => {
    await expect(read({})).rejects.toThrow("'localStorageKey' is required");
    await expect(read({ LocalStorageKey: 'feedback-test' })).rejects.toThrow("'objectItemKey' is required");
    await expect(show({})).rejects.toThrow("'localStorageKey' is required");
    await expect(write({})).rejects.toThrow("'localStorageKey' is required");
    expect(() => feedbackStorageActions(['Unknown'])).toThrow('Unknown Feedback storage action');
    expect(feedbackStorageActions([])).toEqual({});
  });
});
