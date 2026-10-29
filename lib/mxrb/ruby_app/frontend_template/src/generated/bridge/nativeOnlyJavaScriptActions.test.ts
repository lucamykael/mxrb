import { describe, expect, it } from 'vitest';
import { nativeOnlyJavaScriptActions } from './nanoflow';

describe('React Native only JavaScript actions', () => {
  it('report the call unavailable in the web app', () => {
    const actions = nativeOnlyJavaScriptActions(['OIDC.JS_OpenAuthURL']);
    expect(Object.keys(actions)).toEqual(['OIDC.JS_OpenAuthURL']);
    expect(() => actions['OIDC.JS_OpenAuthURL']({})).toThrow(
      'JavaScript action OIDC.JS_OpenAuthURL runs only in the native mobile app',
    );
  });
});
