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

describe('NanoflowCommons.SignIn', () => {
  const signIn = nanoflowCommonsActions(['SignIn'])['NanoflowCommons.SignIn'];
  afterEach(() => vi.useRealTimers());

  it('answers 401 without a request for empty fields and returns the sign-in status', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(new Response('{}', { status: 401 }));
    vi.stubGlobal('fetch', fetch);
    expect(await signIn({ username: '', password: 'x' })).toBe(401);
    expect(await signIn({ username: 'alice', password: null })).toBe(401);
    expect(fetch).not.toHaveBeenCalled();
    expect(await signIn({ username: 'alice', password: 'wrong' })).toBe(401);
    expect(fetch).toHaveBeenCalledWith('/api/login', expect.objectContaining({ method: 'POST' }));
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ username: 'alice', password: 'wrong' });
  });

  it('reloads the application after a successful sign-in and reports offline as 0', async () => {
    vi.useFakeTimers();
    const reload = vi.fn();
    vi.stubGlobal('location', { ...window.location, reload });
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response('{}', { status: 200 })));
    expect(await signIn({ username: 'alice', password: 'Secret#1' })).toBe(200);
    vi.runAllTimers();
    expect(reload).toHaveBeenCalled();
    vi.stubGlobal('fetch', vi.fn().mockRejectedValueOnce(new TypeError('offline')));
    expect(await signIn({ username: 'alice', password: 'Secret#1' })).toBe(0);
  });
});
