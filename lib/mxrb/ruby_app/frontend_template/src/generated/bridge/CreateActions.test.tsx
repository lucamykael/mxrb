import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { expect, it, vi } from 'vitest';
import { ApplicationRuntime } from './ApplicationRuntime';
import { api } from './api';
import type { PageDefinition } from '../types';

vi.mock('./api', () => ({ api: vi.fn(), setCsrfToken: vi.fn() }));
vi.mock('../nanoflows', () => ({ default: {} }));

it('discards associated drafts on cancel and commits both sides when the new object is saved', async () => {
  HTMLDialogElement.prototype.showModal = function () {
    this.open = true;
  };
  HTMLDialogElement.prototype.close = function () {
    this.open = false;
  };
  const parent = { type: 'App.Parent', id: 'parent', attributes: { Children: [] } };
  const child = { type: 'App.Child', id: 'draft', new_record: true, attributes: { Name: '' } };
  const home: PageDefinition = {
    name: 'App.Home',
    title: 'Home',
    data_source: { kind: 'microflow', name: 'App.Load' },
    widgets: [
      {
        name: 'create',
        type: 'button',
        options: { caption: 'Add child' },
        events: [
          {
            event: 'on_click',
            kind: 'action',
            handler: 'create_object',
            settings: {
              create: { entity: 'App.Child', association: 'App.Children', page: 'App.Editor' },
            },
          },
        ],
      },
    ],
  };
  const editor: PageDefinition = {
    name: 'App.Editor',
    title: 'Child',
    popup: { mode: 'modal' },
    parameters: [{ name: 'Child', type: { kind: 'object', entity: 'App.Child' } }],
    widgets: [
      { name: 'Name', type: 'text_box', options: { caption: 'Name', attribute: 'Name' } },
      {
        name: 'save',
        type: 'button',
        options: { caption: 'Save' },
        events: [{ event: 'on_click', kind: 'action', handler: 'save_changes' }],
      },
    ],
  };
  vi.mocked(api).mockReset();
  vi.mocked(api).mockImplementation(async (path, options) => {
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema')
      return {
        project: { name: 'App' },
        modules: [
          {
            name: 'App',
            pages: [home, editor],
            models: [{ name: 'App.Parent' }, { name: 'App.Child' }],
            associations: [
              {
                name: 'App.Children',
                from_entity: 'App.Parent',
                to_entity: 'App.Child',
                type: 'ReferenceSet',
              },
            ],
          },
        ],
      } as never;
    if (path === '/api/pages/App.Home') return home as never;
    if (path === '/api/pages/App.Editor') return editor as never;
    if (path === '/api/microflows/App.Load') return { result: parent } as never;
    if (path === '/api/entities/App.Parent/parent') return parent as never;
    if (path === '/api/records/draft') return structuredClone(child) as never;
    if (path === '/api/records/commit')
      return { records: JSON.parse(String(options?.body)).records } as never;
    throw new Error(`Unexpected request ${path}`);
  });
  render(
    <MemoryRouter>
      <ApplicationRuntime />
    </MemoryRouter>,
  );
  const user = userEvent.setup();
  await user.click(await screen.findByRole('button', { name: 'Add child' }));
  const first = await screen.findByRole('dialog', { name: 'Child' });
  await user.type(within(first).getByRole('textbox', { name: 'Name' }), 'Discarded');
  await user.click(within(first).getByRole('button', { name: 'Close' }));
  await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
  expect(api).not.toHaveBeenCalledWith('/api/records/commit', expect.anything());
  await user.click(screen.getByRole('button', { name: 'Add child' }));
  const second = await screen.findByRole('dialog', { name: 'Child' });
  const name = within(second).getByRole('textbox', { name: 'Name' });
  expect(name).toHaveValue('');
  await user.type(name, 'Saved');
  await user.click(within(second).getByRole('button', { name: 'Save' }));
  await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
  const call = vi.mocked(api).mock.calls.find(([path]) => path === '/api/records/commit')!;
  expect(JSON.parse(String(call[1]?.body)).records).toEqual([
    { type: 'App.Child', id: 'draft', new_record: true, attributes: { Name: 'Saved' } },
    { type: 'App.Parent', id: 'parent', attributes: { Children: [child] } },
  ]);
  expect(parent.attributes.Children).toEqual([]);
});
