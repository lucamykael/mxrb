import { act, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MarketplacePlotly } from './MarketplacePlotly';
import type { MarketplaceWidgetProps } from '../marketplace';
import type { PlotlyClick, PlotlyGraph } from '../plotly';

const engine = vi.hoisted(() => ({react: vi.fn(), purge: vi.fn(), on: vi.fn(), removeAllListeners: vi.fn()}));
vi.mock('plotly.js-dist-min', () => ({default: engine}));
const input = (properties: Record<string, unknown> = {}): MarketplaceWidgetProps => ({
  widget: {type: 'pluggable_widget', name: 'Custom', options: {properties: {dataStatic: '[{"type":"scatter","y":[1,2]}]', ...properties}}},
  context: null, onChange: vi.fn(), onClick: vi.fn(),
});
const click = async () => {
  const callback = engine.on.mock.calls.at(-1)?.[1] as (event: PlotlyClick) => void;
  await act(async () => callback({points: [{bbox: {x0: 10, x1: 20}}]}));
};
beforeEach(() => {
  vi.clearAllMocks();
  engine.react.mockImplementation(async (graph: PlotlyGraph) => Object.assign(graph, {on: engine.on, removeAllListeners: engine.removeAllListeners}));
});
describe('Plotly lifecycle and native event behavior', () => {
  it('passes trace, layout and configuration options, updates data and purges on unmount', async () => {
    const props = input({layoutStatic: '{"xaxis":{"type":"log"}}', configurationOptions: '{"displayModeBar":true}', heightUnit: 'pixels', height: 300});
    const view = render(<MarketplacePlotly {...props} />);
    await waitFor(() => expect(engine.on).toHaveBeenCalled());
    expect(engine.react).toHaveBeenLastCalledWith(screen.getByRole('img'), [{type: 'scatter', y: [1,2]}], expect.objectContaining({xaxis: expect.objectContaining({type: 'log'})}), {displayModeBar: true});
    expect(screen.getByRole('img').parentElement).toHaveStyle({height: '300px'});
    view.rerender(<MarketplacePlotly {...input({dataStatic: '[{"type":"bar","y":[8]}]'})} />);
    await waitFor(() => expect(engine.react).toHaveBeenLastCalledWith(expect.anything(), [{type: 'bar', y: [8]}], expect.anything(), expect.anything()));
    view.unmount();
    await waitFor(() => expect(engine.purge).toHaveBeenCalledTimes(1));
  });
  it('stores the first point bbox, dispatches the bound action and clears event data', async () => {
    const props = input({eventDataAttribute: {attribute: 'App.Owner.Event'}});
    render(<MarketplacePlotly {...props} />);
    await waitFor(() => expect(engine.on).toHaveBeenCalled());
    await click();
    expect(props.onChange).toHaveBeenNthCalledWith(1, 'App.Owner.Event', '{"x0":10,"x1":20}');
    expect(props.onChange).toHaveBeenNthCalledWith(2, 'App.Owner.Event', '');
    expect(props.onClick).toHaveBeenCalledTimes(1);
  });
  it('executes an unbound click action once while pending and reports rejection', async () => {
    let reject!: (error: Error) => void;
    const props = input();
    props.onClick = vi.fn(() => new Promise<void>((_, failure) => { reject = failure; }));
    render(<MarketplacePlotly {...props} />);
    await waitFor(() => expect(engine.on).toHaveBeenCalled());
    await click(); await click();
    expect(props.onClick).toHaveBeenCalledTimes(1);
    await act(async () => reject(new Error('Denied')));
    expect(await screen.findByRole('alert')).toHaveTextContent('Denied');
  });
  it('reports engine failures and invalid dimensions', async () => {
    engine.react.mockRejectedValueOnce(new Error('Plot failed'));
    const view = render(<MarketplacePlotly {...input()} />);
    expect(await screen.findByRole('alert')).toHaveTextContent('Plot failed');
    view.rerender(<MarketplacePlotly {...input({height: -1})} />);
    expect(screen.getByRole('alert')).toHaveTextContent('non-negative');
  });
});
