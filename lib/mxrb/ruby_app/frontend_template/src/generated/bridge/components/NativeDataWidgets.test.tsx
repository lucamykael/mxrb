import { act, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  MarketplaceWidget,
  type MarketplaceWidgetProps,
  type MarketplaceWidgetRegion,
} from '../marketplace';
import { GalleryFilterContext, NativeGalleryTextFilter, matchesText } from './NativeDataWidgets';
import type { ApiRequest, ApplicationSchema, EntityRecord } from '../../types';

const item = (
  id: string,
  name: string,
  extra: Record<string, string | number> = {},
): EntityRecord => ({
  id,
  type: 'App.Item',
  attributes: { Name: name, ...extra },
});
const action = (handler: string) => ({ action: { kind: 'nanoflow', handler, arguments: {} } });
const region = (path: string, label: string): MarketplaceWidgetRegion => ({
  path: [path],
  role: path,
  content: <span>{label}</span>,
  render: (record) => <span key={record.id}>{`${label} ${String(record.attributes.Name)}`}</span>,
});
const source = { data_source: { entity: 'App.Item', xpath: '', sort: [] } };
const widget = (
  kind: string,
  properties: Record<string, unknown>,
  records: EntityRecord[],
  extra: Partial<MarketplaceWidgetProps> = {},
): MarketplaceWidgetProps => ({
  widget: {
    type: 'pluggable_widget',
    name: kind,
    options: { widget_id: `com.mendix.widget.native.${kind.toLowerCase()}.${kind}`, properties },
  },
  context: item('ctx', 'Context'),
  schema: { modules: [] } as unknown as ApplicationSchema,
  request: vi.fn(async () => ({ records })) as unknown as ApiRequest,
  onChange: vi.fn(async () => null),
  onAction: vi.fn(async () => undefined),
  ...extra,
});

afterEach(() => vi.useRealTimers());

describe('native data widgets', () => {
  it('renders the gallery content per object, pages it and runs the click action with the object', async () => {
    const records = [item('1', 'One'), item('2', 'Two'), item('3', 'Three')];
    const input = widget(
      'Gallery',
      {
        datasource: source,
        pageSize: 2,
        pagination: 'buttons',
        loadMoreButtonCaption: 'More please',
        phoneColumns: 2,
        onClick: action('App.Open'),
      },
      records,
      {
        regions: [region('content', 'Item'), region('emptyPlaceholder', 'Nothing here')],
      },
    );
    render(<MarketplaceWidget {...input} />);
    await screen.findByText('Item One');
    expect(screen.queryByText('Item Three')).not.toBeInTheDocument();
    expect(screen.getByRole('list')).toHaveStyle({
      gridTemplateColumns: 'repeat(2, minmax(0, 1fr))',
    });
    fireEvent.click(screen.getByRole('button', { name: 'More please' }));
    expect(screen.getByText('Item Three')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'More please' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Item Two' }));
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Open' }),
      records[1],
    );
    expect(screen.queryByText('Nothing here')).not.toBeInTheDocument();
  });

  it('shows the empty placeholder, refreshes on pull down and filters through the text filter', async () => {
    vi.useFakeTimers();
    const records = [item('1', 'Apple', { Count: 3 }), item('2', 'Banana', { Count: 10 })];
    const input = widget(
      'Gallery',
      {
        datasource: source,
        scrollDirection: 'horizontal',
        pullDown: action('App.Refresh'),
        filterList: { objects: [{ filter: 'App.Item.Name' }] },
      },
      records,
      {
        regions: [
          region('content', 'Row'),
          region('emptyPlaceholder', 'Nothing here'),
          {
            path: ['filtersPlaceholder'],
            role: 'filtersPlaceholder',
            content: (
              <MarketplaceWidget
                {...widget(
                  'GalleryTextFilter',
                  {
                    defaultFilter: 'startsWith',
                    placeholder: 'Search',
                    delay: 100,
                    valueAttribute: 'App.Item.Query',
                    onChange: action('App.Filtered'),
                  },
                  [],
                )}
              />
            ),
          },
        ],
      },
    );
    render(<MarketplaceWidget {...input} />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(screen.getByText('Row Apple')).toBeInTheDocument();
    expect(screen.getByRole('list')).toHaveClass('mxrb-native-gallery__items--horizontal');
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search' }), {
      target: { value: 'ban' },
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(150);
    });
    expect(screen.queryByText('Row Apple')).not.toBeInTheDocument();
    expect(screen.getByText('Row Banana')).toBeInTheDocument();
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search' }), {
      target: { value: 'zzz' },
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(150);
    });
    expect(screen.getByText('Nothing here')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Refresh' }),
      input.context,
    );
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(input.request).toHaveBeenCalledTimes(2);
  });

  it('writes the filter text to its attribute even outside a gallery', async () => {
    vi.useFakeTimers();
    const input = widget(
      'GalleryTextFilter',
      { valueAttribute: 'App.Item.Query', onChange: action('App.Filtered'), defaultValue: "'pre'" },
      [],
    );
    const set = vi.fn();
    render(
      <GalleryFilterContext.Provider value={{ value: '', operator: 'contains', set }}>
        <NativeGalleryTextFilter {...input} />
      </GalleryFilterContext.Provider>,
    );
    expect(screen.getByRole('searchbox')).toHaveValue('pre');
    await act(async () => {
      await vi.advanceTimersByTimeAsync(600);
    });
    expect(set).toHaveBeenCalledWith('pre', 'contains');
    expect(input.onChange).toHaveBeenCalledWith('App.Item.Query', 'pre');
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Filtered' }),
      input.context,
    );
  });

  it('compares values with every filter operator', () => {
    expect(matchesText('Banana', 'ban', 'contains')).toBe(true);
    expect(matchesText('Banana', 'ban', 'startsWith')).toBe(true);
    expect(matchesText('Banana', 'ana', 'endsWith')).toBe(true);
    expect(matchesText('Banana', 'banana', 'equal')).toBe(true);
    expect(matchesText('Banana', 'banana', 'notEqual')).toBe(false);
    expect(matchesText(10, '3', 'greater')).toBe(true);
    expect(matchesText(3, '3', 'greaterEqual')).toBe(true);
    expect(matchesText(3, '10', 'smaller')).toBe(true);
    expect(matchesText(10, '10', 'smallerEqual')).toBe(true);
    expect(matchesText('', '', 'empty')).toBe(true);
    expect(matchesText(null, '', 'notEmpty')).toBe(false);
  });

  it('repeats its content for every object and reports a failing source', async () => {
    render(
      <MarketplaceWidget
        {...widget('Repeater', { datasource: source }, [item('1', 'One'), item('2', 'Two')], {
          regions: [region('content', 'Line')],
        })}
      />,
    );
    expect(await screen.findByText('Line One')).toBeInTheDocument();
    expect(screen.getByText('Line Two')).toBeInTheDocument();
    const failing = widget('Repeater', { datasource: source }, [], {
      request: vi.fn(async () => {
        throw new Error('offline');
      }) as unknown as ApiRequest,
    });
    render(<MarketplaceWidget {...failing} />);
    expect(await screen.findByRole('alert')).toHaveTextContent('offline');
  });

  it('shows one carousel slide at a time with pagination', async () => {
    render(
      <MarketplaceWidget
        {...widget(
          'Carousel',
          { contentSource: source, layout: 'fullWidth', showPagination: true },
          [item('1', 'One'), item('2', 'Two')],
          { regions: [region('content', 'Slide')] },
        )}
      />,
    );
    const carousel = await screen.findByRole('region', { name: 'Carousel' });
    expect(carousel).toHaveClass('mxrb-native-carousel--fullWidth');
    expect(screen.getByText('Slide One')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Previous slide' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Next slide' }));
    expect(screen.getByText('Slide Two')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Next slide' })).toBeDisabled();
    fireEvent.click(within(screen.getByRole('list')).getByRole('button', { name: 'Slide 1' }));
    expect(screen.getByText('Slide One')).toBeInTheDocument();
  });
});
