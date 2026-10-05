import type { ApiFailure, ApiRequest, InvocationResult, RuntimeVariables } from '../types';

export function waitForPoll(signal: AbortSignal, milliseconds = 10000): Promise<void> {
  return new Promise((resolve, reject) => {
    signal.throwIfAborted();
    const abort = () => {
      clearTimeout(timer);
      reject(signal.reason);
    };
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', abort);
      resolve();
    }, milliseconds);
    signal.addEventListener('abort', abort, { once: true });
  });
}

export async function invokeAsync(
  request: ApiRequest,
  name: string,
  parameters: RuntimeVariables,
  signal: AbortSignal,
): Promise<InvocationResult> {
  signal.throwIfAborted();
  const job = await request<{ id: string }>('/api/microflow-jobs', {
    method: 'POST',
    body: JSON.stringify({ name, arguments: parameters }),
    signal,
  });
  for (;;) {
    signal.throwIfAborted();
    const state = await request<{
      status: string;
      result?: InvocationResult;
      error?: ApiFailure;
    }>(`/api/microflow-jobs/${encodeURIComponent(job.id)}`, { signal });
    signal.throwIfAborted();
    if (state.status === 'completed') {
      if (!state.result) throw new Error('Asynchronous invocation returned no result');
      return state.result;
    }
    if (state.status === 'failed') throw state.error || new Error('Asynchronous invocation failed');
    if (!['pending', 'running'].includes(state.status))
      throw new Error(`Unknown asynchronous invocation status: ${state.status}`);
    await waitForPoll(signal);
  }
}
