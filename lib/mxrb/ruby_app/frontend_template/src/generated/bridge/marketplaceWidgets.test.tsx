import { render } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, recognizedMarketplaceWidget } from './marketplace';
import marketplaceWidgets from './marketplaceWidgets.json';
import type { ApplicationSchema } from '../types';

const renderWidget = (widgetId: string) =>
  render(
    <MarketplaceWidget
      widget={{
        type: 'pluggable_widget',
        name: 'Probe',
        options: { widget_id: widgetId, properties: {} },
      }}
      context={{ id: '1', type: 'App.Item', attributes: {} }}
      schema={{ modules: [] } as unknown as ApplicationSchema}
      request={vi.fn().mockResolvedValue({ languages: [] }) as never}
      onChange={vi.fn()}
    />,
  );

describe('pluggable widget families shared with the portability report', () => {
  it.each(marketplaceWidgets.widgets.flatMap((entry) => entry.examples))(
    'renders %s',
    (widgetId) => {
      expect(recognizedMarketplaceWidget(widgetId)).toBeDefined();
      const { container } = renderWidget(widgetId);
      expect(container.querySelector('[data-mxrb-unsupported]')).toBeNull();
    },
  );

  it('renders any other widget as a visible unsupported placeholder', () => {
    expect(recognizedMarketplaceWidget('com.example.Unknown')).toBeUndefined();
    const { container, getByRole } = renderWidget('com.example.Unknown');
    expect(getByRole('alert')).toHaveTextContent('Unsupported widget com.example.Unknown');
    expect(container.querySelector('[data-mxrb-unsupported="com.example.Unknown"]')).not.toBeNull();
  });
});
