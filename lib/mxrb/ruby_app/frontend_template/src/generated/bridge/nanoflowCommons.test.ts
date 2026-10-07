import { afterEach, describe, expect, it, vi } from 'vitest';
import { nanoflowCommonsActions } from './nanoflowCommons';

const actions = nanoflowCommonsActions(['Base64Encode', 'Base64Decode', 'GetGuid', 'GetPlatform', 'FindObjectWithGUID']);
afterEach(() => vi.unstubAllGlobals());
describe('verified Nanoflow Commons actions', () => {
  it.each(['', 'hello', 'Olá 世界 🌍', '\u0000\u00ff'])('roundtrips Unicode text %j', async text => {
    const encoded = await actions['NanoflowCommons.Base64Encode']({stringToEncode: text});
    expect(await actions['NanoflowCommons.Base64Decode']({base64: encoded})).toBe(text);
  });
  it('uses the model parameter case and preserves large object identifiers', async () => {
    const entity = {id: '9007199254740993123', type: 'App.Item', attributes: {Name: 'Example'}};
    expect(await actions['NanoflowCommons.GetGuid']({EntityObject: entity})).toBe(entity.id);
    expect(await actions['NanoflowCommons.FindObjectWithGUID']({list: [entity], objectGUID: entity.id})).toBe(entity);
    expect(await actions['NanoflowCommons.FindObjectWithGUID']({list: [entity], objectGUID: 'missing'})).toBeUndefined();
    await expect(actions['NanoflowCommons.GetGuid']({EntityObject: null})).rejects.toThrow("Input parameter 'Entity object' is required.");
  });
  it('rejects invalid object/list inputs', async () => {
    await expect(actions['NanoflowCommons.GetGuid']({EntityObject: 'bad'})).rejects.toThrow(TypeError);
    await expect(actions['NanoflowCommons.FindObjectWithGUID']({list: null})).rejects.toThrow(TypeError);
    await expect(actions['NanoflowCommons.FindObjectWithGUID']({list: [null]})).rejects.toThrow(TypeError);
    expect(() => nanoflowCommonsActions(['Custom'])).toThrow('Unknown Nanoflow Commons action');
  });
  it('detects browser, hybrid and native hosts in the original precedence order', async () => {
    expect(await actions['NanoflowCommons.GetPlatform']({})).toBe('Web');
    vi.stubGlobal('navigator', {product: 'ReactNative'});
    expect(await actions['NanoflowCommons.GetPlatform']({})).toBe('Native_mobile');
    vi.stubGlobal('window', {cordova: {}});
    expect(await actions['NanoflowCommons.GetPlatform']({})).toBe('Hybrid_mobile');
  });
});
