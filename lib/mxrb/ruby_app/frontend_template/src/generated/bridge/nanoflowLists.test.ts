import { describe, expect, it } from 'vitest';
import { NanoflowRuntime } from './nanoflow';

const runtime = () => new NanoflowRuntime({}, {name: 'App.Lists', id: 'lists', parameters: []});
describe('nanoflow list mutation', () => {
  it('preserves list aliases, deduplicates record identity, removes and clears objects', () => {
    const flow = runtime();
    const first = {id: '1', type: 'App.Item', attributes: {Name: 'First'}};
    const second = {id: '2', type: 'App.Item', attributes: {Name: 'Second'}};
    flow.set('items', []);
    flow.set('alias', flow.value('$items'));
    flow.set('first', first); flow.set('copy', {...first}); flow.set('second', second);
    flow.changeList('items', 'Add', '$first');
    flow.changeList('items', 'Add', '$copy');
    flow.changeList('items', 'Add', '$second');
    expect(flow.value('$alias')).toEqual([first, second]);
    flow.changeList('items', 'Remove', '$copy');
    flow.changeList('items', 'Remove', '$copy');
    expect(flow.value('$alias')).toEqual([second]);
    flow.changeList('items', 'Clear', '');
    expect(flow.value('$alias')).toEqual([]);
  });
  it('rejects missing lists, unsupported operations and non-object values', () => {
    const flow = runtime();
    expect(() => flow.changeList('missing', 'Add', 'empty')).toThrow('list $missing');
    flow.set('items', []);
    expect(() => flow.changeList('items', 'Unsupported', 'empty')).toThrow('Unsupported list change');
    expect(() => flow.changeList('items', 'Add', 'empty')).toThrow('require an object');
  });
});
