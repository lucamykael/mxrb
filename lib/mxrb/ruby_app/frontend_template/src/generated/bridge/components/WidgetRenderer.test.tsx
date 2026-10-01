import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { WidgetRenderer } from './WidgetRenderer';
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
