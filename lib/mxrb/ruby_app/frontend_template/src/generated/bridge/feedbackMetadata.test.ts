import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { EntityRecord } from '../types';
import { api } from './api';
import { feedbackStorageActions } from './feedbackStorage';
import { feedbackStrictMode, populateFeedbackMetadata } from './feedbackMetadata';
import { defineNanoflow, registerJavaScriptActions, registerNanoflows } from './nanoflow';
vi.mock('./api', () => ({ api: vi.fn() }));
const record: EntityRecord = {
  id: 'feedback',
  type: 'FeedbackModule.Feedback',
  transient: true,
  attributes: { Name: 'Original' },
};
beforeEach(() => {
  vi.resetAllMocks();
  vi.spyOn(window.screen, 'width', 'get').mockReturnValue(1440);
  vi.spyOn(window.screen, 'height', 'get').mockReturnValue(900);
  registerJavaScriptActions(
    feedbackStorageActions(['JS_isStrictMode', 'JS_PopulateFeedbackMetadata']),
  );
});
afterEach(() => {
  vi.restoreAllMocks();
  registerJavaScriptActions({});
  registerNanoflows({});
});
describe('Feedback browser metadata', () => {
  it('keeps screen and viewport variants distinct, including numeric zero and null fallbacks', async () => {
    vi.stubGlobal('innerWidth', 1024);
    vi.stubGlobal('innerHeight', 768);
    const screenAction = feedbackStorageActions(['JS_PopulateFeedbackMetadata'], 'screen')[
      'FeedbackModule.JS_PopulateFeedbackMetadata'
    ];
    const viewportAction = feedbackStorageActions(['JS_PopulateFeedbackMetadata'], 'viewport')[
      'FeedbackModule.JS_PopulateFeedbackMetadata'
    ];
    expect(await screenAction({ Feedback: structuredClone(record) })).toMatchObject({
      attributes: { ScreenWidth: 1440, ScreenHeight: 900 },
    });
    expect(await viewportAction({ Feedback: structuredClone(record) })).toMatchObject({
      attributes: { ScreenWidth: 1024, ScreenHeight: 768 },
    });
    vi.spyOn(window.screen, 'width', 'get').mockReturnValue(0);
    vi.spyOn(window.screen, 'height', 'get').mockReturnValue(0);
    vi.stubGlobal('innerWidth', 0);
    vi.stubGlobal('innerHeight', 0);
    expect(await screenAction({ Feedback: structuredClone(record) })).toMatchObject({
      attributes: { ScreenWidth: 0, ScreenHeight: 0 },
    });
    expect(await viewportAction({ Feedback: structuredClone(record) })).toMatchObject({
      attributes: { ScreenWidth: null, ScreenHeight: null },
    });
    vi.unstubAllGlobals();
  });
  it('preserves integer dimensions when the native empty-dimension assignment fails', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(window.screen, 'width', 'get').mockReturnValue(0);
    const item = {
      ...structuredClone(record),
      attributes: { ScreenWidth: 800, ScreenHeight: 600 },
    };
    expect(
      await populateFeedbackMetadata({ Feedback: item }, {}, { pagePath: 'App.Home' }),
    ).toBeUndefined();
    expect(item.attributes).toMatchObject({
      ScreenWidth: 800,
      ScreenHeight: 600,
      PageName: 'App.Home',
    });
    vi.spyOn(window.screen, 'width', 'get').mockReturnValue(1440);
    vi.spyOn(window.screen, 'height', 'get').mockReturnValue(0);
    expect(await populateFeedbackMetadata({ Feedback: item })).toBeUndefined();
    expect(item.attributes).toMatchObject({ ScreenWidth: 1440, ScreenHeight: 600 });
  });
  it('preserves identity and uses the current page, first role, browser, location and screen', async () => {
    const item = structuredClone(record);
    const result = await populateFeedbackMetadata(
      { Feedback: item },
      {},
      { pagePath: 'App/Home.page.xml', userRoles: ['Editor', 'Reviewer'] },
    );
    expect(result).toBe(item);
    expect(item.attributes).toEqual({
      Name: 'Original',
      ActiveUserRoles: 'Editor',
      PageName: 'App/Home.page.xml',
      EnvironmentURL: window.location.href,
      Browser: navigator.userAgent,
      ScreenWidth: 1440,
      ScreenHeight: 900,
    });
  });
  it('tracks mutations even when the generated action ignores its return and preserves nested invocation context', async () => {
    const child = defineNanoflow(
      { name: 'Feedback.Child', id: 'child', parameters: ['Item'] },
      async (runtime) => {
        await runtime.callJavaScript('FeedbackModule.JS_PopulateFeedbackMetadata', {
          Feedback: '$Item',
        });
        return runtime.complete(runtime.variables.Item);
      },
    );
    registerNanoflows({ 'Feedback.Child': child });
    const parent = defineNanoflow(
      { name: 'Feedback.Parent', id: 'parent', parameters: ['Item'] },
      async (runtime) =>
        runtime.complete(await runtime.callNanoflow('Feedback.Child', { Item: '$Item' })),
    );
    const execution = await parent.execute({ Item: record }, undefined, {
      pagePath: 'App/Dialog.page.xml',
      userRoles: ['DialogUser'],
    });
    expect(execution.changes).toHaveLength(1);
    expect(execution.changes[0].attributes).toMatchObject({
      PageName: 'App/Dialog.page.xml',
      ActiveUserRoles: 'DialogUser',
    });
    expect(record.attributes).toEqual({ Name: 'Original' });
  });
  it('uses empty values for unavailable roles/page and preserves the native error return', async () => {
    expect(await populateFeedbackMetadata({ Feedback: structuredClone(record) })).toMatchObject({
      attributes: { PageName: '', ActiveUserRoles: '' },
    });
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(await populateFeedbackMetadata({ Feedback: null })).toBeUndefined();
    expect(error).toHaveBeenCalledWith(
      'Feedback Module cannot correctly set meta data.',
      expect.any(Error),
    );
  });
  it('probes Web object creation and returns false on success or asynchronous failure', async () => {
    vi.mocked(api)
      .mockResolvedValueOnce(record)
      .mockRejectedValueOnce(new Error('Creation denied'));
    expect(await feedbackStrictMode({})).toBe(false);
    expect(await feedbackStrictMode({})).toBe(false);
    expect(api).toHaveBeenCalledWith('/api/records/draft', {
      method: 'POST',
      body: JSON.stringify({ type: 'FeedbackModule.Feedback' }),
    });
  });
});
