import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import type { ApiRequest, EntityRecord, WidgetDefinition } from '../../types';
import { DataGrid } from './DataGrid';

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
});
