import type { JavaScriptAction } from './nanoflow';
import { api } from './api';
import { isEntityRecord } from './value';

export const feedbackStrictMode: JavaScriptAction = async () => {
  // This Web runtime exposes object creation. As in the original callback API,
  // an asynchronous permission/network error does not mean strict mode.
  try {
    await api('/api/records/draft', {
      method: 'POST',
      body: JSON.stringify({ type: 'FeedbackModule.Feedback' }),
    });
  } catch {
    // The native action also returns false from its asynchronous error callback.
  }
  return false;
};

export const populateFeedbackMetadata: JavaScriptAction = async (
  { Feedback },
  _variables,
  environment = {},
) => {
  try {
    if (!isEntityRecord(Feedback))
      throw new Error('Feedback metadata requires an application record');
    Object.assign(Feedback.attributes, {
      ActiveUserRoles: environment.userRoles?.[0] || '',
      PageName: environment.pagePath || '',
      EnvironmentURL: window.location.href || '',
      Browser: navigator.userAgent || '',
    });
    // The original action passes an empty string for a zero dimension. Mendix
    // rejects that integer assignment, leaving this and subsequent fields intact.
    for (const [member, value] of [
      ['ScreenWidth', window.screen.width],
      ['ScreenHeight', window.screen.height],
    ] as const) {
      if (!value) throw new Error('Cannot assign an empty screen dimension to ' + member);
      Feedback.attributes[member] = value;
    }
    return Feedback;
  } catch (error) {
    console.error('Feedback Module cannot correctly set meta data.', error);
  }
};
