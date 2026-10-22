import { describe, expect, it } from 'vitest';
import type { EntityRecord } from '../types';
import {
  IndexedDbOfflineBackend,
  MemoryOfflineBackend,
  OfflineStore,
  offlineStore,
  useOfflineStore,
} from './offlineStore';

const record = (id: string, Name: string, type = 'Probe.Row'): EntityRecord => ({
  id,
  type,
  attributes: { Name },
});

describe('offline store', () => {
  it('keeps the records of each entity and replaces them whole', async () => {
    const store = new OfflineStore(new MemoryOfflineBackend());
    await store.replaceEntity('Probe.Row', [record('1', 'North'), record('2', 'South')]);
    await store.replaceEntity('Probe.Item', [record('9', 'Box', 'Probe.Item')]);
    expect((await store.records('Probe.Row')).map((row) => row.attributes.Name)).toEqual([
      'North',
      'South',
    ]);
    expect((await store.record('Probe.Item', '9'))?.attributes.Name).toBe('Box');
    expect(await store.record('Probe.Item', 'missing')).toBeNull();
    await store.replaceEntity('Probe.Row', [record('3', 'East')]);
    expect((await store.records('Probe.Row')).map((row) => row.id)).toEqual(['3']);
    await store.clearEntity('Probe.Row');
    expect(await store.records('Probe.Row')).toEqual([]);
    expect(await store.records('Probe.Item')).toHaveLength(1);
  });

  it('queues saves and deletions as one change per object', async () => {
    const store = new OfflineStore(new MemoryOfflineBackend());
    const created = await store.save({ ...record('tmp', 'New'), transient: true });
    expect(created.transient).toBeUndefined();
    await store.save({ ...record('tmp', 'Newer'), new_record: true });
    await store.replaceEntity('Probe.Item', [record('9', 'Box', 'Probe.Item')]);
    await store.save(record('9', 'Crate', 'Probe.Item'));
    expect(await store.pendingChanges()).toEqual([
      { type: 'Probe.Row', id: 'tmp', attributes: { Name: 'Newer' }, new_record: true },
      { type: 'Probe.Item', id: '9', attributes: { Name: 'Crate' }, new_record: false },
    ]);
    await store.remove(record('9', 'Crate', 'Probe.Item'));
    await store.remove(record('tmp', 'Newer'));
    expect(await store.pendingChanges()).toEqual([{ type: 'Probe.Item', id: '9', deleted: true }]);
    expect(await store.records('Probe.Row')).toEqual([]);
    await store.clearChanges(await store.pendingChanges());
    expect(await store.pendingChanges()).toEqual([]);
  });

  it('renames objects the server identified and remembers the synchronization', async () => {
    const store = new OfflineStore(new MemoryOfflineBackend());
    await store.save({ ...record('tmp', 'New'), transient: true });
    await store.applyGuidMap({ tmp: '42', unknown: '43' });
    expect(await store.record('Probe.Row', 'tmp')).toBeNull();
    expect(await store.record('Probe.Row', '42')).toEqual(record('42', 'New'));
    expect(await store.meta()).toEqual({});
    await store.setMeta({ profile: 'NativePhone' });
    await store.setMeta({ synchronized_at: 'now' });
    expect(await store.meta()).toEqual({ profile: 'NativePhone', synchronized_at: 'now' });
    await store.reset();
    expect(await store.meta()).toEqual({});
    expect(await store.pendingChanges()).toEqual([]);
  });

  it('serves one application store, in memory without IndexedDB', () => {
    useOfflineStore(null);
    const store = offlineStore();
    expect(store.backend).toBeInstanceOf(MemoryOfflineBackend);
    expect(offlineStore()).toBe(store);
    const replacement = new OfflineStore(new MemoryOfflineBackend());
    useOfflineStore(replacement);
    expect(offlineStore()).toBe(replacement);
    useOfflineStore(null);
  });

  it('drives IndexedDB through requests and upgrades', async () => {
    const data: Record<string, Map<string, unknown>> = {};
    const succeed = <T>(result: T) => {
      const request = { result, error: null } as unknown as IDBRequest<T> & {
        onsuccess: () => void;
      };
      queueMicrotask(() => request.onsuccess());
      return request;
    };
    const fail = () => {
      const request = { error: new Error('boom') } as unknown as IDBRequest & {
        onerror: () => void;
      };
      queueMicrotask(() => request.onerror());
      return request;
    };
    const objectStore = (name: string, failing = false) =>
      ({
        get: (key: string) => (failing ? fail() : succeed(data[name].get(key))),
        put: (value: unknown, key: string) => succeed(void data[name].set(key, value)),
        delete: (key: string) => succeed(void data[name].delete(key)),
        getAll: () => succeed([...data[name].values()]),
        clear: () => succeed(void data[name].clear()),
      }) as unknown as IDBObjectStore;
    let failing = false;
    const database = {
      objectStoreNames: { contains: (name: string) => name in data },
      createObjectStore: (name: string) => {
        data[name] = new Map();
      },
      transaction: (name: string) => ({ objectStore: () => objectStore(name, failing) }),
    } as unknown as IDBDatabase;
    const factory = {
      open: () => {
        const opening = { result: database } as unknown as IDBOpenDBRequest & {
          onupgradeneeded: () => void;
          onsuccess: () => void;
        };
        queueMicrotask(() => {
          opening.onupgradeneeded();
          opening.onsuccess();
        });
        return opening;
      },
    } as unknown as IDBFactory;
    const backend = new IndexedDbOfflineBackend('test', factory);
    await backend.put('objects', 'a', { id: 'a' });
    expect(await backend.get('objects', 'a')).toEqual({ id: 'a' });
    expect(await backend.all('objects')).toEqual([{ id: 'a' }]);
    await backend.delete('objects', 'a');
    await backend.put('meta', 'sync', { profile: 'x' });
    await backend.clear('meta');
    expect(await backend.all('meta')).toEqual([]);
    expect(Object.keys(data).sort()).toEqual(['changes', 'meta', 'objects']);
    failing = true;
    await expect(backend.get('objects', 'a')).rejects.toThrow('boom');
    const broken = new IndexedDbOfflineBackend('broken', {
      open: () => {
        const opening = { error: new Error('denied') } as unknown as IDBOpenDBRequest & {
          onerror: () => void;
        };
        queueMicrotask(() => opening.onerror());
        return opening;
      },
    } as unknown as IDBFactory);
    await expect(broken.all('objects')).rejects.toThrow('denied');
  });
});
