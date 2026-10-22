import { fireEvent, render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { NativeLayout, nativePage, nativeProfile } from './NativeLayout';
import { PageNameContext, PageTitleContext } from './PageTitleContext';
import type { WidgetRuntimeProps } from '../contracts';
import type { ApplicationSchema, WidgetDefinition } from '../../types';

const schema = {
  modules: [],
  languages: { default: 'en_US' },
  navigation: {
    profiles: [
      { name: 'Responsive', kind: 'Responsive', home_page: 'App.Web', items: [] },
      {
        name: 'NativePhone',
        kind: 'Native',
        home_page: 'App.Home',
        bottom_bar: [
          { caption: { en_US: 'Home', nl_NL: 'Thuis' }, page: 'App.Home', icon: 57732 },
          { caption: { en_US: 'Tasks' }, page: 'App.Tasks' },
          { caption: { en_US: 'Nowhere' } },
        ],
      },
    ],
  },
} as unknown as ApplicationSchema;

const layout = (options: Record<string, unknown>): WidgetDefinition => ({
  type: 'native_layout',
  name: 'NativeLayout',
  options,
  regions: {
    content: [{ type: 'text', name: 'Body', options: { caption: 'Body text' } }],
    header: [{ type: 'text', name: 'HeaderAction', options: { caption: 'Edit' } }],
    sidebar: [{ type: 'text', name: 'Menu', options: { caption: 'Side menu' } }],
  },
});

const props = (widget: WidgetDefinition): WidgetRuntimeProps => ({
  widget,
  moduleName: 'App',
  invoke: vi.fn(),
  invokeNanoflow: vi.fn(),
  navigate: vi.fn(),
  context: null,
  pageContext: null,
  revision: 0,
  schema,
  request: vi.fn(),
  saveRecord: vi.fn(),
  onError: vi.fn(),
  onMutation: vi.fn(),
  onSelectRecord: vi.fn(),
});

const renderLayout = (input: WidgetRuntimeProps, page = 'App.Home') =>
  render(
    <PageTitleContext.Provider value="Welcome">
      <PageNameContext.Provider value={page}>
        <NativeLayout {...input} />
      </PageNameContext.Provider>
    </PageTitleContext.Provider>,
  );

describe('native layout in the phone shell', () => {
  it('renders the header with the page title, the content and the bottom bar of the native profile', () => {
    const input = props(layout({ layout_type: 'default', show_bottom_bar: true, sidebar: false }));
    renderLayout(input);
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Welcome');
    expect(screen.getByText('Edit')).toBeInTheDocument();
    expect(screen.getByText('Body text')).toBeInTheDocument();
    expect(screen.queryByText('Side menu')).not.toBeInTheDocument();
    const bar = screen.getByRole('navigation', { name: 'Bottom bar' });
    const home = within(bar).getByRole('button', { name: /Home/ });
    expect(home).toHaveAttribute('aria-current', 'page');
    expect(home).toHaveTextContent(String.fromCodePoint(57732));
    expect(within(bar).getByRole('button', { name: 'Nowhere' })).toBeDisabled();
    fireEvent.click(within(bar).getByRole('button', { name: 'Tasks' }));
    expect(input.navigate).toHaveBeenCalledWith('App.Tasks');
  });

  it('hides the bottom bar when the layout does not show it and renders the sidebar when it has one', () => {
    const input = props(layout({ layout_type: 'popup', show_bottom_bar: false, sidebar: true }));
    renderLayout(input, 'App.Tasks');
    expect(screen.queryByRole('navigation')).not.toBeInTheDocument();
    expect(screen.getByText('Side menu')).toBeInTheDocument();
    expect(document.querySelector('[data-layout-type="popup"]')).toHaveClass(
      'mxrb-native-layout--popup',
    );
  });

  it('finds the native profile and the pages that render inside a native layout', () => {
    expect(nativeProfile(schema)?.name).toBe('NativePhone');
    expect(nativeProfile({ modules: [] } as unknown as ApplicationSchema)).toBeUndefined();
    expect(nativePage([{ type: 'container', name: 'c', children: [layout({})] }])).toBe(true);
    expect(nativePage([{ type: 'layout', name: 'l', regions: { Main: [layout({})] } }])).toBe(true);
    expect(nativePage([{ type: 'text', name: 't' }])).toBe(false);
    expect(nativePage(undefined)).toBe(false);
  });
});
