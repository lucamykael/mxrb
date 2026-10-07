import { Base64 } from 'js-base64';
import type { JavaScriptAction } from './nanoflow';
import { isEntityRecord } from './value';

const handlers: Record<string, JavaScriptAction> = {
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
