import { afterEach, describe, expect, it, vi } from 'vitest';
import { autofocusEnabled, focusWhenReady } from './autofocus';

const field = (name: string) => {
  const input = document.createElement('input');
  input.name = name;
  return input;
};

describe('autofocus', () => {
  afterEach(() => {
    vi.useRealTimers();
    document.body.replaceChildren();
  });

  it('reads the Autofocus setting of pages and popups', () => {
    expect(autofocusEnabled('Never')).toBe(false);
    expect(autofocusEnabled('Always')).toBe(true);
    expect(autofocusEnabled(undefined)).toBe(true);
  });

  it('waits for the container to settle and follows a replaced element', async () => {
    vi.useFakeTimers();
    const container = document.createElement('div');
    document.body.append(container);
    const stop = focusWhenReady(
      container,
      (root) => root.querySelector('input'),
      () => document.activeElement === document.body,
    );
    const late = field('password');
    container.append(late);
    await vi.advanceTimersByTimeAsync(50);
    const first = field('name');
    container.prepend(first);
    await vi.advanceTimersByTimeAsync(200);
    expect(first).toHaveFocus();

    const replacement = field('name');
    first.replaceWith(replacement);
    await vi.advanceTimersByTimeAsync(200);
    expect(replacement).toHaveFocus();

    const outside = field('outside');
    document.body.append(outside);
    outside.focus();
    replacement.replaceWith(field('again'));
    await vi.advanceTimersByTimeAsync(200);
    expect(outside).toHaveFocus();
    stop();
  });

  it('gives up when the focus moved before anything rendered, or after a while', async () => {
    vi.useFakeTimers();
    const container = document.createElement('div');
    document.body.append(container);
    const moved = focusWhenReady(container, (root) => root.querySelector('input'), () => false);
    container.append(field('name'));
    await vi.advanceTimersByTimeAsync(200);
    expect(document.activeElement).toBe(document.body);
    moved();

    const empty = document.createElement('div');
    document.body.append(empty);
    focusWhenReady(empty, (root) => root.querySelector('input'), () => true);
    await vi.advanceTimersByTimeAsync(10_500);
    empty.append(field('late'));
    await vi.advanceTimersByTimeAsync(200);
    expect(document.activeElement).toBe(document.body);
  });
});
