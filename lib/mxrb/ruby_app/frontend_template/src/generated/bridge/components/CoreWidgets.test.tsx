import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { WidgetRenderer } from './WidgetRenderer';
import { PageOutlet } from './PageOutlet';
import { ReadOnlyContext } from './FieldPolicy';
import type { WidgetRuntimeProps } from '../contracts';
import type {
  ApplicationSchema,
  EntityRecord,
  PageWidgetProps,
  WidgetDefinition,
} from '../../types';

const record: EntityRecord = {
  id: '1',
  type: 'App.Item',
  attributes: { Status: 'Open', Active: false, Name: 'Before' },
};
const schema: ApplicationSchema = {
  project: { name: 'Core widgets', mendix_version: '11.12.1' },
  modules: [
    {
      name: 'App',
      pages: [],
      models: [
        {
          name: 'App.Item',
          attributes: [
            { name: 'Status', type: 'Enumeration', enumeration: 'App.Status' },
            { name: 'Active', type: 'Boolean' },
          ],
        },
      ],
      enumerations: [
        {
          name: 'App.Status',
          id: 'status',
          values: [
            { name: 'Open', caption: 'In progress' },
            { name: 'Done', caption: 'Completed' },
          ],
        },
      ],
    },
  ],
};
const radio: WidgetDefinition = {
  name: 'Status',
  type: 'radio_button_group',
  options: { attribute: 'App.Item.Status', caption: 'Status', horizontal: true },
  events: [{ event: 'on_change', kind: 'microflow', handler: 'Changed' }],
};
const props = (widget: WidgetDefinition): WidgetRuntimeProps => ({
  widget,
  moduleName: 'App',
  context: record,
  pageContext: record,
  schema,
  revision: 0,
  invoke: vi.fn(),
  invokeNanoflow: vi.fn(),
  navigate: vi.fn(),
  request: vi.fn(),
  saveRecord: vi.fn(async (current, changes) => ({
    ...current!,
    attributes: { ...current?.attributes, ...changes },
  })),
  onError: vi.fn(),
  onMutation: vi.fn(),
  onSelectRecord: vi.fn(),
});

describe('Ruby core widgets', () => {
  it('accepts qualified backend enum values and preserves their representation on writes', async () => {
    const current = { ...record, attributes: { Status: 'App.Status.Open' } };
    const input = { ...props(radio), context: current };
    render(<WidgetRenderer {...input} />);
    expect(screen.getByRole('radio', { name: 'In progress' })).toBeChecked();
    await userEvent.setup().click(screen.getByRole('radio', { name: 'Completed' }));
    await waitFor(() =>
      expect(input.saveRecord).toHaveBeenCalledWith(current, { Status: 'App.Status.Done' }),
    );
    expect(screen.getByRole('radio', { name: 'Completed' })).toBeChecked();
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('uses native keyboard selection and fires enter/leave once per radio group', async () => {
    const input = props({
      ...radio,
      events: [
        { event: 'on_enter', kind: 'microflow', handler: 'Entered' },
        { event: 'on_leave', kind: 'microflow', handler: 'Left' },
      ],
    });
    render(
      <>
        <WidgetRenderer {...input} />
        <button>After group</button>
      </>,
    );
    const user = userEvent.setup();
    await user.tab();
    expect(screen.getByRole('radio', { name: 'In progress' })).toHaveFocus();
    await user.keyboard('{ArrowDown}');
    expect(screen.getByRole('radio', { name: 'Completed' })).toBeChecked();
    await waitFor(() => expect(input.saveRecord).toHaveBeenCalledTimes(1));
    expect(vi.mocked(input.invoke).mock.calls.map(([name]) => name)).toEqual(['App.Entered']);
    await user.tab();
    await waitFor(() =>
      expect(vi.mocked(input.invoke).mock.calls.map(([name]) => name)).toEqual([
        'App.Entered',
        'App.Left',
      ]),
    );
    expect(input.saveRecord).toHaveBeenCalledTimes(1);
  });
  it('renders enum captions and persists radio changes before the event', async () => {
    const input = props(radio);
    render(<WidgetRenderer {...input} />);
    const group = screen.getByRole('radiogroup', { name: 'Status' });
    expect(group).toHaveStyle({ flexDirection: 'row' });
    expect(within(group).getByRole('radio', { name: 'In progress' })).toBeChecked();
    await userEvent.setup().click(within(group).getByRole('radio', { name: 'Completed' }));
    await waitFor(() =>
      expect(input.invoke).toHaveBeenCalledWith(
        'App.Changed',
        {},
        expect.objectContaining({ attributes: expect.objectContaining({ Status: 'Done' }) }),
      ),
    );
    expect(input.saveRecord).toHaveBeenCalledWith(record, { Status: 'Done' });
    expect(screen.getByRole('radio', { name: 'Completed' })).toBeChecked();
  });

  it('keeps boolean values typed and reports rejected changes without invoking actions', async () => {
    const input = props({ ...radio, options: { attribute: 'App.Item.Active', caption: 'Active' } });
    const { rerender } = render(<WidgetRenderer {...input} />);
    const user = userEvent.setup();
    expect(screen.getByRole('radio', { name: 'No' })).toBeChecked();
    await user.click(screen.getByRole('radio', { name: 'Yes' }));
    await waitFor(() => expect(input.saveRecord).toHaveBeenCalledWith(record, { Active: true }));
    await user.click(screen.getByRole('radio', { name: 'No' }));
    await waitFor(() =>
      expect(input.saveRecord).toHaveBeenLastCalledWith(expect.anything(), { Active: false }),
    );
    const failure = new Error('Denied');
    const save = vi.fn().mockRejectedValue(failure);
    const invoke = vi.fn();
    rerender(<WidgetRenderer {...input} saveRecord={save} invoke={invoke} />);
    await user.click(screen.getByRole('radio', { name: 'Yes' }));
    await waitFor(() => expect(input.onError).toHaveBeenCalledWith(failure));
    expect(invoke).not.toHaveBeenCalled();
  });

  it('isolates repeated radio widgets and respects inherited and conditional locks', async () => {
    const input = props(radio);
    const { rerender } = render(
      <>
        <WidgetRenderer {...input} />
        <WidgetRenderer {...input} />
      </>,
    );
    const radios = screen.getAllByRole('radio', { name: 'In progress' });
    expect(radios[0].getAttribute('name')).not.toBe(radios[1].getAttribute('name'));
    await userEvent.setup().click(screen.getAllByRole('radio', { name: 'Completed' })[0]);
    expect(radios[1]).toBeChecked();
    rerender(
      <ReadOnlyContext.Provider value={true}>
        <WidgetRenderer {...input} />
      </ReadOnlyContext.Provider>,
    );
    screen.getAllByRole('radio').forEach((control) => expect(control).toBeDisabled());
    rerender(
      <WidgetRenderer
        {...input}
        widget={{
          ...radio,
          options: {
            ...radio.options,
            editable: 'conditional',
            editability: { expression: '$currentObject/Active' },
          },
        }}
      />,
    );
    screen.getAllByRole('radio').forEach((control) => expect(control).toBeDisabled());
    rerender(
      <WidgetRenderer
        {...input}
        widget={{
          ...radio,
          options: { ...radio.options, editable: 'never', read_only_style: 'text' },
        }}
      />,
    );
    expect(screen.queryByRole('radio')).not.toBeInTheDocument();
    expect(screen.getByText('In progress')).toBeInTheDocument();
  });

  it('reports unresolved choices and preserves unknown stored values without writing', () => {
    const input = props(radio);
    const { rerender } = render(<WidgetRenderer {...input} schema={{ ...schema, modules: [] }} />);
    expect(screen.getByRole('alert')).toHaveTextContent('Cannot resolve choices');
    rerender(
      <WidgetRenderer {...input} context={{ ...record, attributes: { Status: 'Legacy' } }} />,
    );
    expect(screen.getByRole('status')).toHaveTextContent('Unknown choice: Legacy');
    screen.getAllByRole('radio').forEach((control) => expect(control).not.toBeChecked());
    expect(input.saveRecord).not.toHaveBeenCalled();
  });

  it('uses the loaded page title, including inside nested widgets, and updates after source changes', () => {
    function Widget({ widget }: PageWidgetProps) {
      return <WidgetRenderer {...props(widget)} />;
    }
    const page = {
      name: 'App.Home',
      title: 'Exported title',
      widgets: [
        { type: 'container', name: 'Header', children: [{ type: 'page_title', name: 'Title' }] },
      ],
    };
    const { rerender } = render(<PageOutlet page={page} busy={false} Widget={Widget} />);
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Exported title');
    rerender(
      <PageOutlet page={{ ...page, title: 'Edited in Ruby' }} busy={false} Widget={Widget} />,
    );
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Edited in Ruby');
  });
});

const tabs: WidgetDefinition = {
  name: 'Details',
  type: 'tab_control',
  options: {
    tabs: [
      {
        name: 'Edit',
        caption: 'Edit item',
        widgets: [
          {
            name: 'Name',
            type: 'text_box',
            options: { attribute: 'App.Item.Name', caption: 'Name' },
          },
        ],
      },
      { name: 'Status', caption: 'Item status', widgets: [radio] },
    ],
  },
};

describe('interactive exported tabs', () => {
  it('supports keyboard navigation, associated panels and one tab stop', async () => {
    render(<WidgetRenderer {...props(tabs)} />);
    const user = userEvent.setup();
    const first = screen.getByRole('tab', { name: 'Edit item' });
    const second = screen.getByRole('tab', { name: 'Item status' });
    expect(first).toHaveAttribute('aria-selected', 'true');
    expect(second).toHaveAttribute('tabindex', '-1');
    expect(screen.getAllByRole('tabpanel')).toHaveLength(1);
    expect(screen.queryByRole('radio', { hidden: true })).not.toBeInTheDocument();
    first.focus();
    await user.keyboard('{ArrowRight}');
    expect(second).toHaveFocus();
    expect(second).toHaveAttribute('aria-selected', 'true');
    const panel = screen.getByRole('tabpanel', { name: 'Item status' });
    expect(second).toHaveAttribute('aria-controls', panel.id);
    expect(panel).toHaveAttribute('aria-labelledby', second.id);
    await user.keyboard('{ArrowRight}');
    expect(first).toHaveFocus();
    await user.keyboard('{End}');
    expect(second).toHaveFocus();
    await user.keyboard('{Home}');
    expect(first).toHaveFocus();
    await user.keyboard('{ArrowLeft}');
    expect(second).toHaveFocus();
  });

  it('retains mounted input drafts when switching panels and handles removed tabs', () => {
    const input = props(tabs);
    const { rerender } = render(<WidgetRenderer {...input} />);
    const field = screen.getByRole('textbox');
    fireEvent.change(field, { target: { value: 'Unsaved' } });
    fireEvent.click(screen.getByRole('tab', { name: 'Item status' }));
    expect(field).not.toBeVisible();
    fireEvent.click(screen.getByRole('tab', { name: 'Edit item' }));
    expect(screen.getByRole('textbox')).toBe(field);
    expect(field).toHaveValue('Unsaved');
    expect(input.saveRecord).not.toHaveBeenCalled();
    rerender(
      <WidgetRenderer
        {...input}
        widget={{ ...tabs, options: { tabs: tabs.options!.tabs!.slice(1) } }}
      />,
    );
    expect(screen.getByRole('tab', { name: 'Item status' })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    expect(screen.getByRole('tabpanel')).toBeVisible();
    rerender(<WidgetRenderer {...input} widget={{ ...tabs, options: { tabs: [] } }} />);
    expect(screen.queryByRole('tab')).not.toBeInTheDocument();
  });
});
