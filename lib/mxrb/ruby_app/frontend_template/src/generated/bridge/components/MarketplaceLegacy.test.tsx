import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, type MarketplaceWidgetProps } from '../marketplace';
import { translatedText } from './MarketplaceLegacy';
import type { ApplicationSchema } from '../../types';

const widgetProps = (
  widgetId: string,
  properties: Record<string, unknown>,
  extra: Partial<MarketplaceWidgetProps> = {},
): MarketplaceWidgetProps => ({
  widget: {
    type: 'pluggable_widget',
    name: 'Legacy',
    options: { widget_id: widgetId, properties },
  },
  context: { id: '7', type: 'App.Item', attributes: { Name: 'Seven', Data: 'a,b\n"1,5",2\n' } },
  schema: { modules: [] } as unknown as ApplicationSchema,
  onChange: vi.fn(),
  ...extra,
});

afterEach(() => vi.useRealTimers());

describe('legacy widgets with projected microflow, nanoflow and translatable properties', () => {
  it('picks the session language of a translatable text', () => {
    expect(translatedText({ en_US: 'Hello', nl_NL: 'Hallo' }, 'nl-NL')).toBe('Hallo');
    expect(translatedText({ de_DE: 'Hallo', en_US: 'Hello' }, 'pt-BR')).toBe('Hello');
    expect(translatedText({ de_DE: 'Hallo' }, 'pt-BR')).toBe('Hallo');
    expect(translatedText('plain', 'en-US')).toBe('plain');
    expect(translatedText(undefined, 'en-US')).toBe('');
  });

  it('renders snippet HTML and calls its click microflow', () => {
    const onAction = vi.fn().mockResolvedValue(undefined);
    render(
      <MarketplaceWidget
        {...widgetProps(
          'HTMLSnippet.widget.HTMLSnippet',
          { contenttype: 'html', contents: { en_US: '<b>Bold</b>' }, onclickmf: 'App.Clicked' },
          { onAction },
        )}
      />,
    );
    fireEvent.click(screen.getByText('Bold'));
    expect(onAction).toHaveBeenCalledWith(
      expect.objectContaining({ kind: 'microflow', handler: 'App.Clicked' }),
      expect.objectContaining({ id: '7' }),
    );
  });

  it('runs snippet JavaScript with the element and the context MxObject, and shows its error', async () => {
    const onChange = vi.fn().mockResolvedValue(null);
    const { container } = render(
      <MarketplaceWidget
        {...widgetProps(
          'HTMLSnippet.widget.HTMLSnippetContext',
          {
            contenttype: 'js',
            contents: {
              en_US:
                "this.dataset.name = contextObj.get('Name') + '/' + contextObj.getGuid() + '/' + " +
                "contextObj.getEntity() + '/' + typeof mx.data.get; contextObj.set('Name', 'Eight');",
            },
          },
          { onChange },
        )}
      />,
    );
    expect(container.querySelector('.mxrb-html-snippet')).toHaveAttribute(
      'data-name',
      'Seven/7/App.Item/function',
    );
    await waitFor(() => expect(onChange).toHaveBeenCalledWith('Name', 'Eight'));
    const { container: plain } = render(
      <MarketplaceWidget
        {...widgetProps(
          'HTMLSnippet.widget.HTMLSnippet',
          { contenttype: 'js', contents: 'this.dataset.context = String(contextObj);' },
          { context: null },
        )}
      />,
    );
    expect(plain.querySelector('.mxrb-html-snippet')).toHaveAttribute('data-context', 'null');
    render(
      <MarketplaceWidget
        {...widgetProps('HTMLSnippet.widget.HTMLSnippet', {
          contenttype: 'js',
          contents: 'throw new Error("boom")',
        })}
      />,
    );
    expect(screen.getByRole('alert')).toHaveTextContent('boom');
  });

  it('calls the timer nanoflow at once and then every interval, and once when configured', () => {
    vi.useFakeTimers();
    const onAction = vi.fn();
    const { unmount } = render(
      <MarketplaceWidget
        {...widgetProps(
          'MicroflowTimer.widget.MicroflowTimer',
          {
            interval: 1000,
            once: false,
            startatonce: true,
            callEvent: 'callNanoflow',
            nanoflow: 'App.Tick',
          },
          { onAction },
        )}
      />,
    );
    expect(onAction).toHaveBeenCalledTimes(1);
    act(() => vi.advanceTimersByTime(2000));
    expect(onAction).toHaveBeenCalledTimes(3);
    expect(onAction.mock.calls[0][0]).toMatchObject({ kind: 'nanoflow', handler: 'App.Tick' });
    unmount();
    act(() => vi.advanceTimersByTime(5000));
    expect(onAction).toHaveBeenCalledTimes(3);

    const once = vi.fn();
    render(
      <MarketplaceWidget
        {...widgetProps(
          'MicroflowTimer.widget.MicroflowTimer',
          {
            interval: 500,
            once: true,
            startatonce: false,
            callEvent: 'callMicroflow',
            microflow: 'App.Once',
          },
          { onAction: once },
        )}
      />,
    );
    act(() => vi.advanceTimersByTime(3000));
    expect(once).toHaveBeenCalledTimes(1);
    expect(once.mock.calls[0][0]).toMatchObject({ kind: 'microflow', handler: 'App.Once' });
  });

  it('renders a CSV attribute as a table with quoted fields', () => {
    render(
      <MarketplaceWidget
        {...widgetProps('CSVasTable.widget.CSVasTable', { csv: 'App.Item.Data' })}
      />,
    );
    expect(screen.getAllByRole('columnheader').map((cell) => cell.textContent)).toEqual(['a', 'b']);
    expect(screen.getAllByRole('cell').map((cell) => cell.textContent)).toEqual(['1,5', '2']);
  });

  it('builds an iframe from its expressions and policies', () => {
    render(
      <MarketplaceWidget
        {...widgetProps('mendix.iframecomponent.IFrameComponent', {
          urlExpression: "'https://example.invalid/embed'",
          uiSizeWidth: "'850'",
          uiSizeHeight: "'500'",
          miscLoading: 'lazy',
          miscReferrerPolicy: 'notSet',
        })}
      />,
    );
    const frame = screen.getByTitle('Legacy');
    expect(frame).toHaveAttribute('src', 'https://example.invalid/embed');
    expect(frame).toHaveAttribute('width', '850');
    expect(frame).toHaveAttribute('loading', 'lazy');
    expect(frame).not.toHaveAttribute('referrerpolicy');
  });
});
