import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ApplicationRuntime } from './ApplicationRuntime';
import { api } from './api';
import { MemoryOfflineBackend, OfflineStore, useOfflineStore } from './offlineStore';
import { forgetRequestedProfile } from './synchronize';

vi.mock('./api', () => ({ api: vi.fn(), setCsrfToken: vi.fn() }));
vi.mock('../nanoflows', () => ({ default: {} }));

const page = {
  name: 'App.Home',
  title: 'Home',
  widgets: [{ name: 'Name', type: 'text_box', options: { caption: 'Name' } }],
};
const schema = {
  project: { name: 'App' },
  modules: [{ name: 'App', pages: [page] }],
  navigation: {
    profiles: [
      { name: 'Responsive', kind: 'Responsive', home_page: 'App.Home' },
      {
        name: 'NativePhone',
        kind: 'Native',
        home_page: 'App.Home',
        offline_entities: [{ entity: 'App.Task', sync_mode: 'All', constraint: '' }],
      },
    ],
  },
};
const task = { id: '1', type: 'App.Task', attributes: { Name: 'Call' } };
let store: OfflineStore;

beforeEach(() => {
  vi.mocked(api).mockReset();
  store = new OfflineStore(new MemoryOfflineBackend());
  useOfflineStore(store);
});
afterEach(() => {
  useOfflineStore(null);
  forgetRequestedProfile();
  window.history.replaceState({}, '', '/');
});

const mount = () =>
  render(
    <MemoryRouter>
      <ApplicationRuntime />
    </MemoryRouter>,
  );

it('synchronizes the device copy before opening the home page of an offline profile', async () => {
  window.history.replaceState({}, '', '/?profile=NativePhone');
  await store.save({ ...task, id: 'tmp', transient: true });
  const calls: string[] = [];
  vi.mocked(api).mockImplementation(async (path, options) => {
    calls.push(path);
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema') return schema as never;
    if (path === '/api/sync') {
      expect(JSON.parse(String(options?.body))).toEqual({
        profile: 'NativePhone',
        changes: [{ type: 'App.Task', id: 'tmp', attributes: { Name: 'Call' }, new_record: true }],
      });
      return {
        ok: true,
        profile: 'NativePhone',
        synchronized_at: 'T1',
        guid_map: { tmp: '2' },
        conflicts: [],
        uploaded: [{ ...task, id: '2' }],
        entities: [
          {
            entity: 'App.Task',
            sync_mode: 'All',
            constraint: '',
            records: [task, { ...task, id: '2' }],
          },
        ],
      } as never;
    }
    if (path === '/api/pages/App.Home') return page as never;
    throw new Error(`Unexpected request ${path}`);
  });
  mount();
  expect(await screen.findByRole('textbox', { name: 'Name' })).toBeInTheDocument();
  expect(calls.indexOf('/api/sync')).toBeLessThan(calls.indexOf('/api/pages/App.Home'));
  expect((await store.records('App.Task')).map((record) => record.id).sort()).toEqual(['1', '2']);
  expect(await store.pendingChanges()).toEqual([]);
  expect((await store.meta()).profile).toBe('NativePhone');
});

it('keeps the device data and reports a synchronization the server refused', async () => {
  window.history.replaceState({}, '', '/?profile=NativePhone');
  await store.replaceEntity('App.Task', [task]);
  vi.mocked(api).mockImplementation(async (path) => {
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema') return schema as never;
    if (path === '/api/sync') throw Object.assign(new Error('Server unavailable'), { status: 503 });
    if (path === '/api/pages/App.Home') return page as never;
    throw new Error(`Unexpected request ${path}`);
  });
  const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
  mount();
  expect(await screen.findByRole('textbox', { name: 'Name' })).toBeInTheDocument();
  expect(await screen.findByText(/Synchronization failed: Server unavailable/)).toBeInTheDocument();
  expect(await store.records('App.Task')).toEqual([task]);
  expect(warn).toHaveBeenCalled();
  warn.mockRestore();
});

it('leaves web profiles alone', async () => {
  vi.mocked(api).mockImplementation(async (path) => {
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema') return schema as never;
    if (path === '/api/pages/App.Home') return page as never;
    throw new Error(`Unexpected request ${path}`);
  });
  mount();
  expect(await screen.findByRole('textbox', { name: 'Name' })).toBeInTheDocument();
  await waitFor(() =>
    expect(vi.mocked(api).mock.calls.some(([path]) => path === '/api/sync')).toBe(false),
  );
});

it('clears the device copy when the user of an offline profile signs out', async () => {
  window.history.replaceState({}, '', '/?profile=NativePhone');
  vi.mocked(api).mockImplementation(async (path) => {
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema') return schema as never;
    if (path === '/api/sync')
      return {
        ok: true,
        profile: 'NativePhone',
        synchronized_at: 'T1',
        guid_map: {},
        conflicts: [],
        uploaded: [],
        entities: [{ entity: 'App.Task', sync_mode: 'All', constraint: '', records: [task] }],
      } as never;
    if (path === '/api/pages/App.Home') return page as never;
    if (path === '/api/logout') return {} as never;
    throw new Error(`Unexpected request ${path}`);
  });
  mount();
  expect(await screen.findByRole('textbox', { name: 'Name' })).toBeInTheDocument();
  expect(await store.records('App.Task')).toEqual([task]);
  await userEvent.click(screen.getByRole('button', { name: 'Sign out' }));
  await waitFor(async () => expect(await store.records('App.Task')).toEqual([]));
  expect(await store.meta()).toEqual({});
  expect(window.sessionStorage.getItem('mxrb.profile')).toBeNull();
});
