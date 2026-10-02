import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApplicationRuntime } from './ApplicationRuntime';
import { api } from './api';
import { hasPageEdits, PageEdits } from './PageEdits';
import type { ApplicationSchema, EntityRecord, PageDefinition, WidgetDefinition } from '../types';

vi.mock('./api', () => ({ api: vi.fn(), setCsrfToken: vi.fn() }));
vi.mock('../nanoflows', () => ({ default: {} }));

const button = (handler: string, close_page = false): WidgetDefinition => ({
  name: handler,
  type: 'button',
  options: { caption: handler },
  events: [{ event: 'on_click', kind: 'action', handler, close_page }],
});
const original: EntityRecord = { type: 'App.Item', id: '1', attributes: { Name: 'Original' } };
const home: PageDefinition = {
  name: 'App.Home',
  title: 'Home',
  data_source: { kind: 'microflow', name: 'App.Load' },
  widgets: [
    { name: 'Name', type: 'text_box', options: { caption: 'Name', attribute: 'App.Item.Name' } },
    button('save_changes'),
    button('cancel_changes'),
    button('delete'),
    button('close_page'),
    {
      name: 'Open',
      type: 'button',
      options: { caption: 'Open' },
      events: [{ event: 'on_click', kind: 'page', handler: 'App.Detail' }],
    },
  ],
};
const detail: PageDefinition = {
  name: 'App.Detail',
  title: 'Detail',
  widgets: [
    button('close_page'),
    {
      name: 'Exit',
      type: 'button',
      options: { caption: 'Exit flow' },
      events: [{ event: 'on_click', kind: 'microflow', handler: 'App.Exit' }],
    },
  ],
};
function HistoryControls() {
  const navigate = useNavigate();
  return (
    <>
      <button onClick={() => navigate(-1)}>Browser back</button>
      <button onClick={() => navigate(1)}>Browser forward</button>
    </>
  );
}
function mount() {
  render(
    <MemoryRouter initialEntries={['/pages/App.Home']}>
      <HistoryControls />
      <Routes>
        <Route path="/pages/:pageName" element={<ApplicationRuntime />} />
      </Routes>
    </MemoryRouter>,
  );
  return userEvent.setup();
}
let persisted: EntityRecord;
let failCommit: boolean;
let commits: number;
let reads: number;
beforeEach(() => {
  persisted = structuredClone(original);
  failCommit = false;
  commits = 0;
  reads = 0;
  vi.mocked(api).mockReset();
  vi.mocked(api).mockImplementation(async (path, options) => {
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema')
      return {
        project: { name: 'App' },
        modules: [{ name: 'App', pages: [home, detail] }],
      } as never;
    if (path === '/api/pages/App.Home') return home as never;
    if (path === '/api/pages/App.Detail') return detail as never;
    if (path === '/api/microflows/App.Load') {
      reads += 1;
      return { result: persisted } as never;
    }
    if (path === '/api/microflows/App.Exit')
      return { effects: [{ type: 'close_page', count: 1 }] } as never;
    if (path === '/api/records/commit') {
      commits += 1;
      if (failCommit) throw new Error('Commit denied');
      const [change] = JSON.parse(String(options?.body)).records;
      persisted = { ...persisted, attributes: { ...persisted.attributes, ...change.attributes } };
      return { records: [persisted] } as never;
    }
    if (path === '/api/entities/App.Item/1')
      return (options?.method === 'DELETE' ? { ok: true } : persisted) as never;
    throw new Error(`Unexpected request ${path}`);
  });
});

describe('native client actions', () => {
  it('discards blurred and focused edits without writing, then commits once and cancels to the new baseline', async () => {
    const user = mount();
    const field = await screen.findByRole('textbox', { name: 'Name' });
    await user.clear(field);
    await user.type(field, 'Discarded');
    await user.tab();
    expect(persisted.attributes.Name).toBe('Original');
    await user.click(screen.getByRole('button', { name: 'cancel_changes' }));
    expect(field).toHaveValue('Original');
    await user.clear(field);
    await user.type(field, 'Saved');
    // Programmatic activation also flushes an input which has not lost focus.
    fireEvent.click(screen.getByRole('button', { name: 'save_changes' }));
    await waitFor(() => expect(persisted.attributes.Name).toBe('Saved'));
    expect(commits).toBe(1);
    await user.clear(field);
    await user.type(field, 'Not saved');
    fireEvent.click(screen.getByRole('button', { name: 'cancel_changes' }));
    await waitFor(() => expect(field).toHaveValue('Saved'));
    expect(commits).toBe(1);
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('retains drafts on failed commit for retry and deletes the current record through the entity API', async () => {
    const user = mount();
    const field = await screen.findByRole('textbox', { name: 'Name' });
    await user.clear(field);
    await user.type(field, 'Retry me');
    failCommit = true;
    await user.click(screen.getByRole('button', { name: 'save_changes' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Commit denied');
    expect(field).toHaveValue('Retry me');
    expect(persisted.attributes.Name).toBe('Original');
    failCommit = false;
    await user.click(screen.getByRole('button', { name: 'save_changes' }));
    await waitFor(() => expect(persisted.attributes.Name).toBe('Retry me'));
    await user.click(screen.getByRole('button', { name: 'delete' }));
    await waitFor(() => expect(field).toBeDisabled());
    expect(api).toHaveBeenCalledWith('/api/entities/App.Item/1', { method: 'DELETE' });
  });

  it('restores page context on native close, browser back/forward and microflow close effects', async () => {
    const user = mount();
    const field = await screen.findByRole('textbox', { name: 'Name' });
    await user.clear(field);
    await user.type(field, 'Saved before navigation');
    await user.click(screen.getByRole('button', { name: 'save_changes' }));
    await user.click(screen.getByRole('button', { name: 'close_page' }));
    expect(screen.getByRole('textbox', { name: 'Name' })).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Open' }));
    await screen.findByRole('button', { name: 'Exit flow' });
    await user.click(screen.getByRole('button', { name: 'close_page' }));
    expect(await screen.findByRole('textbox', { name: 'Name' })).toHaveValue(
      'Saved before navigation',
    );
    await user.click(screen.getByRole('button', { name: 'Browser forward' }));
    await screen.findByRole('button', { name: 'Exit flow' });
    await user.click(screen.getByRole('button', { name: 'Browser back' }));
    await screen.findByRole('textbox', { name: 'Name' });
    await user.click(screen.getByRole('button', { name: 'Open' }));
    await user.click(await screen.findByRole('button', { name: 'Exit flow' }));
    expect(await screen.findByRole('textbox', { name: 'Name' })).toHaveValue(
      'Saved before navigation',
    );
    expect(reads).toBe(1);
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('preserves edits made while a commit is in flight and cancels to the committed baseline', () => {
    const edits = new PageEdits(true);
    edits.stage(original, { Name: 'Submitted' });
    const submitted = new Map(edits.changes);
    edits.stage(original, { Name: 'Typed during save' });
    edits.accept([{ ...original, attributes: { Name: 'Submitted' } }], submitted);
    expect(edits.resolve(original)?.attributes.Name).toBe('Typed during save');
    expect(edits.pending()[0].attributes.Name).toBe('Typed during save');
    edits.cancel();
    expect(edits.resolve(original)?.attributes.Name).toBe('Submitted');
    edits.stage(original, { Name: 'Deleted draft' });
    edits.forget(original);
    expect(edits.pending()).toEqual([]);
  });

  it('finds actions in referenced resources and keeps multiple object drafts and transients separate', async () => {
    const schema = {
      presentation: { 'App.Form': { kind: 'snippet', widgets: [button('save_changes')] } },
    } as unknown as ApplicationSchema;
    expect(hasPageEdits({ options: { snippet: 'App.Form' } }, schema)).toBe(true);
    expect(hasPageEdits({ options: { snippet: 'Missing' } }, schema)).toBe(false);
    const edits = new PageEdits(true);
    const other = { ...original, type: 'App.Other' };
    const transient = { ...original, id: 'transient', transient: true };
    edits.stage(original, { Name: 'A' });
    edits.stage(other, { Name: 'B' });
    edits.stage(transient, { Name: 'C' });
    expect(edits.pending()).toHaveLength(2);
    edits.accept([]);
    edits.stage(original, { Name: 'D' });
    edits.cancel();
    expect(edits.resolve(original)?.attributes.Name).toBe('A');
    expect(edits.resolve(other)?.attributes.Name).toBe('B');
    expect(edits.resolve(transient)?.attributes.Name).toBe('C');
  });
});
