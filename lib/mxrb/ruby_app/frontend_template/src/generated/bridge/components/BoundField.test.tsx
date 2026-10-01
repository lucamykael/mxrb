import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { fireEvent as dispatchEvent } from '@testing-library/dom';
import userEvent from '@testing-library/user-event';
import { useLayoutEffect } from 'react';
import { describe, expect, it, vi } from 'vitest';
import type { ApplicationSchema, EntityRecord, WidgetDefinition } from '../../types';
import { BoundField } from './BoundField';
import { ReadOnlyContext, ReadOnlyStyleContext } from './FieldPolicy';

const record: EntityRecord = {
  id: '1',
  type: 'App.Item',
  attributes: { Name: 'Before', Active: true },
};
const widget: WidgetDefinition = {
  name: 'Name',
  type: 'text_box',
  options: { attribute: 'App.Item.Name', aria_label: 'Name' },
};
const props = () => ({
  widget,
  record,
  schema: { modules: [] } as unknown as ApplicationSchema,
  request: vi.fn(),
  saveRecord: vi.fn(async (_record, changes) => ({
    ...record,
    attributes: { ...record.attributes, ...changes },
  })),
  revision: 0,
  onError: vi.fn(),
  onChanged: vi.fn(),
  onEntered: vi.fn(),
  onLeft: vi.fn(),
});

describe('editable exported fields', () => {
  it('does not overwrite an edit made before passive initialization effects run', async () => {
    function EarlyEdit() {
      useLayoutEffect(() => {
        dispatchEvent.change(screen.getByRole('textbox'), { target: { value: 'Early edit' } });
      }, []);
      return <BoundField {...props()} />;
    }
    await act(async () => {
      render(<EarlyEdit />);
    });
    expect(screen.getByRole('textbox')).toHaveValue('Early edit');
  });
  it('preserves a newer draft across server updates but resets it for another record', () => {
    const input = props();
    const { rerender } = render(<BoundField {...input} />);
    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'Unsaved draft' } });
    rerender(
      <BoundField {...input} record={{ ...record, attributes: { Name: 'Server update' } }} />,
    );
    expect(screen.getByRole('textbox')).toHaveValue('Unsaved draft');
    rerender(
      <BoundField
        {...input}
        record={{ ...record, id: '2', attributes: { Name: 'Another item' } }}
      />,
    );
    expect(screen.getByRole('textbox')).toHaveValue('Another item');
  });
  it('inherits read-only presentation without revealing password values', () => {
    render(
      <ReadOnlyContext.Provider value={true}>
        <ReadOnlyStyleContext.Provider value="text">
          <BoundField
            {...props()}
            widget={{
              ...widget,
              options: { ...widget.options, password: true, read_only_style: 'inherit' },
            }}
          />
        </ReadOnlyStyleContext.Provider>
      </ReadOnlyContext.Provider>,
    );
    expect(screen.getByText('••••••••')).toBeInTheDocument();
    expect(screen.queryByText('Before')).not.toBeInTheDocument();
  });
  it('persists an edit before change and leave actions, without saving untouched fields', async () => {
    const input = props();
    const order: string[] = [];
    input.saveRecord.mockImplementation(async (_record, changes) => {
      order.push('save');
      return { ...record, attributes: { ...record.attributes, ...changes } };
    });
    input.onChanged.mockImplementation(() => order.push('change'));
    input.onLeft.mockImplementation(() => order.push('leave'));
    const user = userEvent.setup();
    render(<BoundField {...input} />);
    await user.click(screen.getByRole('textbox'));
    await user.clear(screen.getByRole('textbox'));
    await user.type(screen.getByRole('textbox'), 'After');
    await user.tab();
    await waitFor(() => expect(order).toEqual(['save', 'change', 'leave']));
    expect(input.onEntered).toHaveBeenCalledWith(record);
    expect(input.onLeft).toHaveBeenCalledWith(
      expect.objectContaining({ attributes: { Name: 'After', Active: true } }),
    );
    await user.click(screen.getByRole('textbox'));
    await user.tab();
    expect(input.saveRecord).toHaveBeenCalledTimes(1);
  });

  it('keeps fields disabled inside a read-only view even when locally editable', () => {
    const input = props();
    render(
      <ReadOnlyContext.Provider value={true}>
        <BoundField {...input} />
      </ReadOnlyContext.Provider>,
    );
    const field = screen.getByRole('textbox');
    expect(field).toBeDisabled();
    fireEvent.change(field, { target: { value: 'Forbidden' } });
    fireEvent.blur(field);
    expect(input.saveRecord).not.toHaveBeenCalled();
  });

  it('applies exported input properties and read-only text presentation', () => {
    const input = props();
    const configured = {
      ...widget,
      options: {
        ...widget.options,
        password: true,
        placeholder: 'Secret',
        max_length: 12,
        autocomplete: 'off',
        aria_required: true,
        tab_index: 3,
      },
    };
    const { rerender } = render(<BoundField {...input} widget={configured} />);
    const field = screen.getByLabelText('Name');
    expect(field).toHaveAttribute('type', 'password');
    expect(field).toHaveAttribute('maxlength', '12');
    expect(field).toHaveAttribute('autocomplete', 'off');
    expect(field).toHaveAttribute('aria-required', 'true');
    expect(field).toHaveAttribute('tabindex', '3');
    rerender(
      <BoundField
        {...input}
        widget={{
          ...widget,
          options: { ...widget.options, editable: 'never', read_only_style: 'text' },
        }}
      />,
    );
    expect(screen.getByText('Before')).toBeInTheDocument();
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
  });

  it('reports rejected writes and does not run change or leave actions', async () => {
    const input = props();
    const failure = new Error('Write denied');
    input.saveRecord.mockRejectedValue(failure);
    render(<BoundField {...input} />);
    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'After' } });
    fireEvent.blur(screen.getByRole('textbox'));
    await waitFor(() => expect(input.onError).toHaveBeenCalledWith(failure));
    expect(input.onChanged).not.toHaveBeenCalled();
    expect(input.onLeft).not.toHaveBeenCalled();
  });
});
