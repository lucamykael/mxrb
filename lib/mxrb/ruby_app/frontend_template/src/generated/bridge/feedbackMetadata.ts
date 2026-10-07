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

export type FeedbackMetadataVariant = 'legacy' | 'screen' | 'viewport';

export const feedbackMetadataAction =
  (variant: FeedbackMetadataVariant): JavaScriptAction =>
  async ({ Feedback }, _variables, environment = {}) => {
    try {
      if (!isEntityRecord(Feedback))
        throw new Error('Feedback metadata requires an application record');
      Object.assign(Feedback.attributes, {
        ActiveUserRoles: environment.userRoles?.[0] || '',
        PageName: environment.pagePath || '',
        EnvironmentURL: window.location.href || '',
        Browser: navigator.userAgent || '',
      });
      // Source-verified variants differ in both the dimension source and the zero
      // fallback; these values must not be normalized to one shared behavior.
      for (const [member, value] of [
        ['ScreenWidth', variant === 'viewport' ? window.innerWidth : window.screen.width],
        ['ScreenHeight', variant === 'viewport' ? window.innerHeight : window.screen.height],
      ] as const) {
        if (variant === 'legacy' && !value)
          throw new Error('Cannot assign an empty screen dimension to ' + member);
        Feedback.attributes[member] = variant === 'viewport' ? value || null : value;
      }
      return Feedback;
    } catch (error) {
      console.error('Feedback Module cannot correctly set meta data.', error);
    }
  };

export const populateFeedbackMetadata = feedbackMetadataAction('legacy');
