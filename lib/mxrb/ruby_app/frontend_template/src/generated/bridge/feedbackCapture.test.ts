import { afterEach, describe, expect, it, vi } from 'vitest';
import { feedbackAnnotate, feedbackScreenshot, mountFeedbackCapture } from './feedbackCapture';

const send = (data: unknown, origin = window.origin) =>
  window.dispatchEvent(new MessageEvent('message', { data, origin }));
const message = (messageActionType: string, messageData?: string) =>
  send(JSON.stringify({ messageActionType: `mxFeedbackWidget_${messageActionType}`, messageData }));

afterEach(() => vi.restoreAllMocks());

describe('Feedback capture protocol', () => {
  it('requires a mounted verified widget and rejects overlapping operations', async () => {
    expect(() => feedbackScreenshot({})).toThrow('verified Feedback widget');
    const unmount = mountFeedbackCapture();
    const post = vi.spyOn(window, 'postMessage').mockImplementation(() => {});
    const result = feedbackScreenshot({});
    expect(post).toHaveBeenCalledWith(
      JSON.stringify({ messageActionType: 'mxFeedbackWidget_toggleScreenshotMode' }),
      window.origin,
    );
    expect(() => feedbackAnnotate({ fileBlobURL: 'blob:test' })).toThrow('already in progress');
    message('actionCancelled');
    await expect(result).resolves.toBe('uploadCancelled');
    unmount();
  });

  it('ignores foreign and malformed messages and returns the image unchanged', async () => {
    const unmount = mountFeedbackCapture();
    vi.spyOn(window, 'postMessage').mockImplementation(() => {});
    const result = feedbackScreenshot({});
    send(
      JSON.stringify({ messageActionType: 'mxFeedbackWidget_actionCancelled' }),
      'https://foreign.invalid',
    );
    send({ messageActionType: 'mxFeedbackWidget_actionCancelled' });
    send('not JSON');
    send('null');
    message('unrelated');
    message('convertedToBase64', 'data:image/png;base64,unchanged');
    await expect(result).resolves.toBe('data:image/png;base64,unchanged');
    unmount();
  });

  it('passes the annotation URL, preserves its empty cancellation and removes listeners', async () => {
    const unmount = mountFeedbackCapture();
    const post = vi.spyOn(window, 'postMessage').mockImplementation(() => {});
    const remove = vi.spyOn(window, 'removeEventListener');
    const result = feedbackAnnotate({ fileBlobURL: 'blob:source-image' });
    expect(post).toHaveBeenCalledWith(
      JSON.stringify({
        messageActionType: 'mxFeedbackWidget_toggleAnnotateMode',
        messageData: 'blob:source-image',
      }),
      window.origin,
    );
    message('actionCancelled');
    await expect(result).resolves.toBeUndefined();
    expect(remove).toHaveBeenCalledWith('message', expect.any(Function));
    const repeated = feedbackAnnotate({});
    message('convertedToBase64', 'data:image/png;base64,edited');
    await expect(repeated).resolves.toBe('data:image/png;base64,edited');
    unmount();
  });

  it('cancels pending work only when the last widget unmounts', async () => {
    const first = mountFeedbackCapture();
    const second = mountFeedbackCapture();
    vi.spyOn(window, 'postMessage').mockImplementation(() => {});
    const result = feedbackScreenshot({});
    first();
    expect(() => feedbackScreenshot({})).toThrow('already in progress');
    second();
    await expect(result).resolves.toBe('uploadCancelled');
  });
});
