import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, type MarketplaceWidgetProps } from '../marketplace';
import type { ApplicationSchema, EntityRecord, RuntimeValue } from '../../types';

const action = (handler: string) => ({ action: { kind: 'microflow', handler, arguments: {} } });

const widgetProps = (
  widgetId: string,
  properties: Record<string, unknown>,
  attributes: Record<string, RuntimeValue> = {},
  extra: Partial<MarketplaceWidgetProps> = {},
): MarketplaceWidgetProps => {
  const context: EntityRecord = { id: '1', type: 'App.Item', attributes };
  return {
    widget: {
      type: 'pluggable_widget',
      name: 'Interactive',
      options: { widget_id: widgetId, properties },
    },
    context,
    schema: { modules: [] } as unknown as ApplicationSchema,
    onChange: vi.fn(async (attribute: string | undefined, value: RuntimeValue) => {
      context.attributes[String(attribute).split('.').pop() || ''] = value;
    }),
    onAction: vi.fn().mockResolvedValue(undefined),
    ...extra,
  };
};

afterEach(() => vi.useRealTimers());

describe('events widget', () => {
  it('runs the load action after its delay and repeats it, and reacts to attribute changes', () => {
    vi.useFakeTimers();
    const props = widgetProps(
      'com.mendix.widget.web.events.Events',
      {
        onComponentLoad: action('App.Loaded'),
        componentLoadDelay: 100,
        componentLoadRepeat: true,
        componentLoadRepeatIntervalParameterType: 'expression',
        componentLoadRepeatIntervalExpression: '250',
        onEventChangeAttribute: 'App.Item.Status',
        onEventChange: action('App.Changed'),
        onEventChangeDelay: 0,
      },
      { Status: 'Open' },
    );
    const { rerender, unmount } = render(<MarketplaceWidget {...props} />);
    expect(props.onAction).not.toHaveBeenCalled();
    act(() => vi.advanceTimersByTime(100));
    act(() => vi.advanceTimersByTime(500));
    expect(props.onAction).toHaveBeenCalledTimes(3);
    expect(props.onAction).toHaveBeenLastCalledWith(
      expect.objectContaining({ handler: 'App.Loaded' }),
      props.context,
    );

    props.context!.attributes.Status = 'Closed';
    rerender(
      <MarketplaceWidget
        {...props}
        context={{ ...props.context!, attributes: { Status: 'Closed' } }}
      />,
    );
    act(() => vi.advanceTimersByTime(0));
    expect(props.onAction).toHaveBeenLastCalledWith(
      expect.objectContaining({ handler: 'App.Changed' }),
      expect.anything(),
    );
    unmount();
    const calls = vi.mocked(props.onAction!).mock.calls.length;
    act(() => vi.advanceTimersByTime(2000));
    expect(vi.mocked(props.onAction!).mock.calls.length).toBe(calls);
  });
});

describe('tab page selector', () => {
  it('opens the tab of the 1-based index and stores the clicked tab', () => {
    document.body.innerHTML = '';
    const tabs = document.createElement('div');
    tabs.className = 'mx-tabcontainer mx-name-tabs';
    tabs.innerHTML = '<ul><li><a>One</a></li><li><a>Two</a></li></ul>';
    document.body.append(tabs);
    const clicked: string[] = [];
    tabs
      .querySelectorAll('a')
      .forEach((link) => link.addEventListener('click', () => clicked.push(link.textContent!)));
    const props = widgetProps(
      'mendix.tabpageselector.TabPageSelector',
      { targetTabCtrl: 'tabs', paneIndexByAttr: 'App.Item.Pane' },
      { Pane: 2 },
    );
    render(<MarketplaceWidget {...props} />, {
      container: document.body.appendChild(document.createElement('div')),
    });
    expect(clicked).toEqual(['Two']);
    fireEvent.click(tabs.querySelectorAll('li')[0]);
    expect(props.onChange).toHaveBeenCalledWith('App.Item.Pane', 1);
  });
});

describe('dynamic enumeration picker', () => {
  const values = {
    objects: [
      { enumKey: 'low', enumValue: { text: 'Low', parameters: [] } },
      { enumKey: 'high', enumValue: { text: 'High', parameters: [] } },
    ],
  };

  it('sets the attribute from a dropdown and runs the change action', async () => {
    const props = widgetProps(
      'itvisors.dynamicenumpicker.DynamicEnumPicker',
      { enumAttribute: 'App.Item.Level', enumValues: values, onChangeAction: action('App.Picked') },
      { Level: 'low' },
    );
    render(<MarketplaceWidget {...props} />);
    expect(screen.getByRole('combobox')).toHaveValue('low');
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'high' } });
    await waitFor(() => expect(props.onAction).toHaveBeenCalled());
    expect(props.onChange).toHaveBeenCalledWith('App.Item.Level', 'high');
  });

  it('renders radio buttons', () => {
    const props = widgetProps(
      'itvisors.dynamicenumpicker.DynamicEnumPicker',
      { enumAttribute: 'App.Item.Level', enumValues: values, dropdownRadio: 'radio' },
      { Level: 'high' },
    );
    render(<MarketplaceWidget {...props} />);
    expect(screen.getByLabelText('High')).toBeChecked();
    fireEvent.click(screen.getByLabelText('Low'));
    expect(props.onChange).toHaveBeenCalledWith('App.Item.Level', 'low');
  });
});

describe('advanced pagination', () => {
  it('moves through pages within bounds and refreshes', async () => {
    const props = widgetProps(
      'mendix.advancedpagination.AdvancedPagination',
      {
        page: 'App.Item.Page',
        resultCount: 'App.Item.Count',
        pageSizeType: 'expression',
        pageSize: '10',
        refreshAction: action('App.Refresh'),
      },
      { Page: 2, Count: 35 },
    );
    render(<MarketplaceWidget {...props} />);
    expect(screen.getByText('11 to 20 of 35')).toBeInTheDocument();
    expect(screen.getByRole('button', { current: 'page' })).toHaveTextContent('2');
    fireEvent.click(screen.getByText('Last'));
    await waitFor(() => expect(props.onAction).toHaveBeenCalled());
    expect(props.onChange).toHaveBeenCalledWith('App.Item.Page', 4);
  });

  it('disables the edges on the only page', () => {
    render(
      <MarketplaceWidget
        {...widgetProps(
          'mendix.advancedpagination.AdvancedPagination',
          {
            page: 'App.Item.Page',
            resultCount: 'App.Item.Count',
            pageSizeType: 'attribute',
            pageSizeAttr: 'App.Item.Size',
          },
          { Page: 1, Count: 0, Size: 5 },
        )}
      />,
    );
    expect(screen.getByText('First')).toBeDisabled();
    expect(screen.getByText('Last')).toBeDisabled();
    expect(screen.getByText('0 to 0 of 0')).toBeInTheDocument();
  });
});

describe('JSON editor', () => {
  it('stores valid JSON and calls its microflow, rejecting invalid text', async () => {
    const props = widgetProps(
      'JSON.widget.Editor',
      { jsonStringAttr: 'App.Item.Json', onChangeMf: 'App.JsonChanged', editable: true },
      { Json: '{"a":1}' },
    );
    render(<MarketplaceWidget {...props} />);
    const editor = screen.getByLabelText('Interactive');
    fireEvent.change(editor, { target: { value: '{bad' } });
    fireEvent.blur(editor);
    expect(await screen.findByRole('alert')).toBeInTheDocument();
    expect(props.onChange).not.toHaveBeenCalled();
    fireEvent.change(editor, { target: { value: '{"a":2}' } });
    fireEvent.blur(editor);
    await waitFor(() => expect(props.onAction).toHaveBeenCalled());
    expect(props.onChange).toHaveBeenCalledWith('App.Item.Json', '{"a":2}');
    expect(props.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ kind: 'microflow', handler: 'App.JsonChanged' }),
      expect.anything(),
    );
  });
});
