import type { JavaScriptAction } from './nanoflow';

let widgets = 0;
const pending = new Set<() => void>();

export function mountFeedbackCapture(): () => void {
  widgets += 1;
  return () => {
    widgets -= 1;
    if (widgets === 0) [...pending].forEach((cancel) => cancel());
  };
}

function capture(mode: 'Screenshot' | 'Annotate', value?: string): Promise<string | undefined> {
  if (!widgets) throw new Error('A verified Feedback widget must be visible to capture an image');
  if (pending.size) throw new Error('A Feedback image operation is already in progress');
  return new Promise((resolve) => {
    const finish = (result: string | undefined) => {
      window.removeEventListener('message', receive);
      pending.delete(cancel);
      resolve(result);
    };
    const cancel = () => finish(mode === 'Screenshot' ? 'uploadCancelled' : undefined);
    const receive = (event: MessageEvent) => {
      if (event.origin !== window.origin || typeof event.data !== 'string') return;
      let message: { messageActionType?: string; messageData?: string };
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      if (!message) return;
      if (message.messageActionType === 'mxFeedbackWidget_actionCancelled') cancel();
      if (message.messageActionType === 'mxFeedbackWidget_convertedToBase64')
        finish(message.messageData);
    };
    pending.add(cancel);
    window.addEventListener('message', receive);
    window.postMessage(
      JSON.stringify({
        messageActionType: `mxFeedbackWidget_toggle${mode}Mode`,
        messageData: value,
      }),
      window.origin,
    );
  });
}

export const feedbackScreenshot: JavaScriptAction = () => capture('Screenshot');
export const feedbackAnnotate: JavaScriptAction = ({ fileBlobURL }) =>
  capture('Annotate', String(fileBlobURL ?? ''));
