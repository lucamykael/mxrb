import type { JavaScriptAction } from './nanoflow';
import type { RuntimeValue } from '../types';

const required = (value: RuntimeValue | undefined, name: string): string => {
  if (!value) throw new Error(`Input parameter '${name}' is required`);
  return String(value);
};

const storage = (): Storage => {
  if (navigator.product === 'ReactNative') throw new Error('Native storage adapter is unavailable');
  return window.localStorage;
};

export const commonsStorageHandlers: Record<string, JavaScriptAction> = {
  GetStorageItemString: async ({ Key }) => {
    const key = required(Key, 'Key');
    const value = storage().getItem(key);
    if (value === null) throw new Error(`Storage item '${key}' does not exist`);
    return value;
  },
  SetStorageItemString: async ({ Key, Value }) => {
    const key = required(Key, 'Key');
    const value = required(Value, 'Value');
    storage().setItem(key, value);
  },
  RemoveStorageItem: async ({ Key }) => {
    const key = required(Key, 'Key');
    storage().removeItem(key);
    return true;
  },
  StorageItemExists: async ({ Key }) => {
    const key = required(Key, 'Key');
    return storage().getItem(key) !== null;
  },
  ClearLocalStorage: async () => {
    try {
      window.localStorage.clear();
      return true;
    } catch (error) {
      console.error(error);
      return false;
    }
  },
};
