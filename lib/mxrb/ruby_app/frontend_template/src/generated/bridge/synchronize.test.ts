import { afterEach, describe, expect, it, vi } from 'vitest';
import type { ApplicationSchema, EntityRecord } from '../types';
import { api } from './api';
import { MemoryOfflineBackend, OfflineStore } from './offlineStore';
import {
  forgetRequestedProfile,
  isOfflineProfile,
  offlineProfile,
  requestedOfflineProfile,
  requestedProfileName,
  synchronizeAll,
  synchronizeObjects,
} from './synchronize';

vi.mock('./api', () => ({ api: vi.fn() }));

const record = (id: string, Name: string, type = 'Probe.Row'): EntityRecord => ({
  id,
  type,
  attributes: { Name },
});
const schema = {
  project: { name: 'P', mendix_version: '10.24.0' },
  modules: [],
  navigation: {
    profiles: [
      { name: 'Responsive', kind: 'Responsive' },
      {
        name: 'NativePhone',
        kind: 'Native',
        offline: true,
        offline_entities: [{ entity: 'Probe.Row', sync_mode: 'All' }],
      },
      {
        name: 'Field',
        kind: 'Phone',
        offline_entities: [{ entity: 'Probe.Item', sync_mode: 'None' }],
      },
      { name: 'Bare', kind: 'Native' },
      { name: 'Tablet', kind: 'Tablet', offline: true },
    ],
  },
} as unknown as ApplicationSchema;

describe('offline synchronization', () => {
  afterEach(() => {
    vi.mocked(api).mockReset();
    forgetRequestedProfile();
  });

  it('finds the offline profiles of the schema and the one the browser asks for', () => {
    expect(offlineProfile(schema)?.name).toBe('NativePhone');
    expect(offlineProfile(schema, 'Field')?.name).toBe('Field');
    expect(offlineProfile(schema, 'Bare')?.kind).toBe('Native');
    expect(offlineProfile(schema, 'Tablet')?.offline).toBe(true);
    expect(offlineProfile(schema, 'Responsive')).toBeNull();
    expect(isOfflineProfile({ kind: 'Responsive' })).toBe(false);
    expect(offlineProfile(null)).toBeNull();
    expect(requestedOfflineProfile(schema)).toBeNull();
    expect(requestedProfileName()).toBeNull();
    window.history.replaceState({}, '', '/?profile=NativePhone');
    expect(requestedOfflineProfile(schema)?.name).toBe('NativePhone');
    // Routing drops the query; the session remembers the profile it started with.
    window.history.replaceState({}, '', '/');
    expect(requestedProfileName()).toBe('NativePhone');
    expect(window.sessionStorage.getItem('mxrb.profile')).toBe('NativePhone');
    forgetRequestedProfile();
    expect(requestedProfileName()).toBeNull();
    expect(window.sessionStorage.getItem('mxrb.profile')).toBeNull();
    window.sessionStorage.setItem('mxrb.profile', 'Field');
    expect(requestedOfflineProfile(schema)?.name).toBe('Field');
    forgetRequestedProfile();
  });

  it('uploads pending changes and replaces, clears or keeps each entity by its mode', async () => {
    const store = new OfflineStore(new MemoryOfflineBackend());
    await store.replaceEntity('Probe.Item', [record('9', 'Box', 'Probe.Item')]);
    await store.replaceEntity('Probe.Old', [record('5', 'Gone', 'Probe.Old')]);
    await store.save({ ...record('tmp', 'New'), transient: true });
    await store.save(record('9', 'Crate', 'Probe.Item'));
    vi.mocked(api).mockResolvedValueOnce({
      ok: true,
      profile: 'NativePhone',
      synchronized_at: 'T1',
      guid_map: { tmp: '42' },
      conflicts: [],
      uploaded: [record('42', 'New'), record('9', 'Crate', 'Probe.Item')],
      entities: [
        {
          entity: 'Probe.Row',
          sync_mode: 'All',
          constraint: '',
          records: [record('42', 'New'), record('1', 'North')],
        },
        { entity: 'Probe.Item', sync_mode: 'NoneAndPreserveData', constraint: '' },
        { entity: 'Probe.Old', sync_mode: 'None', constraint: '' },
      ],
    });
    const result = await synchronizeAll('NativePhone', store);
    expect(result.guid_map).toEqual({ tmp: '42' });
    const [path, options] = vi.mocked(api).mock.calls[0];
    expect(path).toBe('/api/sync');
    expect(JSON.parse(String(options?.body))).toEqual({
      profile: 'NativePhone',
      changes: [
        { type: 'Probe.Row', id: 'tmp', attributes: { Name: 'New' }, new_record: true },
        { type: 'Probe.Item', id: '9', attributes: { Name: 'Crate' }, new_record: false },
      ],
    });
    expect((await store.records('Probe.Row')).map((row) => row.id).sort()).toEqual(['1', '42']);
    expect((await store.record('Probe.Item', '9'))?.attributes.Name).toBe('Crate');
    expect(await store.records('Probe.Old')).toEqual([]);
    expect(await store.pendingChanges()).toEqual([]);
    expect(await store.meta()).toEqual({
      synchronized_at: 'T1',
      profile: 'NativePhone',
      entities: [
        { entity: 'Probe.Row', sync_mode: 'All', constraint: '' },
        { entity: 'Probe.Item', sync_mode: 'NoneAndPreserveData', constraint: '' },
        { entity: 'Probe.Old', sync_mode: 'None', constraint: '' },
      ],
    });
    vi.mocked(api).mockResolvedValueOnce({
      ok: true,
      profile: 'NativePhone',
      synchronized_at: 'T2',
    });
    await synchronizeAll(null, store);
    expect(JSON.parse(String(vi.mocked(api).mock.calls[1][1]?.body))).toEqual({
      profile: 'NativePhone',
      changes: [],
    });
  });

  it('synchronizes specific objects, renaming created ones and dropping deleted ones', async () => {
    const store = new OfflineStore(new MemoryOfflineBackend());
    await store.save({ ...record('tmp', 'New'), transient: true });
    await store.replaceEntity('Probe.Item', [record('9', 'Box', 'Probe.Item')]);
    await store.save(record('9', 'Crate', 'Probe.Item'));
    await store.save(record('7', 'Other', 'Probe.Item'));
    vi.mocked(api).mockResolvedValueOnce({
      ok: true,
      profile: 'NativePhone',
      synchronized_at: 'T3',
      guid_map: { tmp: '42' },
      conflicts: [],
      uploaded: [],
      entities: [],
      objects: [record('42', 'New'), null],
    });
    await synchronizeObjects(
      [record('tmp', 'New'), record('9', 'Crate', 'Probe.Item')],
      'NativePhone',
      store,
    );
    const body = JSON.parse(String(vi.mocked(api).mock.calls[0][1]?.body));
    expect(body.objects).toEqual([
      { type: 'Probe.Row', id: 'tmp' },
      { type: 'Probe.Item', id: '9' },
    ]);
    expect(body.changes.map((change: { id: string }) => change.id)).toEqual(['tmp', '9']);
    expect(await store.record('Probe.Row', '42')).toEqual(record('42', 'New'));
    expect(await store.record('Probe.Item', '9')).toBeNull();
    expect((await store.pendingChanges()).map((change) => change.id)).toEqual(['7']);
    expect((await store.meta()).synchronized_at).toBe('T3');
  });
});
