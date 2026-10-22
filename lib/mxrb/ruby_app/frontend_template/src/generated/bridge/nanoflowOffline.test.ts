import { afterEach, describe, expect, it, vi } from 'vitest';
import type { EntityRecord } from '../types';
import { api } from './api';
import { NanoflowRuntime } from './nanoflow';
import { MemoryOfflineBackend, OfflineStore, useOfflineStore } from './offlineStore';

vi.mock('./api', () => ({ api: vi.fn() }));

const record = (id: string, Name: string, type = 'Probe.Row', extra = {}): EntityRecord => ({
  id,
  type,
  attributes: { Name, ...extra },
});
const metadata = { name: 'Probe.Offline', id: 'offline', parameters: [] };

describe('nanoflows of an offline profile', () => {
  afterEach(() => {
    vi.mocked(api).mockReset();
    useOfflineStore(null);
  });

  it('reads, commits, deletes and rolls back against the device store', async () => {
    const store = new OfflineStore(new MemoryOfflineBackend());
    useOfflineStore(store);
    await store.replaceEntity('Probe.Row', [
      record('2', 'South', 'Probe.Row', { Row_Item: '9' }),
      record('1', 'North', 'Probe.Row', { Row_Item: '9' }),
      record('3', 'West', 'Probe.Row', { Row_Item: null }),
    ]);
    await store.replaceEntity('Probe.Item', [record('9', 'Box', 'Probe.Item')]);
    const flow = new NanoflowRuntime({}, metadata, undefined, { offline: true });
    await flow.retrieve('rows', {
      source: 'database',
      entity: 'Probe.Row',
      sort: [{ attribute: 'Name', direction: 'Ascending' }],
      offset: '1',
      limit: '1',
    });
    expect((flow.variables.rows as EntityRecord[]).map((row) => row.attributes.Name)).toEqual([
      'South',
    ]);
    await flow.retrieve('first', { source: 'database', entity: 'Probe.Row', single: true });
    expect((flow.variables.first as EntityRecord).id).toBe('2');
    await expect(
      flow.retrieve('x', { source: 'database', entity: 'Probe.Row', xpath: '[Name = 1]' }),
    ).rejects.toThrow(/XPath/);
    flow.set('item', record('9', 'Box', 'Probe.Item'));
    await flow.retrieve('owned', {
      source: 'association',
      association: 'Probe.Row_Item',
      start: 'item',
      from: 'Probe.Row',
      to: 'Probe.Item',
      kind: 'Reference',
    });
    expect((flow.variables.owned as EntityRecord[]).map((row) => row.id).sort()).toEqual([
      '1',
      '2',
    ]);
    await flow.retrieve('parent', {
      source: 'association',
      association: 'Probe.Row_Item',
      start: 'first',
      from: 'Probe.Row',
      to: 'Probe.Item',
      kind: 'Reference',
    });
    expect((flow.variables.parent as EntityRecord).id).toBe('9');
    flow.set('nothing', null);
    await flow.retrieve('none', {
      source: 'association',
      association: 'Probe.Row_Item',
      start: 'nothing',
      kind: 'Reference',
    });
    expect(flow.variables.none).toBeNull();
    await flow.retrieve('empty', {
      source: 'association',
      association: 'Probe.Row_Item',
      start: 'nothing',
      kind: 'ReferenceSet',
    });
    expect(flow.variables.empty).toEqual([]);

    const created = flow.create('fresh', 'Probe.Row', { Name: "'East'" });
    await flow.commit('fresh');
    expect(created.new_record).toBe(true);
    expect(created.transient).toBeUndefined();
    await flow.commit('nothing');
    expect((await store.pendingChanges()).map((change) => change.id)).toEqual([created.id]);
    flow.change('first', { Name: "'Changed'" });
    await flow.rollback('first');
    expect((flow.variables.first as EntityRecord).attributes.Name).toBe('South');
    flow.set('loose', record('77', 'Loose'));
    await flow.rollback('loose');
    expect((flow.variables.loose as EntityRecord).attributes.Name).toBe('Loose');
    await flow.delete('first');
    expect(await store.record('Probe.Row', '2')).toBeNull();
    expect(api).not.toHaveBeenCalled();
  });

  it('synchronizes everything or the objects of the named variables', async () => {
    const store = new OfflineStore(new MemoryOfflineBackend());
    useOfflineStore(store);
    const flow = new NanoflowRuntime({}, metadata, undefined, { offline: true });
    vi.mocked(api).mockResolvedValueOnce({
      ok: true,
      profile: 'NativePhone',
      synchronized_at: 'T',
      entities: [],
    });
    await flow.synchronize('All');
    expect(vi.mocked(api).mock.calls[0][0]).toBe('/api/sync');
    const created = flow.create('fresh', 'Probe.Row', { Name: "'East'" });
    await flow.commit('fresh');
    flow.set('rows', [record('1', 'North'), 'not a record']);
    vi.mocked(api).mockResolvedValueOnce({
      ok: true,
      profile: 'NativePhone',
      synchronized_at: 'T',
      guid_map: { [created.id]: '42' },
      objects: [record('42', 'East'), record('1', 'North')],
    });
    await flow.synchronize('SpecificObjects', ['fresh', 'rows', 'missing']);
    expect(created.id).toBe('42');
    expect(created.new_record).toBeUndefined();
    expect(await store.record('Probe.Row', '42')).toEqual(record('42', 'East'));
    expect(await store.pendingChanges()).toEqual([]);
  });
});
