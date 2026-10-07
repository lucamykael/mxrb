import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { nanoflowCommonsActions } from './nanoflowCommons';

const names = ['GetStorageItemString', 'SetStorageItemString', 'RemoveStorageItem', 'StorageItemExists', 'ClearLocalStorage'];
const actions = nanoflowCommonsActions(names);
let values: Map<string, string>;
beforeEach(() => {
  values = new Map();
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, String(value)),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
  });
});
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });
describe('verified Commons browser storage', () => {
  it('persists Unicode, distinguishes empty stored strings from missing keys and removes only the requested key', async () => {
    const read = actions['NanoflowCommons.GetStorageItemString'];
    const exists = actions['NanoflowCommons.StorageItemExists'];
    expect(await exists({Key: 'item'})).toBe(false);
    await actions['NanoflowCommons.SetStorageItemString']({Key: 'item', Value: 'Olá 世界 🌍'});
    expect(await read({Key: 'item'})).toBe('Olá 世界 🌍');
    values.set('empty', '');
    expect(await exists({Key: 'empty'})).toBe(true);
    expect(await read({Key: 'empty'})).toBe('');
    expect(await actions['NanoflowCommons.RemoveStorageItem']({Key: 'item'})).toBe(true);
    expect(values.has('empty')).toBe(true);
    await expect(read({Key: 'item'})).rejects.toThrow("Storage item 'item' does not exist");
    expect(await actions['NanoflowCommons.RemoveStorageItem']({Key: 'item'})).toBe(true);
    expect(await actions['NanoflowCommons.ClearLocalStorage']({})).toBe(true);
    expect(values.size).toBe(0);
  });
  it.each(names.slice(0, 4))('validates Key before accessing storage in %s', async name => {
    vi.stubGlobal('localStorage', undefined);
    await expect(actions[`NanoflowCommons.${name}`]({Key: ''})).rejects.toThrow("Input parameter 'Key' is required");
  });
  it('rejects empty writes and propagates storage denial', async () => {
    await expect(actions['NanoflowCommons.SetStorageItemString']({Key: 'test', Value: ''})).rejects.toThrow("Input parameter 'Value' is required");
    const failure = new Error('Storage denied');
    vi.stubGlobal('localStorage', {getItem: () => { throw failure; }});
    await expect(actions['NanoflowCommons.GetStorageItemString']({Key: 'test'})).rejects.toBe(failure);
  });
  it('returns false when clearing fails and refuses an unavailable native storage implementation', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.stubGlobal('localStorage', {clear: () => {throw new Error('Denied');}});
    expect(await actions['NanoflowCommons.ClearLocalStorage']({})).toBe(false);
    expect(log).toHaveBeenCalledOnce();
    vi.stubGlobal('navigator', {product: 'ReactNative'});
    await expect(actions['NanoflowCommons.GetStorageItemString']({Key: 'item'})).rejects.toThrow('Native storage adapter is unavailable');
  });
});
