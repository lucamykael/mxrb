import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, expect, it, vi } from 'vitest';
import { ApplicationRuntime } from './ApplicationRuntime';
import { api } from './api';

vi.mock('./api', () => ({ api: vi.fn(), setCsrfToken: vi.fn() }));
vi.mock('../nanoflows', () => ({ default: {} }));

const page = {
  name: 'App.Private',
  title: 'Private page',
  widgets: [{ name: 'Name', type: 'text_box', options: { caption: 'Name' } }],
};
const schema = { project: { name: 'App' }, modules: [{ name: 'App', pages: [page] }] };
const mount = () =>
  render(
    <MemoryRouter initialEntries={['/pages/App.Private']}>
      <Routes>
        <Route path="/pages/:pageName" element={<ApplicationRuntime />} />
      </Routes>
    </MemoryRouter>,
  );
beforeEach(() => {
  vi.mocked(api).mockReset();
});

it('logs in from a protected deep link and loads that page without a second navigation', async () => {
  let authenticated = false;
  vi.mocked(api).mockImplementation(async (path) => {
    if (path === '/api/session') return { user: authenticated ? 'tester' : null } as never;
    if (path === '/api/schema')
      return (authenticated ? schema : { ...schema, modules: [] }) as never;
    if (path === '/api/login') {
      authenticated = true;
      return { csrf: 'test' } as never;
    }
    if (path === '/api/pages/App.Private' && authenticated) return page as never;
    throw new Error(`Unexpected request ${path}`);
  });
  mount();
  const user = userEvent.setup();
  await user.type(await screen.findByLabelText('Username'), 'tester');
  await user.type(screen.getByLabelText('Password'), 'local-password');
  await user.click(screen.getByRole('button', { name: 'Sign in' }));
  expect(await screen.findByRole('textbox', { name: 'Name' })).toBeInTheDocument();
  expect(screen.queryByText('Loading application…')).not.toBeInTheDocument();
});

it('still opens pages available to anonymous visitors', async () => {
  vi.mocked(api).mockImplementation(async (path) => {
    if (path === '/api/session') return { user: null } as never;
    if (path === '/api/schema') return schema as never;
    if (path === '/api/pages/App.Private') return page as never;
    throw new Error(`Unexpected request ${path}`);
  });
  mount();
  expect(await screen.findByRole('textbox', { name: 'Name' })).toBeInTheDocument();
  expect(screen.queryByLabelText('Username')).not.toBeInTheDocument();
});

it.each([403, 404, 500])('shows initial page failures (%s) and supports retry', async (status) => {
  let failed = true;
  vi.mocked(api).mockImplementation(async (path) => {
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema') return schema as never;
    if (path === '/api/pages/App.Private') {
      if (failed) throw Object.assign(new Error('Page could not be loaded'), { status });
      return page as never;
    }
    throw new Error(`Unexpected request ${path}`);
  });
  mount();
  expect(await screen.findByRole('alert')).toHaveTextContent('Page could not be loaded');
  expect(screen.queryByText('Loading application…')).not.toBeInTheDocument();
  failed = false;
  await userEvent.click(screen.getByRole('button', { name: 'Try again' }));
  expect(await screen.findByRole('textbox', { name: 'Name' })).toBeInTheDocument();
});

it('falls back to an overview instead of an editor that needs an object', async () => {
  const editor = { ...page, name: 'App.Edit', parameters: [{ name: 'Item', required: true }] };
  vi.mocked(api).mockImplementation(async (path) => {
    if (path === '/api/session') return { user: 'tester' } as never;
    if (path === '/api/schema')
      return {
        ...schema,
        modules: [{ name: 'App', pages: [editor, page] }],
      } as never;
    if (path === '/api/pages/App.Private') return page as never;
    throw new Error(`Unexpected request ${path}`);
  });
  render(
    <MemoryRouter>
      <ApplicationRuntime />
    </MemoryRouter>,
  );
  expect(await screen.findByRole('textbox', { name: 'Name' })).toBeInTheDocument();
  expect(vi.mocked(api).mock.calls.some(([path]) => path === '/api/pages/App.Edit')).toBe(false);
});
