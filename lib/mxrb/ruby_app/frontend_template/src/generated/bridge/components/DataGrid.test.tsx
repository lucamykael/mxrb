import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import type {
  ApiRequest,
  ApplicationSchema,
  EntityRecord,
  WidgetDefinition,
} from '../../types';
import { columnValue, DataGrid, matchesGridFilter } from './DataGrid';

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
    expect(screen.getByRole('table').closest('.mx-grid')).toHaveClass('mx-datagrid');
    expect(screen.getByText('Alice')).toHaveClass('mx-datagrid-data-wrapper');
    expect(screen.getByRole('button', { name: 'Reload' })).toHaveClass('btn', 'btn-default');
    expect(screen.getByRole('button', { name: 'Sort Customer' })).toHaveClass(
      'mx-datagrid-head-caption',
    );
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
    expect(matchesGridFilter(12, '10', { type: 'number', operator: 'gt', options: [] })).toBe(true);
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
    expect(matchesGridFilter(null, '', { type: 'text', operator: 'empty', options: [] })).toBe(
      true,
    );
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

describe('Data grid 2', () => {
  const role = (name: string): EntityRecord => ({
    id: name,
    type: 'System.UserRole',
    attributes: { Name: name },
  });
  const accounts: EntityRecord[] = [
    {
      id: 'a',
      type: 'Admin.Account',
      attributes: {
        FullName: 'Ada',
        Active: true,
        LastLogin: '2026-10-01',
        UserRoles: [role('Administrator'), role('User')],
      },
    },
    {
      id: 'b',
      type: 'Admin.Account',
      attributes: { FullName: 'Bea', Active: false, LastLogin: null, UserRoles: [] },
    },
  ];
  const schema = {
    modules: [
      {
        models: [
          {
            name: 'Admin.Account',
            attributes: [{ name: 'FullName', type: 'string' }],
            generalization: { target: 'System.User' },
          },
          { name: 'System.User', attributes: [{ name: 'Active', type: 'boolean' }] },
        ],
      },
    ],
  } as unknown as ApplicationSchema;
  const grid: WidgetDefinition = {
    type: 'data_grid',
    name: 'accounts',
    options: {
      entity: 'Admin.Account',
      presentation: 'datagrid2',
      xpath: "[Name != empty and Owner = $currentObject]",
      on_click_trigger: 'double',
      sort: [{ attribute: 'Admin.Account.FullName', direction: 'Descending' }],
      columns: [
        { name: 'Full name', attribute: 'Admin.Account.FullName', size: 2 },
        {
          name: 'Roles',
          attribute: 'System.UserRole.Name',
          association_path: [{ association: 'System.UserRoles', entity: 'System.UserRole' }],
          filter: { type: 'drop_down' },
          sortable: false,
        },
        {
          name: 'Last login',
          attribute: 'System.User.LastLogin',
          dynamic_text: 'Seen {1}',
          parameters: ['$currentObject/LastLogin'],
          width: 'manual',
          size: 120,
          alignment: 'right',
        },
        {
          name: 'Active',
          attribute: 'System.User.Active',
          filter: { type: 'drop_down' },
          hidable: 'hidden',
        },
        {
          name: 'Actions',
          attribute: 'Admin.Account.FullName',
          content: [{ type: 'text', name: 'edit', options: { caption: 'Edit' } }],
          hidable: false,
          width: 'auto_fit',
        },
      ],
    },
    header: [{ type: 'button', name: 'new', options: { caption: 'New local user' } }],
  };

  it('lays out, fills and filters the columns as Data grid 2 does', async () => {
    const request = vi.fn().mockResolvedValue({ records: accounts });
    const onRowAction = vi.fn();
    const user = userEvent.setup();
    const owner: EntityRecord = { id: 'o', type: 'Admin.Owner', attributes: {} };
    render(
      <DataGrid
        widget={grid}
        request={request as unknown as ApiRequest}
        pageContext={owner}
        revision={0}
        onError={vi.fn()}
        onMutation={vi.fn()}
        onRowAction={onRowAction}
        onSelectRecord={vi.fn()}
        schema={schema}
        renderWidgets={(widgets, record, key) => (
          <span data-testid={key}>
            {widgets.map((widget) => `${widget.options?.caption} ${record?.id ?? 'grid'}`)}
          </span>
        )}
      />,
    );

    expect(await screen.findByText('Administrator, User')).toBeInTheDocument();
    const url = new URL(String(request.mock.calls[0][0]), 'http://mxrb.test');
    expect(url.searchParams.get('xpath')).toBe(grid.options?.xpath);
    expect(url.searchParams.get('xpath_context_id')).toBe('o');
    expect(screen.getByRole('grid')).toHaveStyle({
      gridTemplateColumns: '2fr 1fr 120px minmax(auto, auto) 54px',
    });
    expect(screen.getByLabelText('Grid header')).toHaveTextContent('New local user grid');
    expect(screen.getByTestId('a-Actions')).toHaveTextContent('Edit a');
    expect(screen.getByText('Seen 2026-10-01')).toHaveClass('td', 'align-column-right');
    const rows = screen.getAllByRole('row').slice(1);
    expect(rows[0]).toHaveTextContent('Bea');
    expect(screen.queryByRole('combobox', { name: 'Filter Roles' })).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Column selector' }));
    const chooser = screen.getByRole('group', { name: 'Visible columns' });
    expect(within(chooser).queryByText('Actions')).not.toBeInTheDocument();
    await user.click(within(chooser).getByRole('checkbox', { name: 'Active' }));
    await user.selectOptions(screen.getByRole('combobox', { name: 'Filter Active' }), 'false');
    expect(screen.queryByText('Ada')).not.toBeInTheDocument();
    expect(screen.getByText('Bea')).toBeInTheDocument();

    await user.click(screen.getByText('Bea'));
    expect(onRowAction).not.toHaveBeenCalled();
    await user.dblClick(screen.getByText('Bea'));
    expect(onRowAction).toHaveBeenCalledWith(accounts[1]);
  });

  it('shows boolean attributes as Yes and No', async () => {
    const flags: WidgetDefinition = {
      type: 'data_grid',
      name: 'flags',
      options: {
        entity: 'Admin.Account',
        presentation: 'datagrid2',
        columns: [{ name: 'Active', attribute: 'System.User.Active' }],
      },
    };
    render(
      <DataGrid
        widget={flags}
        request={vi.fn().mockResolvedValue({ records: accounts }) as unknown as ApiRequest}
        pageContext={null}
        revision={0}
        onError={vi.fn()}
        onMutation={vi.fn()}
        onRowAction={vi.fn()}
        onSelectRecord={vi.fn()}
      />,
    );
    expect(await screen.findByText('Yes')).toHaveClass('td');
    expect(screen.getByText('No')).toHaveClass('td');
  });

  it('reads a column over a reference or a reference set', () => {
    const column = {
      attribute: 'System.UserRole.Name',
      association_path: [{ association: 'System.UserRoles', entity: 'System.UserRole' }],
    };
    expect(columnValue(accounts[0], column)).toEqual(['Administrator', 'User']);
    expect(columnValue(accounts[1], column)).toEqual([]);
    const single = { ...accounts[1], attributes: { UserRoles: role('User') } };
    expect(columnValue(single, column)).toBe('User');
  });
});
