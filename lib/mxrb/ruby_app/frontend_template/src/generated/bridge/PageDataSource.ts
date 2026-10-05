import { createContext } from 'react';
import type { PageDefinition, WidgetDefinition } from '../types';

// A promoted page source has already run before its root data view mounts.
// Identify that view by object identity so nested sources keep their own lifecycle.
export const PageDataSource = createContext<WidgetDefinition | null>(null);

export function pageSourceWidget(page: PageDefinition): WidgetDefinition | null {
  if (!page.data_source?.name) return null;
  const find = (value: unknown): WidgetDefinition | null => {
    if (!value || typeof value !== 'object') return null;
    const widget = value as WidgetDefinition;
    if (widget.type === 'data_view') {
      const source = widget.options?.source;
      return source?.kind === page.data_source?.kind && source?.name === page.data_source?.name
        ? widget
        : null;
    }
    for (const child of Object.values(value)) {
      const match = find(child);
      if (match) return match;
    }
    return null;
  };
  return find(page.widgets);
}
