import { render, screen, waitFor } from '@testing-library/react';
import { useEffect, useState } from 'react';
import { describe, expect, it, vi } from 'vitest';
import type { PageComponentProps, PageDefinition } from '../../types';
import { PageOutlet } from './PageOutlet';

const page = {
  name: 'App.Home',
  title: 'Home',
  widgets: [{ type: 'container', name: 'body' }],
} as unknown as PageDefinition;

function Loaded({ children }: { children?: React.ReactNode }) {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const timer = setTimeout(() => setReady(true), 30);
    return () => clearTimeout(timer);
  }, []);
  return (
    <div>
      <button type="button" disabled>
        Disabled
      </button>
      <button type="button" hidden>
        Hidden
      </button>
      {ready && <button type="button">Start</button>}
      {children}
    </div>
  );
}

describe('PageOutlet', () => {
  it('focuses the first focusable element once the page renders it', async () => {
    render(
      <PageOutlet page={page} busy={false} Widget={Loaded as PageComponentProps['Widget']} />,
    );
    await waitFor(() => expect(screen.getByRole('button', { name: 'Start' })).toHaveFocus());
  });

  it.each([
    ['Never', 0, false],
    ['DesktopOnly', 5, false],
    ['DesktopOnly', 0, true],
    ['Always', 5, true],
  ])('follows the %s autofocus setting (touch points: %s)', async (autofocus, touch, focused) => {
    vi.stubGlobal('matchMedia', vi.fn().mockReturnValue({ matches: true }));
    Object.defineProperty(navigator, 'maxTouchPoints', { value: touch, configurable: true });
    render(
      <PageOutlet
        page={{ ...page, autofocus }}
        busy={false}
        Widget={Loaded as PageComponentProps['Widget']}
      />,
    );
    const start = await screen.findByRole('button', { name: 'Start' });
    if (focused) await waitFor(() => expect(start).toHaveFocus());
    else {
      await new Promise((resolve) => setTimeout(resolve, 300));
      expect(start).not.toHaveFocus();
    }
    Reflect.deleteProperty(navigator, 'maxTouchPoints');
    vi.unstubAllGlobals();
  });

  it('keeps the focus the user already moved', async () => {
    const outside = document.createElement('input');
    document.body.append(outside);
    outside.focus();
    render(
      <PageOutlet page={page} busy={false} Widget={Loaded as PageComponentProps['Widget']} />,
    );
    await screen.findByRole('button', { name: 'Start' });
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(outside).toHaveFocus();
    outside.remove();
  });
});
