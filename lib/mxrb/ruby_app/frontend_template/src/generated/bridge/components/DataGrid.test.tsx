import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import type { ApiRequest, EntityRecord, WidgetDefinition } from '../../types';
import { DataGrid, matchesGridFilter } from './DataGrid';

const records: EntityRecord[] = [
  { id: '1', type: 'App.Customer', attributes: { Name: 'Alice', City: 'Amsterdam' } },
  { id: '2', type: 'App.Customer', attributes: { Name: 'Bob', City: 'Boston' } },
  { id: '3', type: 'App.Customer', attributes: { Name: 'Alicia', City: 'Lisbon' } },
];

const widget: WidgetDefinition = {
  type: 'data_grid',
  name: 'Customers',
  options: {
    entity: 'App.Customer',
    page_size: 1,
    toolbar: { buttons: [] },
    columns: [
      { name: 'Name', attribute: 'Name', caption: 'Customer', filter: 'text' },
      { name: 'City', attribute: 'City', caption: 'City', filter: 'text' },
    ],
  },
};

describe('DataGrid', () => {
  it('filters configured columns together and resets pagination', async () => {
    const request = vi.fn().mockResolvedValue({ records }) as unknown as ApiRequest;
    const user = userEvent.setup();
    render(
      <DataGrid
        widget={widget}
        request={request}
        pageContext={null}
        revision={0}
        onError={vi.fn()}
        onMutation={vi.fn()}
        onRowAction={vi.fn()}
        onSelectRecord={vi.fn()}
      />,
    );

    expect(await screen.findByText('Alice')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Next' }));
    expect(screen.getByText('Bob')).toBeInTheDocument();

    await user.type(screen.getByRole('searchbox', { name: 'Filter Customer' }), 'ali');
    expect(screen.getByText('Alice')).toBeInTheDocument();
    expect(screen.queryByText('Bob')).not.toBeInTheDocument();
    expect(screen.getByText('Page 1 of 2 · 2 rows')).toBeInTheDocument();

    await user.type(screen.getByRole('searchbox', { name: 'Filter City' }), 'lis');
    const body = screen.getByRole('table').querySelector('tbody');
    expect(body).not.toBeNull();
    expect(within(body as HTMLElement).getByText('Alicia')).toBeInTheDocument();
    expect(within(body as HTMLElement).queryByText('Alice')).not.toBeInTheDocument();
    expect(screen.getByText('Page 1 of 1 · 1 rows')).toBeInTheDocument();
  });

  it('supports typed client-side operators', () => {
    expect(
      matchesGridFilter(12, '10', { type: 'number', operator: 'gt', options: [] }),
    ).toBe(true);
    expect(
      matchesGridFilter('2026-02-10', '2026-01-01,2026-03-01', {
        type: 'date',
        operator: 'between',
        options: [],
      }),
    ).toBe(true);
    expect(
      matchesGridFilter(false, 'true', {
        type: 'boolean',
        operator: 'not_equals',
        options: [],
      }),
    ).toBe(true);
    expect(
      matchesGridFilter('Pending', 'pending', {
        type: 'enum',
        operator: 'equals',
        options: [],
      }),
    ).toBe(true);
    expect(
      matchesGridFilter(null, '', { type: 'text', operator: 'empty', options: [] }),
    ).toBe(true);
  });

  it('sends filters, sorting, and pagination to the server-side collection endpoint', async () => {
    const request = vi.fn().mockResolvedValue({ records: records.slice(0, 2), total: 5 });
    const user = userEvent.setup();
    const serverWidget: WidgetDefinition = {
      type: 'data_grid',
      name: 'Customers',
      options: {
        entity: 'App.Customer',
        server_side: true,
        page_size: 2,
        sort: [{ attribute: 'Name', direction: 'Descending' }],
        toolbar: { buttons: [] },
        columns: [
          {
            name: 'Name',
            attribute: 'Name',
            filter: { type: 'text', operator: 'starts_with' },
          },
          {
            name: 'Score',
            attribute: 'Score',
            filter: { type: 'number', operator: 'gte' },
          },
          {
            name: 'Active',
            attribute: 'Active',
            filter: { type: 'boolean' },
          },
        ],
      },
    };
    render(
      <DataGrid
        widget={serverWidget}
        request={request as unknown as ApiRequest}
        pageContext={null}
        revision={0}
        onError={vi.fn()}
        onMutation={vi.fn()}
        onRowAction={vi.fn()}
        onSelectRecord={vi.fn()}
      />,
    );

    expect(await screen.findByText('Page 1 of 3 · 5 rows')).toBeInTheDocument();
    const first = new URL(String(request.mock.calls[0][0]), 'http://mxrb.test');
    expect(JSON.parse(first.searchParams.get('sort') || '[]')).toEqual([
      { attribute: 'Name', direction: 'Descending' },
    ]);
    expect(first.searchParams.get('limit')).toBe('2');

    await user.type(screen.getByRole('spinbutton', { name: 'Filter Score' }), '10');
    await waitFor(() => {
      const latest = new URL(String(request.mock.calls.at(-1)?.[0]), 'http://mxrb.test');
      expect(JSON.parse(latest.searchParams.get('filters') || '[]')).toContainEqual({
        attribute: 'Score',
        type: 'number',
        operator: 'gte',
        value: '10',
      });
    });

    await user.click(screen.getByRole('button', { name: 'Next' }));
    await waitFor(() => {
      const latest = new URL(String(request.mock.calls.at(-1)?.[0]), 'http://mxrb.test');
      expect(latest.searchParams.get('offset')).toBe('2');
    });
    await user.click(screen.getByRole('button', { name: 'Sort Name' }));
    await waitFor(() => {
      const latest = new URL(String(request.mock.calls.at(-1)?.[0]), 'http://mxrb.test');
      expect(JSON.parse(latest.searchParams.get('sort') || '[]')).toEqual([]);
      expect(latest.searchParams.get('offset')).toBe('0');
    });
  });
});
