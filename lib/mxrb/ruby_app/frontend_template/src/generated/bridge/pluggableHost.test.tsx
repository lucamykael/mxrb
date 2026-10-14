import Big from 'big.js';
import { act, render, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, type MarketplaceWidgetProps } from './marketplace';
import { attribute, greaterThan, literal } from './mendixFilters';
import {
  apiValue,
  registerProjectWidget,
  runtimeValue,
  type WidgetPropertyDefinition,
} from './pluggableHost';
import type { ApiRequest, ApplicationSchema, EntityRecord } from '../types';

type Props = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const schema = {
  modules: [
    {
      name: 'App',
      models: [
        {
          name: 'App.Point',
          attributes: [
            { name: 'Value', type: 'Decimal' },
            { name: 'At', type: 'DateTime' },
            { name: 'Label', type: 'String' },
          ],
        },
      ],
    },
  ],
} as unknown as ApplicationSchema;

const point = (id: string, value: string, label: string): EntityRecord => ({
  id,
  type: 'App.Point',
  attributes: { Value: { __mxrb_decimal: value }, Label: label, At: '2026-10-14T10:00:00.000Z' },
});

const definitions: WidgetPropertyDefinition[] = [
  { key: 'points', type: 'DataSource', list: true },
  { key: 'y', type: 'Attribute', data_source: 'points' },
  { key: 'at', type: 'Attribute', data_source: 'points' },
  { key: 'label', type: 'Expression', data_source: 'points' },
  { key: 'tooltip', type: 'TextTemplate', data_source: 'points' },
  { key: 'onPoint', type: 'Action', data_source: 'points' },
  { key: 'cell', type: 'Widgets', data_source: 'points' },
  { key: 'target', type: 'Attribute' },
  { key: 'caption', type: 'TextTemplate' },
  { key: 'mode', type: 'Expression', default: "'date'" },
  { key: 'onClick', type: 'Action' },
  { key: 'header', type: 'Widgets' },
  { key: 'title', type: 'String', default: 'Chart' },
  { key: 'limit', type: 'Decimal' },
  { key: 'icon', type: 'Icon' },
  { key: 'picture', type: 'Image' },
  { key: 'series', type: 'Object', list: true, properties: [{ key: 'name', type: 'String' }] },
  { key: 'single', type: 'Object', properties: [{ key: 'name', type: 'String' }] },
  { key: 'selection', type: 'Selection' },
];

function host(properties: Record<string, unknown>, records: EntityRecord[]) {
  let latest: Props = {};
  const Widget = (props: Props) => {
    latest = props;
    return <span data-testid="widget">{String(props.title)}</span>;
  };
  const unregister = registerProjectWidget(
    'example.chart.Chart',
    { Chart: Widget },
    'Chart',
    definitions,
  );
  const context = point('ctx', '1', 'Context');
  const request = vi.fn().mockResolvedValue({ records });
  const props: MarketplaceWidgetProps = {
    widget: {
      type: 'pluggable_widget',
      name: 'chart1',
      options: { widget_id: 'example.chart.Chart', class: 'chart-panel', properties },
    },
    context,
    schema,
    request: request as unknown as ApiRequest,
    regions: [
      { path: [], role: 'header', content: <b>Header</b> },
      { path: [], role: 'cell', content: null, render: (record) => <i>{record.id}</i> },
    ],
    onChange: vi.fn().mockResolvedValue(undefined),
    onAction: vi.fn().mockResolvedValue(undefined),
  };
  const view = render(<MarketplaceWidget {...props} />);
  return { props, request, view, unregister, current: () => latest };
}

describe('pluggable host', () => {
  it('runs a project widget build with the pluggable widget API over the runtime', async () => {
    const records = [point('1', '3', 'b'), point('2', '1.5', 'a'), point('3', '7', 'c')];
    const action = { action: { kind: 'microflow', handler: 'App.Open', arguments: {} } };
    const { props, request, unregister, current } = host(
      {
        points: {
          data_source: { entity: 'App.Point', sort: [{ attribute: 'Label', direction: 'asc' }] },
        },
        y: 'App.Point.Value',
        at: 'App.Point.At',
        label: '$currentObject/Label',
        tooltip: 'Point',
        onPoint: action,
        target: 'App.Point.Value',
        caption: 'Caption',
        onClick: action,
        limit: '2.5',
        icon: 'glyphicon-star',
        picture: { uri: '/img/a.png' },
        series: { objects: [{ name: 'S1' }, { name: 'S2' }] },
        single: { objects: [{ name: 'Only' }] },
      },
      records,
    );
    expect(current().points.status).toBe('loading');
    await waitFor(() => expect(current().points.status).toBe('available'));
    expect(request).toHaveBeenCalledWith('/api/entities/App.Point');

    const widget = current();
    expect(widget.class).toBe('chart-panel');
    expect(widget.name).toBe('chart1');
    expect(widget.points.items.map((item: { id: string }) => item.id)).toEqual(['2', '1', '3']);
    expect(widget.points.totalCount).toBe(3);
    const [first] = widget.points.items;
    expect(widget.y.get(first).value).toEqual(new Big('1.5'));
    expect(widget.y.get({ id: 'unknown' })).toBeUndefined();
    expect(widget.at.get(first).displayValue).toBe(
      new Date('2026-10-14T10:00:00.000Z').toLocaleDateString('en-US'),
    );
    expect(widget.label.get(first).value).toBe('a');
    expect(widget.tooltip.get(first).value).toBe('Point');
    expect(widget.cell.get(first)).toEqual(<i>2</i>);
    widget.onPoint.get(first).execute();
    expect(props.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Open' }),
      records[1],
    );

    expect(widget.target.value).toEqual(new Big('1'));
    expect(widget.target.displayValue).toBe('1');
    widget.target.setValue(new Big('4.25'));
    expect(props.onChange).toHaveBeenCalledWith('App.Point.Value', { __mxrb_decimal: '4.25' });
    widget.target.setTextValue('5');
    expect(props.onChange).toHaveBeenLastCalledWith('App.Point.Value', '5');
    expect(widget.target.formatter.format(new Date('2026-01-02T00:00:00.000Z'))).toBe(
      '2026-01-02T00:00:00.000Z',
    );
    expect(widget.target.formatter.format(undefined)).toBe('');
    expect(widget.target.formatter.parse('x')).toEqual({ valid: true, value: 'x' });
    expect(widget.caption.value).toBe('Caption');
    expect(widget.mode.value).toBe('date');
    expect(widget.onClick.canExecute).toBe(true);
    widget.onClick.execute();
    expect(props.onAction).toHaveBeenLastCalledWith(expect.anything(), props.context);
    expect(widget.header).toEqual(<b>Header</b>);
    expect(widget.title).toBe('Chart');
    expect(widget.limit).toEqual(new Big('2.5'));
    expect(widget.icon.value).toEqual({ type: 'glyph', iconClass: 'glyphicon-star' });
    expect(widget.picture.value).toEqual({ uri: '/img/a.png' });
    expect(widget.series).toEqual([{ name: 'S1' }, { name: 'S2' }]);
    expect(widget.single).toEqual({ name: 'Only' });
    expect(widget.selection).toBeUndefined();

    act(() => widget.points.setSortOrder([[widget.y.id, 'desc']]));
    expect(current().points.items.map((item: { id: string }) => item.id)).toEqual(['3', '1', '2']);
    act(() => current().points.setFilter(greaterThan(attribute(widget.y.id), literal(new Big(2)))));
    expect(current().points.items.map((item: { id: string }) => item.id)).toEqual(['3', '1']);
    act(() => current().points.setLimit(1));
    expect(current().points.hasMoreItems).toBe(true);
    act(() => current().points.setOffset(1));
    expect(current().points.items.map((item: { id: string }) => item.id)).toEqual(['1']);
    act(() => current().points.setSortOrder(undefined));
    act(() => current().points.setFilter(undefined));
    act(() => current().points.setLimit(undefined));
    expect(current().points.items).toHaveLength(3);
    expect(current().points.sortOrder).toEqual([]);
    current().points.requestTotalCount();

    act(() => current().points.reload());
    await waitFor(() => expect(request).toHaveBeenCalledTimes(2));
    unregister();
  });

  it('leaves unset properties empty and shows image icons and empty data sources', async () => {
    const { unregister, current } = host(
      { points: {}, icon: { uri: 'img/icon.png' }, onClick: null },
      [],
    );
    await waitFor(() => expect(current().points.status).toBe('available'));
    const widget = current();
    expect(widget.points.items).toEqual([]);
    expect(widget.y).toBeUndefined();
    expect(widget.target).toBeUndefined();
    expect(widget.label).toBeUndefined();
    expect(widget.caption.value).toBe('');
    expect(widget.onClick).toBeUndefined();
    expect(widget.limit).toBeUndefined();
    expect(widget.picture).toBeUndefined();
    expect(widget.series).toEqual([]);
    expect(widget.single).toBeUndefined();
    expect(widget.icon.value).toEqual({ type: 'image', iconUrl: 'img/icon.png' });
    unregister();
  });

  it('rejects a widget build without its component', () => {
    expect(() => registerProjectWidget('example.Empty', {}, 'Empty', [])).toThrow(
      'Widget build example.Empty exports no Empty component',
    );
  });

  it('converts values between the runtime and the widget API', () => {
    expect(apiValue(null)).toBeUndefined();
    expect(apiValue('')).toBeUndefined();
    expect(apiValue(3)).toEqual(new Big(3));
    expect(apiValue('2026-01-02T00:00:00.000Z', 'DateTime')).toEqual(
      new Date('2026-01-02T00:00:00.000Z'),
    );
    expect(apiValue('text', 'String')).toBe('text');
    expect(runtimeValue(undefined)).toBeNull();
    expect(runtimeValue(new Big('1.25'), 'Decimal')).toEqual({ __mxrb_decimal: '1.25' });
    expect(runtimeValue(new Big('2'), 'Integer')).toBe(2);
    expect(runtimeValue(new Date('2026-01-02T00:00:00.000Z'))).toBe('2026-01-02T00:00:00.000Z');
    expect(runtimeValue(true)).toBe(true);
  });
});
