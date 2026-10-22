import type {
  ApplicationSchema,
  EntityRecord,
  NavigationProfile,
  OfflineEntityConfig,
} from '../types';
import { api } from './api';
import { offlineStore, type OfflineChange, type OfflineStore } from './offlineStore';

// Synchronization with the server as the Mendix offline client does it: the
// device uploads the objects it created, changed and deleted, then downloads
// the entities the profile synchronizes whole; entities with the sync mode
// None are cleared and NoneAndPreserveData are kept as they are.
export type SyncConfiguration = {
  profile: string;
  entities: OfflineEntityConfig[];
  synchronized_at: string;
};

export type SyncResult = SyncConfiguration & {
  ok: boolean;
  guid_map: Record<string, string>;
  conflicts: Array<{ type: string; id: string; reason: string }>;
  uploaded: EntityRecord[];
  entities: Array<OfflineEntityConfig & { records?: EntityRecord[] }>;
  objects?: Array<EntityRecord | null>;
};

// A native profile always works on the device; a web profile does when Studio
// Pro marks it offline or gives it entities to synchronize.
export const isOfflineProfile = (profile: NavigationProfile): boolean =>
  profile.kind === 'Native' ||
  profile.offline === true ||
  (profile.offline_entities?.length ?? 0) > 0;

export const offlineProfile = (
  schema: ApplicationSchema | null | undefined,
  requested: string | null = null,
): NavigationProfile | null => {
  const offline = (schema?.navigation?.profiles ?? []).filter(isOfflineProfile);
  if (requested) return offline.find((profile) => profile.name === requested) ?? null;
  return offline[0] ?? null;
};

const PROFILE_KEY = 'mxrb.profile';
let rememberedProfile: string | null = null;

const storedProfile = (): string | null => {
  try {
    return window.sessionStorage?.getItem(PROFILE_KEY) ?? null;
  } catch {
    return null;
  }
};

const rememberProfile = (name: string | null): void => {
  rememberedProfile = name;
  try {
    if (name) window.sessionStorage?.setItem(PROFILE_KEY, name);
    else window.sessionStorage?.removeItem(PROFILE_KEY);
  } catch {
    // Without session storage the profile lives as long as the page.
  }
};

// The profile the browser was opened with (?profile=Name). The query is read
// once and remembered for the session, since routing drops it afterwards.
export const requestedProfileName = (): string | null => {
  if (typeof window === 'undefined') return null;
  const requested = new URLSearchParams(window.location.search).get('profile');
  if (requested) rememberProfile(requested);
  return rememberedProfile ?? storedProfile();
};

export const forgetRequestedProfile = (): void => rememberProfile(null);

// The offline profile the browser was opened with, when the app has one.
export const requestedOfflineProfile = (
  schema: ApplicationSchema | null | undefined,
): NavigationProfile | null => {
  const requested = requestedProfileName();
  return requested ? offlineProfile(schema, requested) : null;
};

const profileName = async (profile: string | null, store: OfflineStore): Promise<string | null> =>
  profile ?? requestedProfileName() ?? (await store.meta()).profile ?? null;

const apply = async (
  store: OfflineStore,
  result: SyncResult,
  changes: OfflineChange[],
): Promise<void> => {
  await store.applyGuidMap(result.guid_map ?? {});
  await store.clearChanges(changes);
  for (const entity of result.entities ?? []) {
    if (entity.sync_mode === 'All') await store.replaceEntity(entity.entity, entity.records ?? []);
    else if (entity.sync_mode === 'None') await store.clearEntity(entity.entity);
  }
  for (const record of result.uploaded ?? []) {
    await store.backend.put('objects', `${record.type}:${record.id}`, record);
  }
  await store.setMeta({
    synchronized_at: result.synchronized_at,
    profile: result.profile,
    entities: result.entities?.map(({ entity, sync_mode, constraint }) => ({
      entity,
      sync_mode,
      constraint,
    })),
  });
};

export const synchronizeAll = async (
  profile: string | null = null,
  store: OfflineStore = offlineStore(),
): Promise<SyncResult> => {
  const changes = await store.pendingChanges();
  const result = await api<SyncResult>('/api/sync', {
    method: 'POST',
    body: JSON.stringify({ profile: await profileName(profile, store), changes }),
  });
  await apply(store, result, changes);
  return result;
};

// Synchronizing specific objects uploads the changes to them and refreshes them;
// an object the server deleted leaves the device.
export const synchronizeObjects = async (
  records: EntityRecord[],
  profile: string | null = null,
  store: OfflineStore = offlineStore(),
): Promise<SyncResult> => {
  const wanted = new Set(records.map((record) => `${record.type}:${record.id}`));
  const changes = (await store.pendingChanges()).filter((change) =>
    wanted.has(`${change.type}:${change.id}`),
  );
  const result = await api<SyncResult>('/api/sync', {
    method: 'POST',
    body: JSON.stringify({
      profile: await profileName(profile, store),
      changes,
      objects: records.map((record) => ({ type: record.type, id: record.id })),
    }),
  });
  await store.applyGuidMap(result.guid_map ?? {});
  await store.clearChanges(changes);
  const refreshed = result.objects ?? [];
  for (const [index, record] of records.entries()) {
    const id = result.guid_map?.[record.id] ?? record.id;
    const fresh = refreshed[index];
    if (fresh) await store.backend.put('objects', `${fresh.type}:${fresh.id}`, fresh);
    else await store.backend.delete('objects', `${record.type}:${id}`);
  }
  await store.setMeta({ synchronized_at: result.synchronized_at, profile: result.profile });
  return result;
};
