import { afterEach, describe, expect, it, vi } from 'vitest';
import type { EntityRecord } from '../types';
import { api } from './api';
import { decimal } from './decimal';
import { NanoflowRuntime } from './nanoflow';

vi.mock('./api', () => ({ api: vi.fn() }));

const row = (id: string, Name: string, Amount: number | null, Rank: number): EntityRecord => ({
  id,
  type: 'Probe.Row',
  attributes: { Name, Amount: Amount === null ? null : decimal(Amount), Rank },
});
const rows = () => [row('1', 'North', 2.5, 3), row('2', 'south', 7, 1), row('3', 'Middle', null, 2)];
const runtime = () => new NanoflowRuntime({}, { name: 'Probe.Case', id: 'case', parameters: [] });
const names = (value: unknown) => (value as EntityRecord[]).map((record) => record.attributes.Name);

describe('nanoflow data actions', () => {
  afterEach(() => vi.mocked(api).mockReset());

  it('applies list operations with the client sort order', () => {
    const flow = runtime();
    flow.set('rows', rows());
    flow.set('some', [rows()[0]]);
    const operation = (operation: string, extra = {}) =>
      flow.listOperation({
        operation,
        list: 'rows',
        second: 'some',
        expression: '',
        attribute: '',
        sort: [],
        result_variable: 'out',
        ...extra,
      });
    operation('Head');
    expect((flow.variables.out as EntityRecord).attributes.Name).toBe('North');
    operation('Tail');
    expect(names(flow.variables.out)).toEqual(['south', 'Middle']);
    operation('Subtract');
    expect(names(flow.variables.out)).toEqual(['south', 'Middle']);
    operation('Intersect');
    expect(names(flow.variables.out)).toEqual(['North']);
    operation('Union');
    expect(names(flow.variables.out)).toHaveLength(3);
    flow.set('some', rows()[1]);
    operation('Contains');
    expect(flow.variables.out).toBe(true);
    operation('Sort', { sort: [{ attribute: 'Amount', direction: 'Descending' }] });
    expect(names(flow.variables.out)).toEqual(['south', 'North', 'Middle']);
    operation('Sort', { sort: [{ attribute: 'Name', direction: 'Ascending' }] });
    expect(names(flow.variables.out)).toEqual(['Middle', 'North', 'south']);
    operation('FindByExpression', { expression: '$currentObject/Rank = 1' });
    expect((flow.variables.out as EntityRecord).attributes.Name).toBe('south');
    operation('FilterByExpression', { expression: '$currentObject/Rank > 1' });
    expect(names(flow.variables.out)).toEqual(['North', 'Middle']);
    operation('Find', { attribute: 'Rank', expression: '2' });
    expect((flow.variables.out as EntityRecord).attributes.Name).toBe('Middle');
    operation('Filter', { attribute: 'Name', expression: "'NORTH'" });
    expect(names(flow.variables.out)).toEqual(['North']);
    expect(() => operation('Equals')).toThrow('Equals');
  });

  it('aggregates without empty values and on empty lists', () => {
    const flow = runtime();
    flow.set('rows', rows());
    flow.set('none', []);
    const aggregate = (fn: string, list = 'rows', attribute = 'Amount') =>
      flow.aggregate({ list, function: fn, attribute, result_variable: 'out' });
    aggregate('Count');
    expect(flow.variables.out).toBe(3);
    aggregate('Sum');
    expect(flow.variables.out).toEqual(decimal('9.5'));
    aggregate('Average');
    expect(flow.variables.out).toEqual(decimal('4.75'));
    aggregate('Maximum', 'rows', 'Rank');
    expect(flow.variables.out).toBe(3);
    aggregate('Minimum');
    expect(flow.variables.out).toEqual(decimal('2.5'));
    aggregate('Sum', 'none');
    expect(flow.variables.out).toBe(0);
    aggregate('Average', 'none');
    expect(flow.variables.out).toBeNull();
    expect(() => aggregate('Count', 'missing')).toThrow('missing');
  });

  it('iterates over snapshots and re-evaluates while conditions', () => {
    const flow = runtime();
    flow.set('rows', rows());
    expect([...flow.loop({ kind: 'iterable', list: 'rows' })]).toHaveLength(3);
    flow.set('n', 0);
    let count = 0;
    for (const _item of flow.loop({ kind: 'while', condition: '$n < 3' })) {
      count += 1;
      flow.set('n', count);
    }
    expect(count).toBe(3);
    expect(() => [...flow.loop({ kind: 'while', condition: 'true' })]).toThrow();
  });

  it('retrieves on the server with XPath variables, sorting and ranges', async () => {
    const flow = runtime();
    flow.set('item', { id: '9', type: 'Probe.Item', attributes: {} });
    flow.set('minimum', 2);
    vi.mocked(api).mockResolvedValue({ records: rows() });
    await flow.retrieve('found', {
      source: 'database',
      entity: 'Probe.Row',
      xpath: '[Rank >= $minimum][Probe.Row_Item = $item][$currentObject]',
      sort: [{ attribute: 'Name', direction: 'Ascending' }],
      limit: '2',
      offset: '1',
    });
    const url = new URL(String(vi.mocked(api).mock.calls[0][0]), 'http://localhost');
    expect(url.pathname).toBe('/api/entities/Probe.Row');
    expect(JSON.parse(url.searchParams.get('xpath_variables') || '{}')).toEqual({
      minimum: 2,
      item: { type: 'Probe.Item', id: '9' },
    });
    expect(url.searchParams.get('limit')).toBe('2');
    expect(url.searchParams.get('offset')).toBe('1');
    expect(names(flow.variables.found)).toHaveLength(3);
    await flow.retrieve('first', { source: 'database', entity: 'Probe.Row', single: true });
    expect((flow.variables.first as EntityRecord).id).toBe('1');
    vi.mocked(api).mockResolvedValue({ records: [] });
    await flow.retrieve('none', { source: 'database', entity: 'Probe.Row', single: true });
    expect(flow.variables.none).toBeNull();
  });

  it('retrieves over associations from either side', async () => {
    const flow = runtime();
    const spec = { source: 'association', association: 'Probe.Row_Item', from: 'Probe.Row', to: 'Probe.Item', kind: 'Reference' };
    flow.set('row', rows()[0]);
    flow.set('item', { id: '9', type: 'Probe.Item', attributes: {} });
    vi.mocked(api).mockResolvedValue({ records: [{ id: '9', type: 'Probe.Item', attributes: {} }] });
    await flow.retrieve('owner', { ...spec, start: 'row' });
    expect(vi.mocked(api).mock.calls[0][0]).toContain('/api/entities/Probe.Item?association=Probe.Row_Item');
    expect((flow.variables.owner as EntityRecord).id).toBe('9');
    vi.mocked(api).mockResolvedValue({ records: rows() });
    await flow.retrieve('children', { ...spec, start: 'item' });
    expect(names(flow.variables.children)).toHaveLength(3);
    await flow.retrieve('nothing', { ...spec, start: 'missing' });
    expect(flow.variables.nothing).toEqual([]);
  });

  it('commits new objects, deletes stored ones and rolls back changes', async () => {
    const flow = runtime();
    const created = flow.create('new', 'Probe.Row', { Name: "'zeta'" });
    vi.mocked(api).mockResolvedValueOnce({ records: [{ id: '10', type: 'Probe.Row', attributes: { Name: 'zeta' } }] });
    await flow.commit('new');
    expect(JSON.parse(String(vi.mocked(api).mock.calls[0][1]?.body)).records[0].new_record).toBe(true);
    expect(created.id).toBe('10');
    expect('transient' in created).toBe(false);
    await flow.commit('missing');
    vi.mocked(api).mockResolvedValueOnce({ ok: true });
    await flow.delete('new');
    expect(JSON.parse(String(vi.mocked(api).mock.calls[1][1]?.body))).toEqual({ records: [{ type: 'Probe.Row', id: '10' }] });
    flow.create('draft', 'Probe.Row', {});
    await flow.delete('draft');
    expect(vi.mocked(api)).toHaveBeenCalledTimes(2);
    flow.set('stored', row('1', 'changed', 1, 1));
    vi.mocked(api).mockResolvedValueOnce(row('1', 'North', 2.5, 3));
    await flow.rollback('stored');
    expect((flow.variables.stored as EntityRecord).attributes.Name).toBe('North');
  });

  it('logs message templates with their parameters', () => {
    const flow = runtime();
    const info = vi.spyOn(console, 'info').mockImplementation(() => undefined);
    flow.log('value={1} {2}', ["'a'", '1 + 1']);
    flow.log('');
    expect(info.mock.calls.map((call) => call[0])).toEqual(['[nanoflow] value=a 2', '[nanoflow] Probe.Case']);
    info.mockRestore();
  });
});
