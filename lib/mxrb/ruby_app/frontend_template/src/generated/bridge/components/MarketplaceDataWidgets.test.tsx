import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, type MarketplaceWidgetProps } from '../marketplace';
import { PageParameters } from '../PageVariables';
import type { ApiRequest, ApplicationSchema, EntityRecord, RuntimeValue } from '../../types';

const item = (id: string, attributes: Record<string, RuntimeValue>): EntityRecord => ({
  id,
  type: 'App.Event',
  attributes,
});
const caption = (attribute: string) => ({
  text: '{1}',
  parameters: [`$currentObject/${attribute}`],
});
const action = { action: { kind: 'microflow', handler: 'App.Open', arguments: {} } };

const widgetProps = (
  widgetId: string,
  properties: Record<string, unknown>,
  extra: Partial<MarketplaceWidgetProps> = {},
): MarketplaceWidgetProps => ({
  widget: { type: 'pluggable_widget', name: 'Probe', options: { widget_id: widgetId, properties } },
  context: item('ctx', { Name: 'Context' }),
  schema: { modules: [] } as unknown as ApplicationSchema,
  onChange: vi.fn(),
  ...extra,
});

describe('tree node over its data source', () => {
  it('lists one node per object and renders its children region for that object', async () => {
    const records = [item('1', { Name: 'Root A' }), item('2', { Name: 'Root B' })];
    const request = vi.fn().mockResolvedValue({ records });
    const owner = item('o1', {});
    render(
      <PageParameters.Provider value={{ Owner: owner }}>
        <MarketplaceWidget
          {...widgetProps(
            'com.mendix.widget.web.treenode.TreeNode',
            {
              datasource: {
                data_source: { entity: 'App.Event', xpath: '[App.Event_Owner = $Owner]', sort: [] },
              },
              headerType: 'text',
              headerCaption: caption('Name'),
              hasChildren: true,
              startExpanded: false,
            },
            {
              request: request as unknown as ApiRequest,
              regions: [
                {
                  path: ['children'],
                  role: 'children',
                  content: null,
                  render: (record) => <span>children of {String(record.attributes.Name)}</span>,
                },
              ],
            },
          )}
        />
      </PageParameters.Provider>,
    );
    await screen.findByText('Root A');
    const sent = new URLSearchParams(String(request.mock.calls[0][0]).split('?')[1]);
    expect(JSON.parse(sent.get('xpath_variables') || '{}')).toEqual({
      Owner: { type: 'App.Event', id: 'o1' },
    });
    expect(screen.queryByText('children of Root A')).toBeNull();
    fireEvent.click(screen.getByText('Root A'));
    expect(screen.getByText('children of Root A')).toBeInTheDocument();
    expect(screen.getAllByRole('treeitem')[0]).toHaveAttribute('aria-expanded', 'true');
    expect(screen.queryByText('children of Root B')).toBeNull();
  });

  it('reports a missing data source', () => {
    render(<MarketplaceWidget {...widgetProps('com.mendix.widget.web.treenode.TreeNode', {})} />);
    expect(screen.getByRole('alert')).toHaveTextContent('Widget data source is unavailable');
  });
});

describe('timeline over its data source', () => {
  it('groups events by month, keeps ungrouped events and runs the click action', async () => {
    const records = [
      item('1', { Title: 'Kickoff', When: '2026-01-05T10:00:00Z' }),
      item('2', { Title: 'Review', When: '2026-01-20T10:00:00Z' }),
      item('3', { Title: 'Launch', When: '2026-03-02T10:00:00Z' }),
      item('4', { Title: 'Someday', When: null }),
    ];
    const onAction = vi.fn().mockResolvedValue(undefined);
    render(
      <MarketplaceWidget
        {...widgetProps(
          'com.mendix.widget.web.timeline.Timeline',
          {
            data: { data_source: { entity: 'App.Event', xpath: '', sort: [] } },
            title: caption('Title'),
            groupEvents: true,
            groupAttribute: 'App.Event.When',
            groupByKey: 'month',
            groupByMonthOptions: 'monthYear',
            ungroupedEventsPosition: 'end',
            onClick: action,
          },
          { request: vi.fn().mockResolvedValue({ records }) as unknown as ApiRequest, onAction },
        )}
      />,
    );
    await screen.findByText('Kickoff');
    expect(screen.getAllByRole('heading').map((heading) => heading.textContent)).toEqual([
      'January 2026',
      'March 2026',
    ]);
    const titles = screen
      .getAllByText(/Kickoff|Review|Launch|Someday/)
      .map((node) => node.textContent);
    expect(titles).toEqual(['Kickoff', 'Review', 'Launch', 'Someday']);
    fireEvent.click(screen.getByText('Launch'));
    expect(onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Open' }),
      records[2],
    );
  });

  it('renders a flat list when events are not grouped', async () => {
    render(
      <MarketplaceWidget
        {...widgetProps(
          'com.mendix.widget.web.timeline.Timeline',
          { data: { data_source: 'App.Event' }, title: caption('Title'), groupEvents: false },
          {
            request: vi.fn().mockResolvedValue({
              records: [item('1', { Title: 'Only' })],
            }) as unknown as ApiRequest,
          },
        )}
      />,
    );
    expect(await screen.findByText('Only')).toBeInTheDocument();
    expect(screen.queryByRole('heading')).toBeNull();
  });
});

describe('badge button and popup menu', () => {
  it('runs the badge button action with its caption and value', () => {
    const onAction = vi.fn().mockResolvedValue(undefined);
    render(
      <MarketplaceWidget
        {...widgetProps(
          'com.mendix.widget.custom.badgebutton.BadgeButton',
          { label: caption('Name'), value: { text: '3', parameters: [] }, onClickEvent: action },
          { onAction },
        )}
      />,
    );
    fireEvent.click(screen.getByRole('button'));
    expect(screen.getByRole('button')).toHaveTextContent('Context3');
    expect(onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Open' }),
      expect.anything(),
    );
  });

  it('opens basic items, hides invisible ones and runs the chosen action', async () => {
    const onAction = vi.fn().mockResolvedValue(undefined);
    render(
      <MarketplaceWidget
        {...widgetProps(
          'com.mendix.widget.web.popupmenu.PopupMenu',
          {
            basicItems: {
              objects: [
                { itemType: 'item', caption: { text: 'Edit', parameters: [] }, action },
                { itemType: 'divider' },
                { itemType: 'item', caption: { text: 'Hidden', parameters: [] }, visible: 'false' },
              ],
            },
          },
          {
            onAction,
            regions: [{ path: ['menuTrigger'], role: 'menuTrigger', content: 'Open menu' }],
          },
        )}
      />,
    );
    expect(screen.queryByRole('menu')).toBeNull();
    fireEvent.click(screen.getByText('Open menu'));
    expect(screen.getAllByRole('menuitem').map((node) => node.textContent)).toEqual(['Edit']);
    expect(screen.getByRole('separator')).toBeInTheDocument();
    fireEvent.click(screen.getByText('Edit'));
    await waitFor(() => expect(onAction).toHaveBeenCalled());
    expect(screen.queryByRole('menu')).toBeNull();
  });
});
