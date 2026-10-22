import type { EntityRecord, OfflineEntityConfig } from '../types';

// The device copy of the entities an offline profile synchronizes: the records
// by entity, the changes made since the last synchronization, and what the
// last synchronization reported. IndexedDB keeps it across sessions; a memory
// backend serves tests and browsers without IndexedDB.
export type OfflineChange = {
  type: string;
  id: string;
  attributes?: Record<string, unknown>;
  new_record?: boolean;
  deleted?: boolean;
};

export type OfflineMeta = {
  synchronized_at?: string;
  profile?: string;
  entities?: OfflineEntityConfig[];
};

type StoreName = 'objects' | 'changes' | 'meta';

export interface OfflineBackend {
  get(store: StoreName, key: string): Promise<unknown>;
  put(store: StoreName, key: string, value: unknown): Promise<void>;
  delete(store: StoreName, key: string): Promise<void>;
  all(store: StoreName): Promise<unknown[]>;
  clear(store: StoreName): Promise<void>;
}

export class MemoryOfflineBackend implements OfflineBackend {
  readonly stores: Record<StoreName, Map<string, unknown>> = {
    objects: new Map(),
    changes: new Map(),
    meta: new Map(),
  };

  async get(store: StoreName, key: string): Promise<unknown> {
    return this.stores[store].get(key);
  }

  async put(store: StoreName, key: string, value: unknown): Promise<void> {
    this.stores[store].set(key, structuredClone(value));
  }

  async delete(store: StoreName, key: string): Promise<void> {
    this.stores[store].delete(key);
  }

  async all(store: StoreName): Promise<unknown[]> {
    return [...this.stores[store].values()].map((value) => structuredClone(value));
  }

  async clear(store: StoreName): Promise<void> {
    this.stores[store].clear();
  }
}

const STORES: StoreName[] = ['objects', 'changes', 'meta'];

const request = <T>(value: IDBRequest<T>): Promise<T> =>
  new Promise((resolve, reject) => {
    value.onsuccess = () => resolve(value.result);
    value.onerror = () => reject(value.error ?? new Error('IndexedDB request failed'));
  });

export class IndexedDbOfflineBackend implements OfflineBackend {
  #database: Promise<IDBDatabase> | null = null;

  constructor(
    readonly name: string,
    readonly factory: IDBFactory = indexedDB,
  ) {}

  #open(): Promise<IDBDatabase> {
    this.#database ??= new Promise((resolve, reject) => {
      const opening = this.factory.open(this.name, 1);
      opening.onupgradeneeded = () => {
        const database = opening.result;
        STORES.forEach((store) => {
          if (!database.objectStoreNames.contains(store)) database.createObjectStore(store);
        });
      };
      opening.onsuccess = () => resolve(opening.result);
      opening.onerror = () => reject(opening.error ?? new Error('IndexedDB cannot open'));
    });
    return this.#database;
  }

  async #store(store: StoreName, mode: IDBTransactionMode): Promise<IDBObjectStore> {
    const database = await this.#open();
    return database.transaction(store, mode).objectStore(store);
  }

  async get(store: StoreName, key: string): Promise<unknown> {
    return request((await this.#store(store, 'readonly')).get(key));
  }

  async put(store: StoreName, key: string, value: unknown): Promise<void> {
    await request((await this.#store(store, 'readwrite')).put(value, key));
  }

  async delete(store: StoreName, key: string): Promise<void> {
    await request((await this.#store(store, 'readwrite')).delete(key));
  }

  async all(store: StoreName): Promise<unknown[]> {
    return request((await this.#store(store, 'readonly')).getAll());
  }

  async clear(store: StoreName): Promise<void> {
    await request((await this.#store(store, 'readwrite')).clear());
  }
}

const objectKey = (type: string, id: string): string => `${type}:${id}`;
const isRecord = (value: unknown): value is EntityRecord =>
  Boolean(value && typeof value === 'object' && 'id' in value && 'type' in value);

export class OfflineStore {
  constructor(readonly backend: OfflineBackend) {}

  async records(type: string): Promise<EntityRecord[]> {
    const values = await this.backend.all('objects');
    return values.filter(isRecord).filter((record) => record.type === type);
  }

  async record(type: string, id: string): Promise<EntityRecord | null> {
    const value = await this.backend.get('objects', objectKey(type, id));
    return isRecord(value) ? value : null;
  }

  // The device holds what the server sent for an entity synchronized whole.
  async replaceEntity(type: string, records: EntityRecord[]): Promise<void> {
    await this.clearEntity(type);
    for (const record of records)
      await this.backend.put('objects', objectKey(type, record.id), record);
  }

  async clearEntity(type: string): Promise<void> {
    for (const record of await this.records(type)) {
      await this.backend.delete('objects', objectKey(type, record.id));
    }
  }

  // A record saved offline is kept locally and queued for the next upload; a
  // record created and changed offline stays one creation.
  async save(record: EntityRecord): Promise<EntityRecord> {
    const key = objectKey(record.type, record.id);
    const stored: EntityRecord = { ...record, attributes: { ...record.attributes } };
    delete stored.transient;
    await this.backend.put('objects', key, stored);
    const previous = (await this.backend.get('changes', key)) as OfflineChange | undefined;
    const change: OfflineChange = {
      type: record.type,
      id: record.id,
      attributes: stored.attributes as Record<string, unknown>,
      new_record: Boolean(record.new_record || record.transient || previous?.new_record),
    };
    await this.backend.put('changes', key, change);
    return stored;
  }

  // Deleting a record created offline cancels its creation outright.
  async remove(record: EntityRecord): Promise<void> {
    const key = objectKey(record.type, record.id);
    await this.backend.delete('objects', key);
    const previous = (await this.backend.get('changes', key)) as OfflineChange | undefined;
    if (previous?.new_record) {
      await this.backend.delete('changes', key);
      return;
    }
    await this.backend.put('changes', key, { type: record.type, id: record.id, deleted: true });
  }

  async pendingChanges(): Promise<OfflineChange[]> {
    return (await this.backend.all('changes')) as OfflineChange[];
  }

  async clearChanges(changes: OfflineChange[]): Promise<void> {
    for (const change of changes)
      await this.backend.delete('changes', objectKey(change.type, change.id));
  }

  // Objects created offline take the identity the server gave them.
  async applyGuidMap(map: Record<string, string>): Promise<void> {
    for (const [local, server] of Object.entries(map)) {
      const values = await this.backend.all('objects');
      for (const value of values.filter(isRecord)) {
        if (value.id !== local) continue;
        await this.backend.delete('objects', objectKey(value.type, local));
        const renamed: EntityRecord = { ...value, id: server };
        delete renamed.new_record;
        await this.backend.put('objects', objectKey(value.type, server), renamed);
      }
    }
  }

  async meta(): Promise<OfflineMeta> {
    return ((await this.backend.get('meta', 'sync')) as OfflineMeta | undefined) ?? {};
  }

  async setMeta(value: OfflineMeta): Promise<void> {
    await this.backend.put('meta', 'sync', { ...(await this.meta()), ...value });
  }

  async reset(): Promise<void> {
    for (const store of STORES) await this.backend.clear(store);
  }
}

let current: OfflineStore | null = null;

// The store of the running application; IndexedDB when the browser has it.
export const offlineStore = (name = 'mxrb-offline'): OfflineStore => {
  current ??= new OfflineStore(
    typeof indexedDB === 'undefined'
      ? new MemoryOfflineBackend()
      : new IndexedDbOfflineBackend(name),
  );
  return current;
};

export const useOfflineStore = (store: OfflineStore | null): void => {
  current = store;
};
