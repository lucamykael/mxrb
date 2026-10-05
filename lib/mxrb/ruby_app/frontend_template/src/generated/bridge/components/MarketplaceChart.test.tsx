import { act, render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, type MarketplaceWidgetProps } from '../marketplace';
import type { EntityCollectionResponse, EntityRecord } from '../../types';

const record = (name: string, value: number | null): EntityRecord => ({
  id: name,
  type: 'App.Point',
  attributes: { Name: name, Value: value },
});
const source = {
  data_source: 'App.Point',
  xpath: '[Value > 0]',
  sort: [{ attribute: 'App.Point.Value', direction: 'Ascending' }],
};
const series = {
  staticDataSource: source,
  staticName: 'Values',
  staticXAttribute: 'App.Point.Name',
  staticYAttribute: 'App.Point.Value',
};
const props = (
  kind: string,
  properties: Record<string, unknown> = { series: { objects: [series] } },
): MarketplaceWidgetProps => ({
  widget: {
    type: 'pluggable_widget',
    name: 'Live chart',
    options: {
      widget_id: `com.mendix.widget.web.${kind.toLowerCase()}.${kind}`,
      properties,
    },
  },
  context: { id: 'owner', type: 'App.Owner', attributes: {} },
  onChange: vi.fn(),
});

describe('Marketplace charts read actual application values', () => {
  it('aligns equal categories across series with different data points', async () => {
    const request = vi
      .fn()
      .mockResolvedValueOnce({ records: [record('A', 10), record('B', 20)] })
      .mockResolvedValueOnce({ records: [record('B', 15), record('C', 25)] });
    render(
      <MarketplaceWidget
        {...props('LineChart', { lines: { objects: [series, series] } })}
        request={request}
      />,
    );
    const svg = await screen.findByRole('img');
    const points = [...svg.querySelectorAll('circle')];
    expect(points[1].getAttribute('cx')).toBe(points[2].getAttribute('cx'));
    expect(points[0].getAttribute('cx')).not.toBe(points[2].getAttribute('cx'));
    expect([...svg.querySelectorAll('text')].map((node) => node.textContent)).toEqual(
      expect.arrayContaining(['A', 'B', 'C']),
    );
  });

  it('reads data sources emitted by the typed Ruby property DSL', async () => {
    const request = vi.fn().mockResolvedValue({ records: [record('Typed source', 12)] });
    const input = props('LineChart', {
      lines: {
        objects: [
          {
            ...series,
            staticDataSource: {
              data_source: { entity: 'App.Point', xpath: '[Value > 10]', sort: [] },
            },
          },
        ],
      },
    });
    render(<MarketplaceWidget {...input} request={request} />);
    expect(await screen.findByRole('img')).toHaveTextContent('Typed source: 12');
    const url = new URL(request.mock.calls[0][0], 'http://localhost');
    expect(url.pathname).toBe('/api/entities/App.Point');
    expect(url.searchParams.get('xpath')).toBe('[Value > 10]');
  });

  it('queries the declared source and XPath context, sorts records and redraws after mutation', async () => {
    const request = vi
      .fn()
      .mockResolvedValue({ records: [record('Beta', 20), record('Alpha', 10)] });
    const input = { ...props('ColumnChart'), request };
    const { rerender } = render(<MarketplaceWidget {...input} />);
    const svg = await screen.findByRole('img', { name: 'Live chart' });
    const url = new URL(request.mock.calls[0][0], 'http://localhost');
    expect(url.pathname).toBe('/api/entities/App.Point');
    expect(url.searchParams.get('xpath')).toBe('[Value > 0]');
    expect(url.searchParams.get('xpath_context_id')).toBe('owner');
    expect(
      within(screen.getByRole('table', { hidden: true })).getAllByRole('row', { hidden: true })[1],
    ).toHaveTextContent('Alpha10');
    const heights = () =>
      [...svg.querySelectorAll('rect')].map((node) => Number(node.getAttribute('height')));
    expect(heights()[1] / heights()[0]).toBeCloseTo(2);
    request.mockResolvedValue({ records: [record('Alpha', 10), record('Beta', 40)] });
    rerender(<MarketplaceWidget {...input} revision={1} />);
    await screen.findByRole('img');
    expect(request).toHaveBeenCalledTimes(2);
    const changed = [...screen.getByRole('img').querySelectorAll('rect')].map((node) =>
      Number(node.getAttribute('height')),
    );
    expect(changed[1] / changed[0]).toBeCloseTo(4);
  });

  it('draws horizontal bars and preserves negative values', async () => {
    render(
      <MarketplaceWidget
        {...props('BarChart', {
          series: {
            objects: [
              {
                ...series,
                staticXAttribute: 'App.Point.Value',
                staticYAttribute: 'App.Point.Name',
              },
            ],
          },
        })}
        request={vi
          .fn()
          .mockResolvedValue({ records: [record('Debit', -5), record('Credit', 10)] })}
      />,
    );
    const svg = await screen.findByRole('img');
    const bars = [...svg.querySelectorAll('rect')];
    expect(
      Number(bars[1].getAttribute('width')) / Number(bars[0].getAttribute('width')),
    ).toBeCloseTo(2);
    expect(Number(bars[0].getAttribute('x'))).toBeLessThan(Number(bars[1].getAttribute('x')));
    expect(svg).toHaveTextContent('Debit: -5');
  });

  it('ignores a stale response when the source changes', async () => {
    let complete!: (value: EntityCollectionResponse) => void;
    const pending = new Promise<EntityCollectionResponse>((resolve) => {
      complete = resolve;
    });
    const request = vi
      .fn()
      .mockReturnValueOnce(pending)
      .mockResolvedValue({ records: [record('New data', 8)] });
    const { rerender } = render(<MarketplaceWidget {...props('LineChart')} request={request} />);
    rerender(
      <MarketplaceWidget
        {...props('LineChart', {
          lines: { objects: [{ ...series, staticDataSource: { data_source: 'App.Other' } }] },
        })}
        request={request}
      />,
    );
    expect(await screen.findByRole('img')).toHaveTextContent('New data: 8');
    await act(async () => {
      complete({ records: [record('Stale data', 99)] });
      await pending;
    });
    expect(screen.getByRole('img')).not.toHaveTextContent('Stale data');
  });

  it('spaces time-series points by their timestamps', async () => {
    const request = vi.fn().mockResolvedValue({
      records: [record('2026-01-01', 1), record('2026-01-02', 2), record('2026-01-11', 3)],
    });
    render(
      <MarketplaceWidget
        {...props('TimeSeries', { lines: { objects: [series] } })}
        request={request}
      />,
    );
    const svg = await screen.findByRole('img');
    const coordinates = [...svg.querySelectorAll('circle')].map((node) =>
      Number(node.getAttribute('cx')),
    );
    expect((coordinates[2] - coordinates[1]) / (coordinates[1] - coordinates[0])).toBeCloseTo(9);
  });

  it('reads explicit custom-chart JSON without executing code or inventing series', async () => {
    const input = props('CustomChart', {
      dataStatic: JSON.stringify([
        { name: 'Budget', type: 'bar', x: ['A', 'B', 'Empty'], y: [7, 21, null] },
      ]),
    });
    const { rerender } = render(<MarketplaceWidget {...input} />);
    const svg = await screen.findByRole('img');
    expect(svg.querySelectorAll('rect')).toHaveLength(2);
    expect(svg).toHaveTextContent('Budget B: 21');
    rerender(<MarketplaceWidget {...props('CustomChart', { dataStatic: '[]' })} />);
    expect(await screen.findByText('No chart data')).toBeInTheDocument();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  it('reports source and data failures instead of showing the previous decorative graph', async () => {
    const { rerender } = render(
      <MarketplaceWidget
        {...props('LineChart')}
        request={vi.fn().mockRejectedValue(new Error('Data access denied'))}
      />,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent('Data access denied');
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
    rerender(<MarketplaceWidget {...props('CustomChart', { dataStatic: '{broken}' })} />);
    expect(await screen.findByRole('alert')).toHaveTextContent('SyntaxError');
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  it('rejects unsupported aggregation rather than silently plotting unaggregated values', async () => {
    const request = vi.fn().mockResolvedValue({ records: [record('A', 10)] });
    render(
      <MarketplaceWidget
        {...props('LineChart', {
          lines: { objects: [{ ...series, aggregationType: 'sum' }] },
        })}
        request={request}
      />,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Chart aggregation is not supported: sum',
    );
    expect(request).not.toHaveBeenCalled();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  it('uses declared pie and heatmap bindings and leaves null values out of the plot', async () => {
    const input = props('PieChart', {
      seriesDataSource: source,
      seriesName: 'Shares',
      seriesValueAttribute: 'App.Point.Value',
    });
    const request = vi
      .fn()
      .mockResolvedValue({ records: [record('A', 10), record('B', 30), record('Empty', null)] });
    const { rerender } = render(<MarketplaceWidget {...input} request={request} />);
    expect((await screen.findByRole('img')).querySelectorAll('path')).toHaveLength(2);
    rerender(
      <MarketplaceWidget
        {...props('HeatMap', {
          seriesDataSource: source,
          seriesValueAttribute: 'App.Point.Value',
          horizontalAxisAttribute: 'App.Point.Name',
          verticalAxisAttribute: 'App.Point.Name',
        })}
        request={request}
      />,
    );
    const svg = await screen.findByRole('img');
    const cells = [...svg.querySelectorAll('rect')];
    expect(cells).toHaveLength(2);
    expect(Number(cells[1].getAttribute('opacity'))).toBeGreaterThan(
      Number(cells[0].getAttribute('opacity')),
    );
  });
});
