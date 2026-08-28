import type { ReactNode } from 'react';

export interface NavigationEntry {
  caption?: Record<string, string>;
  page?: string;
  items?: NavigationEntry[];
}

interface AppNavigationProps {
  items: NavigationEntry[];
  authenticated: boolean;
  onOpenPage: (name: string) => unknown;
  onLogout: () => unknown;
}

function navigationItems(items: NavigationEntry[], openPage: (name: string) => unknown): ReactNode {
  return (items || []).map((item, index) => (
    <li key={`${item.page || item.caption?.en_US}-${index}`}>
      {item.page ? (
        <button type="button" onClick={() => openPage(item.page!)}>
          {item.caption?.en_US || item.page}
        </button>
      ) : (
        <span>{item.caption?.en_US || ''}</span>
      )}
      {item.items?.length ? <ul>{navigationItems(item.items, openPage)}</ul> : null}
    </li>
  ));
}

export function AppNavigation({ items, authenticated, onOpenPage, onLogout }: AppNavigationProps) {
  if (!items.length && !authenticated) return null;
  return (
    <nav className="app-navigation mxrb-navigation region-sidebar" aria-label="Main navigation">
      {items.length ? <ul>{navigationItems(items, onOpenPage)}</ul> : null}
      {authenticated ? (
        <button type="button" onClick={onLogout}>
          Sign out
        </button>
      ) : null}
    </nav>
  );
}
