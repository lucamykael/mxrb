import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { WidgetRenderer } from './WidgetRenderer';
import { PageDataSource } from '../PageDataSource';
import { SelectionScope, useSelections } from './SelectionScope';
import type { WidgetRuntimeProps } from '../contracts';
import type { ApplicationSchema, EntityRecord, WidgetDefinition } from '../../types';

const record: EntityRecord = {
  id: '1',
  type: 'App.Item',
  attributes: { Name: 'Before', Active: false },
};
const field: WidgetDefinition = {
  type: 'text_box',
  name: 'Name',
  options: { attribute: 'App.Item.Name', caption: 'Name' },
};
const view: WidgetDefinition = {
  type: 'data_view',
  name: 'Details',
  options: {
    source: { kind: 'context' },
    editable: 'conditional',
    editability: { expression: '$currentObject/Active' },
  },
  body: [field],
};
const props = (widget: WidgetDefinition): WidgetRuntimeProps => ({
  widget,
  moduleName: 'App',
  invoke: vi.fn(),
  invokeNanoflow: vi.fn(),
  navigate: vi.fn(),
  context: record,
  pageContext: record,
  revision: 0,
  schema: { modules: [] } as unknown as ApplicationSchema,
  request: vi.fn(),
  saveRecord: vi.fn(async () => record),
  onError: vi.fn(),
  onMutation: vi.fn(),
  onSelectRecord: vi.fn(),
});

describe('Ruby data view editing', () => {
  it('routes Marketplace point actions through the page event executor with the clicked record', async () => {
    const chart: WidgetDefinition = {
      type: 'pluggable_widget',
      name: 'Chart',
      options: {
        widget_id: 'com.mendix.widget.web.columnchart.ColumnChart',
        properties: {
          series: {
            objects: [
              {
                staticDataSource: { data_source: 'App.Item' },
                staticXAttribute: 'Name',
                staticYAttribute: 'Value',
                staticName: 'Items',
                staticOnClickAction: {
                  action: {
                    kind: 'microflow',
                    handler: 'Select',
                    arguments: { Item: '$currentObject' },
                  },
                },
              },
            ],
          },
        },
      },
    };
    const input = props(chart);
    const point = { ...record, id: 'point', attributes: { Name: 'Clicked', Value: 8 } };
    render(<WidgetRenderer {...input} request={vi.fn().mockResolvedValue({ records: [point] })} />);
    await userEvent.click(await screen.findByRole('button', { name: 'Items Clicked: 8' }));
    expect(input.invoke).toHaveBeenCalledWith('App.Select', { Item: point }, point);
    expect(input.onError).not.toHaveBeenCalled();
  });

  it('uses the already loaded page source and follows its updated draft without invoking it again', () => {
    const sourced: WidgetDefinition = {
      ...view,
      options: { source: { kind: 'microflow', name: 'App.Load' } },
    };
    const input = props(sourced);
    const { rerender } = render(
      <PageDataSource.Provider value={sourced}>
        <WidgetRenderer {...input} />
      </PageDataSource.Provider>,
    );
    expect(screen.getByRole('textbox')).toHaveValue('Before');
    const updated = { ...record, attributes: { Name: 'Changed' } };
    rerender(
      <PageDataSource.Provider value={sourced}>
        <WidgetRenderer {...input} context={updated} />
      </PageDataSource.Provider>,
    );
    expect(screen.getByRole('textbox')).toHaveValue('Changed');
    expect(input.request).not.toHaveBeenCalled();
  });

  it('updates role-based visibility and editing when the authorized schema changes', () => {
    const guarded = {
      ...field,
      options: {
        ...field.options,
        editable: 'conditional',
        editability: { roles: ['App.Editor'] },
      },
    };
    const input = props(guarded);
    const { rerender } = render(<WidgetRenderer {...input} />);
    expect(screen.getByRole('textbox')).toBeDisabled();
    rerender(
      <WidgetRenderer {...input} schema={{ ...input.schema, module_roles: ['App.Editor'] }} />,
    );
    expect(screen.getByRole('textbox')).toBeEnabled();
    const hidden = {
      ...guarded,
      options: { ...guarded.options, visibility: { roles: ['App.Editor'] } },
    };
    rerender(<WidgetRenderer {...input} widget={hidden} />);
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
    rerender(
      <WidgetRenderer
        {...input}
        widget={hidden}
        schema={{ ...input.schema, module_roles: ['App.Editor'] }}
      />,
    );
    expect(screen.getByRole('textbox')).toBeEnabled();
  });

  it('applies data view visibility conditions and read-only text style', () => {
    const visible: WidgetDefinition = {
      ...view,
      options: {
        source: { kind: 'context' },
        editable: 'never',
        read_only_style: 'text',
        visibility: { expression: '$currentObject/Active' },
      },
    };
    const input = props(visible);
    const { rerender } = render(<WidgetRenderer {...input} />);
    expect(screen.queryByText('Name')).not.toBeInTheDocument();
    rerender(
      <WidgetRenderer
        {...input}
        context={{ ...record, attributes: { ...record.attributes, Active: true } }}
      />,
    );
    expect(screen.getByText('Before')).toBeInTheDocument();
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
  });
  it('listens to the named grid independently of other widget selections', async () => {
    const grid: WidgetDefinition = {
      type: 'data_grid',
      name: 'Items',
      options: {
        entity: 'App.Item',
        columns: [{ name: 'Name', attribute: 'Name' }],
        toolbar: { buttons: [] },
      },
    };
    const listener: WidgetDefinition = {
      ...view,
      options: { source: { kind: 'listen', target: 'App.Home.Items' } },
    };
    const request = vi.fn().mockResolvedValue({ records: [record] });
    function OtherSelections() {
      const selections = useSelections();
      return (
        <>
          <button
            onClick={() =>
              selections.select('Other', { ...record, id: '2', attributes: { Name: 'Other' } })
            }
          >
            Other selection
          </button>
          <button onClick={() => selections.select('Items', null)}>Clear selection</button>
        </>
      );
    }
    render(
      <SelectionScope>
        <WidgetRenderer {...props(grid)} request={request} />
        <WidgetRenderer {...props(listener)} />
        <OtherSelections />
      </SelectionScope>,
    );
    const user = userEvent.setup();
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
    await user.click(await within(screen.getByRole('table')).findByText('Before'));
    expect(await screen.findByRole('textbox')).toHaveValue('Before');
    await user.click(screen.getByText('Other selection'));
    expect(screen.getByRole('textbox')).toHaveValue('Before');
    await user.click(screen.getByText('Clear selection'));
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('traverses each association using the preceding object and stops at empty links', async () => {
    const associated: WidgetDefinition = {
      ...view,
      options: {
        source: {
          kind: 'association',
          entity: 'App.Final',
          steps: [
            { association: 'App.Item_Parent', entity: 'App.Parent' },
            { association: 'App.Parent_Final', entity: 'App.Final' },
          ],
        },
      },
    };
    const parent = { id: 'parent', type: 'App.Parent', attributes: {} };
    const final = { id: 'final', type: 'App.Final', attributes: { Name: 'Related' } };
    const request = vi
      .fn()
      .mockResolvedValueOnce({ records: [parent] })
      .mockResolvedValueOnce({ records: [final] });
    const { rerender } = render(<WidgetRenderer {...props(associated)} request={request} />);
    expect(await screen.findByRole('textbox')).toHaveValue('Related');
    const first = new URL(String(request.mock.calls[0][0]), 'http://local');
    const second = new URL(String(request.mock.calls[1][0]), 'http://local');
    expect(first.searchParams.get('context_id')).toBe('1');
    expect(second.searchParams.get('context_id')).toBe('parent');
    expect(second.searchParams.get('association')).toBe('App.Parent_Final');
    const empty = vi.fn().mockResolvedValue({ records: [] });
    rerender(<WidgetRenderer {...props(associated)} request={empty} revision={1} />);
    await waitFor(() => expect(screen.queryByRole('textbox')).not.toBeInTheDocument());
    expect(empty).toHaveBeenCalledTimes(1);
    const noContext = vi.fn();
    rerender(
      <WidgetRenderer
        {...props(associated)}
        request={noContext}
        context={null}
        pageContext={null}
      />,
    );
    await waitFor(() => expect(screen.queryByText('Loading…')).not.toBeInTheDocument());
    expect(noContext).not.toHaveBeenCalled();
  });

  it('shows an icon-only button and opens a page for the grid row acted on', async () => {
    const schema = {
      modules: [],
      presentation: {
        'Atlas.Icons.pencil': { kind: 'icon', path: '/assets/icons.woff', character: 59903 },
      },
    } as unknown as ApplicationSchema;
    const edit: WidgetDefinition = {
      type: 'button',
      name: 'editButton',
      options: { caption: '', icon: 'Atlas.Icons.pencil' },
    };
    render(<WidgetRenderer {...props(edit)} schema={schema} />);
    const button = screen.getByRole('button');
    expect(button).not.toHaveTextContent('editButton');
    expect(button.querySelector('[data-icon-collection="Atlas.Icons.pencil"]')).not.toBeNull();

    const row = { id: 'row', type: 'App.Item', attributes: { Name: 'Row' } };
    const grid: WidgetDefinition = {
      type: 'data_grid',
      name: 'grid',
      options: {
        entity: 'App.Item',
        presentation: 'datagrid2',
        columns: [{ name: 'Name', attribute: 'Name' }],
      },
      events: [{ event: 'on_click', kind: 'page', handler: 'App.Edit', arguments: {} }],
    };
    const input = props(grid);
    const request = vi.fn().mockResolvedValue({ records: [row] });
    render(<WidgetRenderer {...input} request={request} />);
    await userEvent.click(await screen.findByText('Row'));
    await waitFor(() =>
      expect(input.navigate).toHaveBeenCalledWith('App.Edit', row, expect.anything()),
    );
  });

  it('renders Studio Pro text modes, link buttons and Atlas tab containers', async () => {
    const title: WidgetDefinition = {
      type: 'text',
      name: 'title',
      options: { caption: 'Accounts', render_mode: 'h2' },
    };
    const { unmount } = render(<WidgetRenderer {...props(title)} />);
    expect(screen.getByRole('heading', { level: 2, name: 'Accounts' })).toHaveClass('mx-text');
    unmount();

    const link: WidgetDefinition = {
      type: 'button',
      name: 'open',
      options: { caption: 'Open', render_type: 'link' },
      events: [{ event: 'on_click', kind: 'page', handler: 'App.Edit', arguments: {} }],
    };
    const input = props(link);
    const second = render(<WidgetRenderer {...input} />);
    const anchor = screen.getByRole('button', { name: 'Open' });
    expect(anchor.tagName).toBe('A');
    expect(anchor).toHaveClass('mx-link');
    await userEvent.click(anchor);
    await waitFor(() => expect(input.navigate).toHaveBeenCalled());
    second.unmount();

    const tabs: WidgetDefinition = {
      type: 'tab_control',
      name: 'tabs',
      options: { tabs: [{ name: 'local', caption: 'Local Users', widgets: [] }] },
    };
    render(<WidgetRenderer {...props(tabs)} />);
    const tab = screen.getByRole('tab', { name: 'Local Users' });
    expect(tab.closest('ul')).toHaveClass('nav', 'nav-tabs', 'mx-tabcontainer-tabs');
    expect(tab.closest('li')).toHaveClass('active');
    expect(screen.getByRole('tabpanel')).toHaveClass('tab-pane', 'active');
  });

  it('adds theme design classes and shows icon-only sidebar toggles', () => {
    const schema = {
      modules: [],
      presentation: {
        'Atlas.Icons.menu': { kind: 'icon', path: '/assets/icons.woff', character: 59903 },
      },
    } as unknown as ApplicationSchema;
    const toggle: WidgetDefinition = {
      type: 'sidebar_toggle',
      name: 'toggle',
      options: {
        caption: '',
        tooltip: 'Toggle Menu',
        icon: 'Atlas.Icons.menu',
        design_class: 'btn-lg spacing-inner-top',
      },
    };
    render(<WidgetRenderer {...props(toggle)} schema={schema} />);
    const button = screen.getByRole('button', { name: 'Toggle Menu' });
    expect(button).toHaveClass('btn-lg', 'spacing-inner-top');
    expect(button).not.toHaveTextContent('Menu');
    expect(button.querySelector('[data-icon-collection="Atlas.Icons.menu"]')).not.toBeNull();
    const bar: WidgetDefinition = {
      type: 'container',
      name: 'bar',
      options: { design_class: 'flex-row flex-nowrap' },
    };
    const { container } = render(<WidgetRenderer {...props(bar)} />);
    expect(container.firstElementChild).toHaveClass('flex-row', 'flex-nowrap');
  });

  it('renders layout grids with the Atlas grid classes', () => {
    const grid: WidgetDefinition = {
      type: 'layout_grid',
      name: 'grid',
      options: {
        rows: [
          {
            options: { horizontal_alignment: 'end', vertical_alignment: 'center', gutters: false },
            columns: [
              { options: { desktop: 'auto', vertical_alignment: 'center' }, widgets: [] },
              { options: { desktop: 6, tablet: 12, phone: 'grow' }, widgets: [] },
              { options: {}, widgets: [] },
            ],
          },
        ],
      },
    };
    const { container } = render(<WidgetRenderer {...props(grid)} />);
    const root = container.firstElementChild!;
    expect(root).toHaveClass('mx-layoutgrid', 'mx-layoutgrid-fluid', 'container-fluid');
    const row = root.querySelector('.row')!;
    expect(row).toHaveClass('justify-content-end', 'align-items-center', 'no-gutters');
    const [auto, half, grow] = Array.from(row.children);
    expect(auto).toHaveClass('col-lg-auto', 'col-md-auto', 'col-auto', 'align-self-center');
    expect(half).toHaveClass('col-lg-6', 'col-md-12', 'col');
    expect(grow).toHaveClass('col-lg', 'col-md', 'col');
    const fixed = render(
      <WidgetRenderer {...props({ ...grid, options: { ...grid.options, width: 'fixed' } })} />,
    );
    expect(fixed.container.firstElementChild).toHaveClass('mx-layoutgrid-fixed', 'container');
  });

  it('keeps the fields and their drafts while an association view refreshes', async () => {
    const associated: WidgetDefinition = {
      ...view,
      options: {
        source: {
          kind: 'association',
          entity: 'App.Parent',
          steps: [{ association: 'App.Item_Parent', entity: 'App.Parent' }],
        },
      },
    };
    const parent = { id: 'parent', type: 'App.Parent', attributes: { Name: 'Saved' } };
    let refresh: (value: unknown) => void = () => {};
    const request = vi
      .fn()
      .mockResolvedValueOnce({ records: [parent] })
      .mockReturnValueOnce(new Promise((resolve) => (refresh = resolve)))
      .mockReturnValue(new Promise(() => {}));
    const { rerender } = render(<WidgetRenderer {...props(associated)} request={request} />);
    const input = await screen.findByRole('textbox');
    await userEvent.clear(input);
    await userEvent.type(input, 'Draft');
    rerender(<WidgetRenderer {...props(associated)} request={request} revision={1} />);
    expect(screen.queryByText('Loading…')).not.toBeInTheDocument();
    refresh({ records: [parent] });
    await waitFor(() => expect(request).toHaveBeenCalledTimes(2));
    expect(screen.getByRole('textbox')).toBe(input);
    expect(input).toHaveValue('Draft');

    const other = { ...record, id: '2' };
    rerender(
      <WidgetRenderer
        {...props(associated)}
        request={request}
        context={other}
        pageContext={other}
        revision={1}
      />,
    );
    expect(await screen.findByText('Loading…')).toBeInTheDocument();
  });

  it('updates conditional editability and prevents nested views from overriding a locked parent', () => {
    const input = props(view);
    const { rerender } = render(<WidgetRenderer {...input} />);
    expect(screen.getByRole('textbox', { name: 'Name' })).toBeDisabled();
    rerender(
      <WidgetRenderer
        {...input}
        context={{ ...record, attributes: { ...record.attributes, Active: true } }}
      />,
    );
    expect(screen.getByRole('textbox', { name: 'Name' })).toBeEnabled();
    const nested = {
      ...view,
      options: { source: { kind: 'context' }, editable: 'never' },
      body: [{ ...view, options: { source: { kind: 'context' }, editable: 'always' } }],
    };
    rerender(<WidgetRenderer {...input} widget={nested} />);
    expect(screen.getByRole('textbox', { name: 'Name' })).toBeDisabled();
  });

  it('retains edited source records and does not reload a data source when handlers change', async () => {
    const input = props({
      ...view,
      options: { source: { kind: 'microflow', name: 'App.Load' }, editable: 'always' },
    });
    const request = vi.fn().mockResolvedValue({ result: record });
    const save = vi.fn(async (_current, changes) => ({
      ...record,
      attributes: { ...record.attributes, ...changes },
    }));
    const { rerender } = render(<WidgetRenderer {...input} request={request} saveRecord={save} />);
    const field = await screen.findByRole('textbox');
    const user = userEvent.setup();
    await user.clear(field);
    await user.type(field, 'After');
    await user.tab();
    await waitFor(() => expect(save).toHaveBeenCalledTimes(1));
    rerender(
      <WidgetRenderer {...input} request={request} saveRecord={save} invokeNanoflow={vi.fn()} />,
    );
    expect(screen.getByRole('textbox')).toHaveValue('After');
    expect(request).toHaveBeenCalledTimes(1);
  });
});
