import { Base64 } from 'js-base64';
import type { JavaScriptAction } from './nanoflow';
import { isEntityRecord } from './value';
import { commonsStorageHandlers } from './commonsStorage';

// NanoflowCommons.SignIn returns 401 without a request when a field is empty and
// otherwise the sign-in status (0 offline); success reloads the app like mx.login.
const signIn: JavaScriptAction = async ({ username, password }) => {
  if (!username || !password) return 401;
  try {
    const response = await fetch('/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ username, password }),
    });
    if (response.ok) setTimeout(() => window.location.reload(), 0);
    return response.status;
  } catch {
    return 0;
  }
};

const handlers: Record<string, JavaScriptAction> = {
  ...commonsStorageHandlers,
  SignIn: signIn,
  Base64Encode: async ({ stringToEncode }) => Base64.encode(stringToEncode as string),
  Base64Decode: async ({ base64 }) => Base64.decode(base64 as string),
  GetGuid: async ({ EntityObject }) => {
    if (!EntityObject) throw new Error("Input parameter 'Entity object' is required.");
    if (!isEntityRecord(EntityObject)) throw new TypeError('Entity object must be an application record');
    return EntityObject.id;
  },
  GetPlatform: async () => {
    if ((window as Window & { cordova?: unknown }).cordova) return 'Hybrid_mobile';
    if (navigator.product === 'ReactNative') return 'Native_mobile';
    return 'Web';
  },
  FindObjectWithGUID: async ({ list, objectGUID }) => {
    if (!Array.isArray(list)) throw new TypeError('Object list must be an array');
    return list.find(record => {
      if (!isEntityRecord(record)) throw new TypeError('Object list must contain application records');
      return record.id === objectGUID;
    });
  },
};

export const nanoflowCommonsActions = (names: string[]): Record<string, JavaScriptAction> =>
  Object.fromEntries(names.map(name => {
    const action = handlers[name];
    if (!action) throw new Error(`Unknown Nanoflow Commons action: ${name}`);
    return [`NanoflowCommons.${name}`, action];
  }));
