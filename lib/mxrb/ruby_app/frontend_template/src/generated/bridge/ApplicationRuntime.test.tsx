import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { ApplicationRuntime } from './ApplicationRuntime';
import { api } from './api';

vi.mock('./api', () => ({ api: vi.fn(), setCsrfToken: vi.fn() }));
vi.mock('../nanoflows', () => ({ default: {} }));

describe('application field lifetime', () => {
  it.each([false, true])(
    'persists server records and reports failed writes (missing: %s)',
    async (missing) => {
      vi.mocked(api).mockReset();
      const record = { id: '1', type: 'App.Item', attributes: { Name: 'Before' } };
      const page = {
        name: 'App.Home',
        title: 'Home',
        data_source: { kind: 'microflow', name: 'App.Load' },
        widgets: [
          {
            name: 'Name',
            type: 'text_box',
            options: { attribute: 'App.Item.Name', caption: 'Name' },
          },
        ],
      };
      vi.mocked(api).mockImplementation(async (path, options) => {
        if (path === '/api/session') return { user: 'tester' } as never;
        if (path === '/api/schema')
          return { project: { name: 'App' }, modules: [{ name: 'App', pages: [page] }] } as never;
        if (path === '/api/pages/App.Home') return page as never;
        if (path === '/api/microflows/App.Load') return { result: record } as never;
        if (path === '/api/entities/App.Item/1' && options?.method === 'PATCH') {
          if (missing) throw Object.assign(new Error('Record no longer exists'), { status: 404 });
          return { ...record, attributes: JSON.parse(String(options.body)) } as never;
        }
        throw new Error(`Unexpected request ${path}`);
      });
      render(
        <MemoryRouter>
          <ApplicationRuntime />
        </MemoryRouter>,
      );
      const user = userEvent.setup();
      const field = await screen.findByRole('textbox', { name: 'Name' });
      await user.clear(field);
      await user.type(field, 'Persisted edit');
      await user.tab();
      await waitFor(() =>
        expect(api).toHaveBeenCalledWith('/api/entities/App.Item/1', {
          method: 'PATCH',
          body: '{"Name":"Persisted edit"}',
        }),
      );
      if (missing)
        expect(await screen.findByRole('alert')).toHaveTextContent('Record no longer exists');
      else expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    },
  );

  it('keeps the focused input and draft mounted while a focus action updates application state', async () => {
    const record = { id: '1', type: 'App.Item', attributes: { Name: 'Before' } };
    const page = {
      name: 'App.Home',
      title: 'Home',
      data_source: { kind: 'microflow', name: 'App.Load' },
      widgets: [
        {
          name: 'Name',
          type: 'text_box',
          options: { attribute: 'App.Item.Name', caption: 'Name' },
          events: [{ event: 'on_enter', kind: 'microflow', handler: 'App.Focus' }],
        },
      ],
    };
    vi.mocked(api).mockImplementation(async (path) => {
      if (path === '/api/session') return { user: 'tester', csrf: 'test' } as never;
      if (path === '/api/schema')
        return { project: { name: 'App' }, modules: [{ name: 'App', pages: [page] }] } as never;
      if (path === '/api/pages/App.Home') return page as never;
      if (path === '/api/microflows/App.Load') return { result: record } as never;
      if (path === '/api/microflows/App.Focus') return { result: null } as never;
      throw new Error(`Unexpected request ${path}`);
    });
    render(
      <MemoryRouter>
        <ApplicationRuntime />
      </MemoryRouter>,
    );
    const user = userEvent.setup();
    const field = await screen.findByRole('textbox', { name: 'Name' });
    await user.click(field);
    await waitFor(() =>
      expect(api).toHaveBeenCalledWith('/api/microflows/App.Focus', expect.anything()),
    );
    expect(screen.getByRole('textbox', { name: 'Name' })).toBe(field);
    expect(field).toHaveFocus();
    await user.type(field, ' draft');
    expect(field).toHaveValue('Before draft');
  });
});
