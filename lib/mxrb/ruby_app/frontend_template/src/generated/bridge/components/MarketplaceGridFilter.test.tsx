import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget } from '../marketplace';
import type {
  ApiRequest,
  ApplicationSchema,
  EntityRecord,
  RuntimeValue,
  WidgetDefinition,
} from '../../types';
import { DataGrid } from './DataGrid';

const account = (id: string, FullName: string, Email: string): EntityRecord => ({
  id,
  type: 'Admin.Account',
  attributes: { FullName, Email, Active: true },
});
const accounts = [
  account('a', 'Ada Lovelace', 'ada@example.org'),
  account('b', 'Bea Smith', 'bea@lovelace.dev'),
  account('c', 'Cy Young', 'cy@example.org'),
];
const schema = {
  modules: [
    {
      models: [
        {
          name: 'Admin.Account',
          attributes: [
            { name: 'FullName', type: 'string' },
            { name: 'Email', type: 'string' },
            { name: 'Active', type: 'boolean' },
          ],
        },
      ],
    },
  ],
} as unknown as ApplicationSchema;
const textFilter = (properties: Record<string, unknown> = {}): WidgetDefinition => ({
  type: 'pluggable_widget',
  name: 'textFilter1',
  options: {
    widget_id: 'com.mendix.widget.web.datagridtextfilter.DatagridTextFilter',
    properties: {
      defaultFilter: 'contains',
      placeholder: 'Global search',
      delay: 0,
      screenReaderInputCaption: 'Search accounts',
      ...properties,
    },
  },
});
const grid = (
  header: WidgetDefinition[],
  options: Record<string, unknown> = {},
): WidgetDefinition => ({
  type: 'data_grid',
  name: 'accounts',
  options: {
    entity: 'Admin.Account',
    presentation: 'datagrid2',
    filter_attributes: ['Admin.Account.FullName', 'Admin.Account.Email', 'Admin.Account.Active'],
    columns: [{ name: 'Full name', attribute: 'Admin.Account.FullName' }],
    ...options,
  },
  header,
});

const renderGrid = (widget: WidgetDefinition, records = accounts, total?: number) => {
  const request = vi.fn().mockResolvedValue({ records, total });
  const onChange = vi.fn();
  const onAction = vi.fn().mockResolvedValue(undefined);
  render(
    <DataGrid
      widget={widget}
      request={request as unknown as ApiRequest}
      pageContext={null}
      revision={0}
      onError={vi.fn()}
      onMutation={vi.fn()}
      onRowAction={vi.fn()}
      onSelectRecord={vi.fn()}
      schema={schema}
      renderWidgets={(widgets, record) =>
        widgets.map((item) => (
          <MarketplaceWidget
            key={item.name}
            widget={item}
            context={record}
            schema={schema}
            onChange={onChange}
            onAction={onAction}
          />
        ))
      }
    />,
  );
  return { request, onChange, onAction };
};

const names = () =>
  screen
    .getAllByRole('row')
    .slice(1)
    .map((row) => row.textContent);

describe('Data grid 2 text filter in the filters placeholder', () => {
  it('matches any string attribute of the filter list', async () => {
    const user = userEvent.setup();
    renderGrid(grid([textFilter()]));
    expect(await screen.findByText('Cy Young')).toBeInTheDocument();
    const input = screen.getByRole('textbox', { name: 'Search accounts' });
    expect(input).toHaveAttribute('placeholder', 'Global search');
    expect(input).toHaveClass('form-control', 'filter-input');

    await user.type(input, 'LOVELACE');
    await waitFor(() => expect(names()).toEqual(['Ada Lovelace', 'Bea Smith']));
    await user.clear(input);
    await waitFor(() => expect(names()).toHaveLength(3));
  });

  it('starts with the default filter and lets the user change it when adjustable', async () => {
    const user = userEvent.setup();
    renderGrid(grid([textFilter({ defaultFilter: 'endsWith', adjustable: true })]));
    await screen.findByText('Cy Young');
    await user.type(screen.getByRole('textbox', { name: 'Search accounts' }), 'example.org');
    await waitFor(() => expect(names()).toEqual(['Ada Lovelace', 'Cy Young']));

    const selector = screen.getByRole('button', { name: 'Ends with' });
    await user.click(selector);
    await user.click(
      within(screen.getByRole('listbox', { name: 'Select filter type' })).getByText('Empty'),
    );
    expect(screen.getByRole('textbox', { name: 'Search accounts' })).toBeDisabled();
    await waitFor(() => expect(screen.queryAllByRole('row')).toHaveLength(1));
  });

  it('sends one any-of filter to the server and resets the page', async () => {
    const user = userEvent.setup();
    const { request } = renderGrid(
      grid([textFilter()], { server_side: true, page_size: 1 }),
      accounts.slice(0, 1),
      3,
    );
    await screen.findByText('Ada Lovelace');
    await user.click(screen.getByRole('button', { name: 'Go to next page' }));
    await user.type(screen.getByRole('textbox', { name: 'Search accounts' }), 'ada');
    await waitFor(() => {
      const url = new URL(String(request.mock.calls.at(-1)?.[0]), 'http://mxrb.test');
      expect(JSON.parse(url.searchParams.get('filters') || '[]')).toEqual([
        {
          any: [
            {
              attribute: 'Admin.Account.FullName',
              type: 'text',
              operator: 'contains',
              value: 'ada',
            },
            { attribute: 'Admin.Account.Email', type: 'text', operator: 'contains', value: 'ada' },
          ],
        },
      ]);
      expect(url.searchParams.get('offset')).toBe('0');
    });
  });

  it('writes the value attribute and runs the change action after the delay', async () => {
    const user = userEvent.setup();
    const onChangeAction = {
      action: { kind: 'nanoflow', handler: 'Admin.Searched', arguments: {} },
    };
    const { onChange, onAction } = renderGrid(
      grid([
        textFilter({
          defaultValue: "'Cy'",
          delay: 300,
          valueAttribute: 'Admin.Search.Text',
          onChange: onChangeAction,
        }),
      ]),
    );
    const input = await screen.findByRole('textbox', { name: 'Search accounts' });
    expect(input).toHaveValue('Cy');
    await waitFor(() => expect(names()).toEqual(['Cy Young']));
    expect(onChange).not.toHaveBeenCalled();

    await user.type(input, ' Y');
    await waitFor(() => expect(onAction).toHaveBeenCalledTimes(1));
    expect(onChange).toHaveBeenLastCalledWith('Admin.Search.Text', 'Cy Y');
    expect(onAction.mock.calls[0][0]).toMatchObject({
      kind: 'nanoflow',
      handler: 'Admin.Searched',
    });
  });

  it('reports a placement or attribute problem as the widget does', async () => {
    const onChange = vi.fn() as unknown as (
      attribute: string | undefined,
      value: RuntimeValue,
    ) => unknown;
    render(<MarketplaceWidget widget={textFilter()} context={null} onChange={onChange} />);
    expect(screen.getByText(/must be placed inside the header of the Data grid 2.0/)).toHaveClass(
      'alert',
      'alert-danger',
    );

    renderGrid(grid([textFilter()], { filter_attributes: ['Admin.Account.Active'] }));
    expect(
      await screen.findByText(/requires a "Hashed string or String" attribute/),
    ).toBeInTheDocument();
  });
});
