import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApplicationRuntime } from './ApplicationRuntime';
import { api } from './api';
import type { PageDefinition } from '../types';

vi.mock('./api', () => ({ api: vi.fn(), setCsrfToken: vi.fn() }));
vi.mock('../nanoflows', () => ({ default: {} }));

beforeEach(() => {
  HTMLDialogElement.prototype.showModal = function () {
    this.open = true;
  };
  HTMLDialogElement.prototype.show = function () {
    this.open = true;
  };
  HTMLDialogElement.prototype.close = function () {
    this.open = false;
  };
});

const record = { id: '1', type: 'App.Item', attributes: { Name: 'Original' } };
const field = { name: 'name', type: 'text_box', options: { attribute: 'Name', caption: 'Name' } };
const home: PageDefinition = {
  name: 'App.Home',
  title: 'Home',
  data_source: { kind: 'microflow', name: 'App.Load' },
  widgets: [
    field,
    {
      name: 'apply',
      type: 'button',
      options: { caption: 'Owner' },
      events: [{ event: 'on_click', kind: 'page', handler: 'App.Owner', arguments: {} }],
    },
    {
      name: 'edit',
      type: 'button',
      options: { caption: 'Edit' },
      events: [
        {
          event: 'on_click',
          kind: 'page',
          handler: 'App.Editor',
          arguments: { Item: '$currentObject', Title: "'Passed title'" },
        },
      ],
    },
  ],
};
const editor: PageDefinition = {
  name: 'App.Editor',
  title: 'Editor',
  popup: { mode: 'modal', width: 520, resizable: false },
  parameters: [
    { name: 'Item', type: { kind: 'object', entity: 'App.Item' } },
    { name: 'Title', type: { kind: 'string' } },
  ],
  variables: [{ name: 'DraftTitle', type: { kind: 'string' }, default: '$Title' }],
  widgets: [
    field,
    {
      name: 'local',
      type: 'text_box',
      options: {
        caption: 'Local title',
        source_variable: { kind: 'local_variable', name: 'DraftTitle' },
      },
    },
    {
      name: 'save',
      type: 'button',
      options: { caption: 'Save' },
      events: [{ event: 'on_click', kind: 'action', handler: 'save_changes' }],
    },
  ],
};

// A popup editing an object reached through an association, saved by a microflow.
const ownerPopup: PageDefinition = {
  name: 'App.Owner',
  title: 'Owner',
  popup: { mode: 'modal' },
  parameters: [{ name: 'Item', type: { kind: 'object', entity: 'App.Item' } }],
  widgets: [
    {
      name: 'owner',
      type: 'data_view',
      options: {
        source: {
          kind: 'association',
          entity: 'App.Person',
          steps: [{ association: 'App.Item_Person', entity: 'App.Person' }],
        },
      },
      body: [{ name: 'person', type: 'text_box', options: { attribute: 'Name', caption: 'Person' } }],
    },
    {
      name: 'apply',
      type: 'button',
      options: { caption: 'Apply' },
      events: [{ event: 'on_click', kind: 'microflow', handler: 'App.Apply' }],
    },
  ],
};
const person = {
  id: 'p',
  type: 'App.Person',
  attributes: { Name: 'Before' },
  new_record: true,
  draft_token: 'token',
};

function setup() {
  vi.mocked(api).mockReset();
  vi.mocked(api).mockImplementation(async (path, options) => {
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema')
      return {
        project: { name: 'App' },
        modules: [{ name: 'App', models: [{ name: 'App.Item' }], pages: [home, editor, ownerPopup] }],
      } as never;
    if (path === '/api/pages/App.Home') return home as never;
    if (path === '/api/pages/App.Editor') return editor as never;
    if (path === '/api/pages/App.Owner') return ownerPopup as never;
    if (path.startsWith('/api/entities/App.Person?')) return { records: [person] } as never;
    if (path === '/api/microflows/App.Apply')
      return { result: null, effects: [{ type: 'close_page', count: 1 }] } as never;
    if (path === '/api/microflows/App.Load') return { result: record } as never;
    if (path === '/api/entities/App.Item/1') return record as never;
    if (path === '/api/records/commit')
      return { records: JSON.parse(String(options?.body)).records } as never;
    throw new Error(`Unexpected request ${path}`);
  });
  render(
    <MemoryRouter>
      <ApplicationRuntime />
    </MemoryRouter>,
  );
  return userEvent.setup();
}

describe('popup page lifetime', () => {
  it('keeps the background mounted, binds named parameters and local inputs, and rolls back dismissal', async () => {
    const user = setup();
    const background = await screen.findByRole('textbox', { name: 'Name' });
    await user.click(screen.getByRole('button', { name: 'Edit' }));
    const popup = await screen.findByRole('dialog', { name: 'Editor' });
    expect(popup).toHaveAttribute('aria-modal', 'true');
    expect(popup).toHaveStyle({ width: '520px', resize: 'none' });
    expect(background.isConnected).toBe(true);
    const local = within(popup).getByRole('textbox', { name: 'Local title' });
    expect(local).toHaveValue('Passed title');
    await user.clear(local);
    await user.type(local, 'Local edit');
    const input = within(popup).getByRole('textbox', { name: 'Name' });
    await user.clear(input);
    await user.type(input, 'Discarded');
    await user.click(within(popup).getByRole('button', { name: 'Close' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(background).toHaveValue('Original');
    expect(api).not.toHaveBeenCalledWith('/api/records/commit', expect.anything());
    expect(api).not.toHaveBeenCalledWith(
      '/api/entities/App.Item/1',
      expect.objectContaining({ method: 'PATCH' }),
    );
    expect(screen.getByRole('button', { name: 'Edit' })).toHaveFocus();
  });

  it('commits edited objects atomically and closes the popup without replacing its background', async () => {
    const user = setup();
    const background = await screen.findByRole('textbox', { name: 'Name' });
    await user.click(screen.getByRole('button', { name: 'Edit' }));
    const popup = await screen.findByRole('dialog');
    const input = within(popup).getByRole('textbox', { name: 'Name' });
    await user.clear(input);
    await user.type(input, 'Saved');
    await user.click(within(popup).getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(api).toHaveBeenCalledWith('/api/records/commit', {
      method: 'POST',
      body: JSON.stringify({
        records: [{ type: 'App.Item', id: '1', attributes: { Name: 'Saved' } }],
      }),
    });
    expect(background.isConnected).toBe(true);
  });

  it('sends the objects a popup edited with its microflow and refreshes the page beneath', async () => {
    const user = setup();
    await screen.findByRole('textbox', { name: 'Name' });
    await user.click(screen.getByRole('button', { name: 'Owner' }));
    const popup = await screen.findByRole('dialog', { name: 'Owner' });
    const input = await within(popup).findByRole('textbox', { name: 'Person' });
    await user.clear(input);
    await user.type(input, 'After');
    const reloads = vi
      .mocked(api)
      .mock.calls.filter(([path]) => path === '/api/entities/App.Item/1').length;
    await user.click(within(popup).getByRole('button', { name: 'Apply' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    const call = vi.mocked(api).mock.calls.find(([path]) => path === '/api/microflows/App.Apply');
    const body = JSON.parse(String(call?.[1]?.body));
    expect(body.__mxrb_changes).toEqual([
      {
        type: 'App.Person',
        id: 'p',
        attributes: { Name: 'After' },
        new_record: true,
        draft_token: 'token',
      },
    ]);
    expect(body.__mxrb_context).toMatchObject({ type: 'App.Item', id: '1' });
    await waitFor(() =>
      expect(
        vi.mocked(api).mock.calls.filter(([path]) => path === '/api/entities/App.Item/1').length,
      ).toBeGreaterThan(reloads),
    );
  });
});
