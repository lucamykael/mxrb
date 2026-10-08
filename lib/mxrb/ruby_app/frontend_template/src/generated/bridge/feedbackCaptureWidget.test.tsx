import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, type MarketplaceWidgetProps } from './marketplace';
import { registerFeedbackWidget, type NativeFeedbackProps } from './feedbackCaptureWidget';
import { feedbackScreenshot } from './feedbackCapture';

vi.mock('plotly.js-dist-min', () => ({ default: {} }));

describe('project-owned Feedback widget adapter', () => {
  it('forwards presentation and translated labels, executes with context and cancels on unmount', async () => {
    let received: NativeFeedbackProps;
    const unregister = registerFeedbackWidget((props) => {
      received = props;
      return <button onClick={() => props.feedbackButtonAction.execute()}>Native feedback</button>;
    });
    const props: MarketplaceWidgetProps = {
      widget: {
        type: 'pluggable_widget',
        name: 'Feedback',
        options: {
          widget_id: 'SprintrFeedbackWidget.SprintrFeedback',
          class: 'custom',
          style: 'color: red',
          tab_index: 4,
          properties: {
            userDefinedButtonStyle: 'normal',
            sprintrapp: 'application-id',
            foreignObjectRendering: true,
            scrollableAreaSelector: '.scrollable',
            title_label: { text: 'Report {1}', parameters: ['$currentObject/Name'] },
            feedbackButtonAction: { action: { kind: 'nanoflow', handler: 'App.Report' } },
          },
        },
      },
      context: { id: '1', type: 'App.Item', attributes: { Name: 'Example' } },
      onChange: vi.fn(),
      onAction: vi.fn(async () => undefined),
    };
    const view = render(<MarketplaceWidget {...props} />);
    expect(received!).toMatchObject({
      class: 'mx-name-Feedback custom',
      style: { color: 'red' },
      tabIndex: 4,
      userDefinedButtonStyle: 'normal',
      sprintrapp: 'application-id',
      foreignObjectRendering: true,
      scrollableAreaSelector: '.scrollable',
      title_label: { status: 'available', value: 'Report Example' },
      cancel_label: { status: 'available', value: 'Cancel' },
      feedbackButtonAction: { canExecute: true, isExecuting: false },
    });
    fireEvent.click(screen.getByText('Native feedback'));
    expect(props.onAction).toHaveBeenCalledWith(
      { kind: 'nanoflow', handler: 'App.Report', event: 'click' },
      props.context,
    );
    view.rerender(<MarketplaceWidget {...props} actionRunning />);
    expect(received!.feedbackButtonAction).toMatchObject({ canExecute: false, isExecuting: true });
    fireEvent.click(screen.getByText('Native feedback'));
    expect(props.onAction).toHaveBeenCalledTimes(1);
    const capture = feedbackScreenshot({});
    view.unmount();
    await expect(capture).resolves.toBe('uploadCancelled');
    unregister();
  });

  it('forwards the legacy action and the newer portal and accessibility properties', () => {
    let received: NativeFeedbackProps;
    const unregister = registerFeedbackWidget((props) => {
      received = props;
      return null;
    });
    const onAction = vi.fn(async () => undefined);
    const view = render(
      <MarketplaceWidget
        widget={{
          type: 'pluggable_widget',
          name: 'Feedback',
          options: {
            widget_id: 'SprintrFeedbackWidget.SprintrFeedback',
            properties: {
              showFeedbackModalAction: { action: { kind: 'nanoflow', handler: 'App.Legacy' } },
              targetContainerSelector: 'body',
              feedbackStartButtonAriaLabel: { text: 'Send report' },
            },
          },
        }}
        context={null}
        onChange={vi.fn()}
        onAction={onAction}
      />,
    );
    expect(received!).toMatchObject({
      targetContainerSelector: 'body',
      feedbackStartButtonAriaLabel: { value: 'Send report', status: 'available' },
    });
    expect(received!.showFeedbackModalAction).toBe(received!.feedbackButtonAction);
    received!.feedbackButtonAction.execute();
    expect(onAction).toHaveBeenCalledWith(
      { kind: 'nanoflow', handler: 'App.Legacy', event: 'click' },
      null,
    );
    view.unmount();
    unregister();
  });

  it('supplies native defaults and leaves unconfigured actions unavailable', () => {
    let received: NativeFeedbackProps;
    const unregister = registerFeedbackWidget((props) => {
      received = props;
      return null;
    });
    const view = render(
      <MarketplaceWidget
        widget={{
          type: 'pluggable_widget',
          name: 'Feedback',
          options: { widget_id: 'SprintrFeedbackWidget.SprintrFeedback' },
        }}
        context={null}
        onChange={vi.fn()}
      />,
    );
    expect(received!).toMatchObject({
      userDefinedButtonStyle: 'side',
      sprintrapp: '',
      scrollableAreaSelector: '',
      foreignObjectRendering: false,
    });
    expect(received!.tabIndex).toBeUndefined();
    expect(received!.feedbackButtonAction.canExecute).toBe(false);
    expect(received!.feedbackButtonAction.execute()).toBe(false);
    view.unmount();
    unregister();
  });
});
