import { afterEach, expect, it, vi } from 'vitest';
import { invokeAsync, waitForPoll } from './AsyncInvocation';
import type { ApiRequest } from '../types';

afterEach(() => vi.useRealTimers());

it('polls without repeating the submission, then delivers the result', async () => {
  vi.useFakeTimers();
  const request = vi
    .fn()
    .mockResolvedValueOnce({ id: 'job' })
    .mockResolvedValueOnce({ status: 'pending' })
    .mockResolvedValueOnce({ status: 'running' })
    .mockResolvedValueOnce({ status: 'completed', result: { result: 42 } });
  const operation = invokeAsync(
    request as ApiRequest,
    'App.Work',
    { Count: 2 },
    new AbortController().signal,
  );
  await vi.advanceTimersByTimeAsync(20000);
  await expect(operation).resolves.toEqual({ result: 42 });
  expect(request.mock.calls.map(([path]) => path)).toEqual([
    '/api/microflow-jobs',
    '/api/microflow-jobs/job',
    '/api/microflow-jobs/job',
    '/api/microflow-jobs/job',
  ]);
  expect(vi.getTimerCount()).toBe(0);
});

it('cancels the timer and discards late responses when the owner closes or signs out', async () => {
  vi.useFakeTimers();
  const controller = new AbortController();
  const request = vi
    .fn()
    .mockResolvedValueOnce({ id: 'job' })
    .mockResolvedValue({ status: 'pending' });
  const operation = invokeAsync(request as ApiRequest, 'App.Work', {}, controller.signal);
  const rejection = expect(operation).rejects.toMatchObject({ name: 'AbortError' });
  await vi.advanceTimersByTimeAsync(1);
  controller.abort();
  await rejection;
  await vi.advanceTimersByTimeAsync(30000);
  expect(request).toHaveBeenCalledTimes(2);
  expect(vi.getTimerCount()).toBe(0);
  await expect(waitForPoll(controller.signal)).rejects.toMatchObject({ name: 'AbortError' });
});

it('propagates failed jobs and rejects invalid results instead of applying output mappings', async () => {
  for (const state of [
    { status: 'failed', error: new Error('Work failed') },
    { status: 'completed' },
    { status: 'unknown' },
  ]) {
    const request = vi.fn().mockResolvedValueOnce({ id: 'job' }).mockResolvedValueOnce(state);
    await expect(
      invokeAsync(request as ApiRequest, 'App.Work', {}, new AbortController().signal),
    ).rejects.toBeInstanceOf(Error);
  }
});
