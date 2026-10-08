import { useEffect, type ComponentType, type CSSProperties } from 'react';
import { registerMarketplaceWidget, type MarketplaceWidgetProps } from './marketplace';
import { chartCaption, useCaptionEnvironment } from './captions';
import { classes, dynamicClass, inlineStyle } from './value';
import { mountFeedbackCapture } from './feedbackCapture';
import type { WidgetEvent } from '../types';

export interface NativeFeedbackProps {
  class: string;
  style: CSSProperties;
  tabIndex?: number;
  userDefinedButtonStyle: string;
  sprintrapp: string;
  scrollableAreaSelector: string;
  foreignObjectRendering: boolean;
  feedbackButtonAction: { canExecute: boolean; isExecuting: boolean; execute(): unknown };
  [key: string]: unknown;
}

const object = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' ? (value as Record<string, unknown>) : {};

export function registerFeedbackWidget(NativeWidget: ComponentType<NativeFeedbackProps>) {
  function FeedbackWidget(props: MarketplaceWidgetProps) {
    useEffect(mountFeedbackCapture, []);
    const environment = useCaptionEnvironment(props.schema);
    const options = props.widget.options || {};
    const properties = options.properties || {};
    const action = object(
      object(properties.feedbackButtonAction ?? properties.showFeedbackModalAction).action,
    );
    const canExecute = typeof action.kind === 'string' && typeof action.handler === 'string';
    const labels = Object.fromEntries(
      Object.entries({
        title_label: 'Feedback',
        cancel_label: 'Cancel',
        clear_label: 'Clear',
        annotate_label: 'Annotate',
        take_screenshot_label: 'Take screenshot',
        done_label: 'Done',
        feedbackStartButtonAriaLabel: 'Feedback',
      }).map(([name, fallback]) => [
        name,
        {
          status: 'available',
          value: chartCaption(properties[name] ?? fallback, props.context, environment),
        },
      ]),
    );
    const actionValue = {
      canExecute: canExecute && !props.actionRunning,
      isExecuting: Boolean(props.actionRunning),
      execute: () =>
        canExecute &&
        !props.actionRunning &&
        props.onAction?.({ ...action, event: 'click' } as WidgetEvent, props.context),
    };
    return (
      <NativeWidget
        {...labels}
        class={classes(
          `mx-name-${props.widget.name}`,
          options.class,
          dynamicClass(options.dynamic_class, props.context),
        )}
        style={inlineStyle(options.style)}
        tabIndex={typeof options.tab_index === 'number' ? options.tab_index : undefined}
        userDefinedButtonStyle={String(properties.userDefinedButtonStyle ?? 'side')}
        sprintrapp={String(properties.sprintrapp ?? '')}
        scrollableAreaSelector={String(properties.scrollableAreaSelector ?? '')}
        foreignObjectRendering={properties.foreignObjectRendering === true}
        targetContainerSelector={properties.targetContainerSelector}
        feedbackButtonAction={actionValue}
        showFeedbackModalAction={actionValue}
      />
    );
  }
  return registerMarketplaceWidget('SprintrFeedbackWidget.SprintrFeedback', FeedbackWidget);
}
