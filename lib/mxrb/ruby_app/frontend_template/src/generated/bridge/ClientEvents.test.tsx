import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WidgetRenderer } from './components/WidgetRenderer';
import { VariableEnvironment } from './PageVariables';
import { ClientActions, PageEdits } from './PageEdits';
import type { WidgetRuntimeProps } from './contracts';
import type { WidgetEvent } from '../types';

const props = (settings: WidgetEvent['settings'] = {}): WidgetRuntimeProps => ({
  widget: {
    name: 'Run',
    type: 'button',
    options: { caption: 'Run' },
    events: [{ event: 'on_click', kind: 'microflow', handler: 'App.Run', settings }],
  },
  moduleName: 'App',
  pageContext: null,
  schema: { project: { name: 'App', mendix_version: '11.12.1' }, modules: [] },
  revision: 0,
  invoke: vi.fn(),
  invokeNanoflow: vi.fn(),
  navigate: vi.fn(),
  request: vi.fn(),
  saveRecord: vi.fn(),
  onError: vi.fn(),
  onMutation: vi.fn(),
  onSelectRecord: vi.fn(),
});

afterEach(() => vi.useRealTimers());

describe('client action execution', () => {
  it('passes the current primitive variable on change without sending a synthetic entity to the server', async () => {
    const input = props();
    const field = {
      name: 'Draft',
      type: 'text_box',
      options: { caption: 'Draft', source_variable: { kind: 'local_variable', name: 'Draft' } },
      events: [
        {
          event: 'on_change',
          kind: 'microflow',
          handler: 'App.Changed',
          arguments: { Value: { kind: 'local_variable', name: 'Draft' } },
        },
      ],
    };
    render(
      <VariableEnvironment
        parameters={{}}
        definitions={[{ name: 'Draft', type: { kind: 'string' }, default: "'Original'" }]}
        context={null}
        schema={input.schema}
      >
        <WidgetRenderer {...input} widget={field} />
      </VariableEnvironment>,
    );
    const control = screen.getByRole('textbox', { name: 'Draft' });
    fireEvent.change(control, { target: { value: 'Changed' } });
    fireEvent.blur(control);
    await waitFor(() =>
      expect(input.invoke).toHaveBeenCalledWith('App.Changed', { Value: 'Changed' }, null),
    );
    expect(input.saveRecord).not.toHaveBeenCalled();
    expect(input.onError).not.toHaveBeenCalled();
  });

  it('prevents duplicate submissions on one button while another action remains usable', async () => {
    let complete!: (value: unknown) => void;
    const input = props();
    vi.mocked(input.invoke).mockReturnValue(
      new Promise((resolve) => {
        complete = resolve;
      }),
    );
    render(
      <>
        <WidgetRenderer {...input} />
        <button>Other</button>
      </>,
    );
    const button = screen.getByRole('button', { name: 'Run' });
    fireEvent.click(button);
    fireEvent.click(button);
    expect(input.invoke).toHaveBeenCalledTimes(1);
    expect(button).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Other' })).toBeEnabled();
    await act(async () => complete({ result: null }));
    expect(button).toBeEnabled();
  });

  it('honors repeated invocation and delays nonblocking progress until 500ms', async () => {
    vi.useFakeTimers();
    const completions: ((value: unknown) => void)[] = [];
    const input = props({
      disabled_during_execution: false,
      progress: 'NonBlocking',
      progress_message: 'Loading records',
    });
    vi.mocked(input.invoke).mockImplementation(
      () => new Promise((resolve) => completions.push(resolve)),
    );
    render(<WidgetRenderer {...input} />);
    const button = screen.getByRole('button', { name: 'Run' });
    fireEvent.click(button);
    fireEvent.click(button);
    expect(input.invoke).toHaveBeenCalledTimes(2);
    expect(button).toBeEnabled();
    act(() => vi.advanceTimersByTime(499));
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
    act(() => vi.advanceTimersByTime(1));
    expect(screen.getByRole('status')).toHaveTextContent('Loading records');
    await act(async () => completions[0]({ result: null }));
    expect(screen.getByRole('status')).toBeInTheDocument();
    await act(async () => completions[1]({ result: null }));
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('cancels before invocation and maps confirmed return values to local and page parameters', async () => {
    const input = props({
      confirmation: { question: 'Continue?' },
      outputs: [
        {
          source: { kind: 'local_variable', name: 'Answer' },
          expression: '$ActionReturnValue + 1',
        },
        { source: { kind: 'page_parameter', name: 'Input' }, expression: '$ActionReturnValue' },
      ],
    });
    vi.mocked(input.invoke).mockResolvedValue({ result: 41 });
    const confirm = vi.fn().mockResolvedValueOnce(false).mockResolvedValueOnce(true);
    const fields = ['Answer', 'Input'].map((name) => (
      <WidgetRenderer
        key={name}
        {...input}
        widget={{
          name,
          type: 'number_input',
          options: {
            caption: name,
            source_variable: {
              kind: name === 'Answer' ? 'local_variable' : 'page_parameter',
              name,
            },
          },
        }}
      />
    ));
    render(
      <ClientActions.Provider
        value={{ edits: new PageEdits(true), reset: 0, run: vi.fn(), confirm }}
      >
        <VariableEnvironment
          parameters={{ Input: 1 }}
          parameterDefinitions={[{ name: 'Input', type: { kind: 'integer' } }]}
          definitions={[{ name: 'Answer', type: { kind: 'integer' }, default: '0' }]}
          context={null}
          schema={input.schema}
        >
          <WidgetRenderer {...input} />
          {fields}
        </VariableEnvironment>
      </ClientActions.Provider>,
    );
    fireEvent.click(screen.getByRole('button', { name: 'Run' }));
    await waitFor(() => expect(screen.getByRole('button', { name: 'Run' })).toBeEnabled());
    expect(input.invoke).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Run' }));
    await waitFor(() => expect(screen.getByRole('spinbutton', { name: 'Answer' })).toHaveValue(42));
    expect(screen.getByRole('spinbutton', { name: 'Input' })).toHaveValue(41);
    expect(input.saveRecord).not.toHaveBeenCalled();
    expect(input.onError).not.toHaveBeenCalled();
  });
});
