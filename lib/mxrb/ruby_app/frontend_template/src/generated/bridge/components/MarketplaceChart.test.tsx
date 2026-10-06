import { act, fireEvent, render, screen, within } from '@testing-library/react';
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
  it.each(['ColumnChart', 'BarChart'])(
    'stacks %s in source order, including negative and zero values',
    async (kind) => {
      const definitions = [10, -4, 0, 8].map((value, index) => ({
        ...series,
        staticName: String(index),
        staticDataSource: { data_source: `App.Point${value}` },
        ...(kind === 'BarChart' ? { staticXAttribute: 'Value', staticYAttribute: 'Name' } : {}),
      }));
      const request = vi
        .fn()
        .mockImplementation((url: string) =>
          Promise.resolve({ records: [record('A', Number(url.split('Point')[1]))] }),
        );
      render(
        <MarketplaceWidget
          {...props(kind, { barmode: 'stack', series: { objects: definitions } })}
          request={request}
        />,
      );
      const svg = await screen.findByRole('img');
      const bars = [...svg.querySelectorAll('rect')];
      expect(bars).toHaveLength(4);
      const position = kind === 'BarChart' ? 'y' : 'x';
      const thickness = kind === 'BarChart' ? 'height' : 'width';
      expect(new Set(bars.map((bar) => bar.getAttribute(position))).size).toBe(1);
      expect(new Set(bars.map((bar) => bar.getAttribute(thickness))).size).toBe(1);
      const length = kind === 'BarChart' ? 'width' : 'height';
      expect(Number(bars[2].getAttribute(length))).toBe(0);
      const scale = Number(bars[0].getAttribute(length)) / 10;
      expect(Number(bars[1].getAttribute(length))).toBeCloseTo(scale * 4);
      expect(Number(bars[3].getAttribute(length))).toBeCloseTo(scale * 8);
      expect(svg).toHaveTextContent('14');
    },
  );

  it('executes point actions with the ordered source record, locks pending actions and supports keyboard activation', async () => {
    const first = record('A', 10);
    const second = { ...record('A', 20), id: 'second' };
    const last = record('B', 7);
    let finish: (value?: unknown) => void = () => {};
    const onAction = vi.fn().mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    render(
      <MarketplaceWidget
        {...props('ColumnChart', {
          series: {
            objects: [
              {
                ...series,
                staticDataSource: { data_source: 'App.Point' },
                aggregationType: 'sum',
                staticOnClickAction: {
                  action: {
                    kind: 'microflow',
                    handler: 'App.Select',
                    arguments: { Point: '$currentObject' },
                  },
                },
              },
            ],
          },
        })}
        request={vi.fn().mockResolvedValue({ records: [first, second, last] })}
        onAction={onAction}
      />,
    );
    const svg = await screen.findByRole('img');
    const point = within(svg).getByRole('button', { name: 'Values B: 7' });
    fireEvent.keyDown(point, { key: 'Enter' });
    fireEvent.click(point);
    await act(async () => {});
    expect(onAction).toHaveBeenCalledTimes(1);
    expect(onAction).toHaveBeenCalledWith(
      expect.objectContaining({ kind: 'microflow', handler: 'App.Select' }),
      second,
    );
    expect(point).toHaveAttribute('aria-disabled', 'true');
    await act(async () => finish());
    fireEvent.keyDown(point, { key: ' ' });
    await act(async () => {});
    expect(onAction).toHaveBeenCalledTimes(2);
    await act(async () => finish());
  });

  it('dispatches dynamic actions and reports failures without leaving the chart locked', async () => {
    const point = record('A', 12);
    const onAction = vi.fn().mockRejectedValue(new Error('Action denied'));
    render(
      <MarketplaceWidget
        {...props('LineChart', {
          lines: {
            objects: [
              {
                dataSet: 'dynamic',
                dynamicDataSource: { data_source: 'App.Point' },
                groupByAttribute: 'Name',
                dynamicXAttribute: 'Name',
                dynamicYAttribute: 'Value',
                dynamicOnClickAction: { kind: 'nanoflow', handler: 'App.Select' },
              },
            ],
          },
        })}
        request={vi.fn().mockResolvedValue({ records: [point] })}
        onAction={onAction}
      />,
    );
    const svg = await screen.findByRole('img');
    fireEvent.click(within(svg).getByRole('button'));
    expect(await screen.findByRole('alert')).toHaveTextContent('Action denied');
    expect(onAction).toHaveBeenCalledWith(expect.objectContaining({ kind: 'nanoflow' }), point);
    expect(within(svg).getByRole('button')).toHaveAttribute('aria-disabled', 'false');
  });

  it('groups dynamic series by typed values and aggregates independently after sorting', async () => {
    const point = (
      id: string,
      group: string | number | null,
      label: string,
      value: number | null,
      name: string,
      position: number,
    ): EntityRecord => ({
      id,
      type: 'App.Point',
      attributes: { Group: group, Name: label, Value: value, Caption: name, Position: position },
    });
    const request = vi.fn().mockResolvedValue({
      records: [
        point('3', 1, 'A', 20, 'Later', 3),
        point('1', 1, 'A', 10, '', 1),
        point('2', 1, 'A', null, 'Numeric', 2),
        point('4', '1', 'A', 4, 'String', 4),
        point('5', null, 'B', 5, 'Empty', 5),
        point('6', '', 'B', 6, 'Other', 6),
      ],
    });
    render(
      <MarketplaceWidget
        {...props('LineChart', {
          lines: {
            objects: [
              {
                dataSet: 'dynamic',
                dynamicDataSource: {
                  data_source: 'App.Point',
                  sort: [{ attribute: 'App.Point.Position', direction: 'Ascending' }],
                },
                groupByAttribute: 'App.Point.Group',
                dynamicXAttribute: 'App.Point.Name',
                dynamicYAttribute: 'App.Point.Value',
                dynamicName: { text: '{1}', parameters: ['$currentObject/Caption'] },
                aggregationType: 'sum',
              },
            ],
          },
        })}
        request={request}
      />,
    );
    const svg = await screen.findByRole('img');
    expect(svg).toHaveTextContent('Numeric A: 30');
    expect(svg).toHaveTextContent('String A: 4');
    expect(svg).toHaveTextContent('Empty B: 11');
    expect(svg.querySelectorAll('circle')).toHaveLength(3);
    expect(svg).not.toHaveTextContent('Later');
  });

  it('renders parameterized static names using the page context and mixes static and dynamic series', async () => {
    const request = vi.fn().mockResolvedValue({ records: [record('Alpha', 12)] });
    const input = props('BarChart', {
      series: {
        objects: [
          {
            ...series,
            staticName: { text: 'Owner {1}', parameters: ['$currentObject/Name'] },
            staticXAttribute: 'App.Point.Value',
            staticYAttribute: 'App.Point.Name',
          },
          {
            dataSet: 'dynamic',
            dynamicDataSource: { data_source: 'App.Point' },
            groupByAttribute: 'App.Point.Name',
            dynamicXAttribute: 'App.Point.Value',
            dynamicYAttribute: 'App.Point.Name',
            dynamicName: 'Dynamic',
          },
        ],
      },
    });
    render(
      <MarketplaceWidget
        {...input}
        context={{ id: 'owner', type: 'App.Owner', attributes: { Name: 'Context' } }}
        request={request}
      />,
    );
    const svg = await screen.findByRole('img');
    expect(svg).toHaveTextContent('Owner Context Alpha: 12');
    expect(svg).toHaveTextContent('Dynamic Alpha: 12');
    expect(svg.querySelectorAll('rect')).toHaveLength(2);
  });

  it('refreshes dynamic groups after mutations without retaining removed series', async () => {
    const request = vi.fn().mockResolvedValue({ records: [record('First', 1)] });
    const input = props('LineChart', {
      lines: {
        objects: [
          {
            dataSet: 'dynamic',
            dynamicDataSource: { data_source: 'App.Point' },
            groupByAttribute: 'App.Point.Name',
            dynamicXAttribute: 'App.Point.Name',
            dynamicYAttribute: 'App.Point.Value',
          },
        ],
      },
    });
    const { rerender } = render(<MarketplaceWidget {...input} request={request} />);
    expect(await screen.findByRole('img')).toHaveTextContent('First: 1');
    request.mockResolvedValue({ records: [record('Second', 2)] });
    rerender(<MarketplaceWidget {...input} request={request} revision={1} />);
    const svg = await screen.findByRole('img');
    expect(svg).toHaveTextContent('Second: 2');
    expect(svg).not.toHaveTextContent('First');
  });

  it.each([
    [{ dataSet: 'other' }, 'Chart data set is not supported: other'],
    [
      { dataSet: 'dynamic', dynamicDataSource: source },
      'Dynamic chart group attribute is unavailable',
    ],
    [
      { staticName: { text: 'Bad', parameters: [1] } },
      'Chart caption requires text and expression parameters',
    ],
  ])('reports invalid dynamic or caption configuration', async (configuration, message) => {
    render(
      <MarketplaceWidget
        {...props('LineChart', { lines: { objects: [{ ...series, ...configuration }] } })}
        request={vi.fn().mockResolvedValue({ records: [record('A', 1)] })}
      />,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent(message);
  });

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
          lines: { objects: [{ ...series, aggregationType: 'unsupported' }] },
        })}
        request={request}
      />,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Chart aggregation is not supported: unsupported',
    );
    expect(request).not.toHaveBeenCalled();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  it('reports unsupported native horizontal aggregation', async () => {
    const request = vi.fn();
    render(
      <MarketplaceWidget
        {...props('BarChart', {
          series: { objects: [{ ...series, aggregationType: 'sum' }] },
        })}
        request={request}
      />,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Horizontal chart aggregation is not supported',
    );
    expect(request).not.toHaveBeenCalled();
  });

  it.each([
    ['count', 4, 3],
    ['sum', 80, 30],
    ['avg', 20, 10],
    ['min', 10, 5],
    ['max', 40, 20],
    ['median', 15, 5],
    ['mode', 10, 5],
    ['first', 10, 5],
    ['last', 40, 20],
  ])(
    'aggregates %s within each category after sorting and excluding nulls',
    async (aggregation, a, b) => {
      const request = vi.fn().mockResolvedValue({
        records: [
          record('A', 10),
          record('B', 5),
          record('A', 20),
          record('B', 5),
          record('A', 10),
          record('B', 20),
          record('A', 40),
          record('A', null),
        ],
      });
      render(
        <MarketplaceWidget
          {...props('LineChart', {
            lines: {
              objects: [
                {
                  ...series,
                  staticDataSource: { data_source: 'App.Point' },
                  aggregationType: aggregation,
                },
              ],
            },
          })}
          request={request}
        />,
      );
      const table = await screen.findByRole('table', { hidden: true });
      expect([...table.querySelectorAll('tbody tr')].map((row) => row.textContent)).toEqual([
        `ValuesA${a}`,
        `ValuesB${b}`,
      ]);
      expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    },
  );

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
