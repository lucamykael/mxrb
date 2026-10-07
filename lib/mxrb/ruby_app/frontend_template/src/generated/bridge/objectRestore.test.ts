import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ApplicationSchema, EntityRecord } from '../types';
import { api } from './api';
import { feedbackStorageActions } from './feedbackStorage';
import { registerObjectStorageSchema } from './objectStorage';
import { readStorageObject } from './objectRestore';
import { NanoflowRuntime, registerJavaScriptActions } from './nanoflow';

vi.mock('./api', () => ({ api: vi.fn() }));
const schema = {
  modules: [
    {
      name: 'FeedbackModule',
      models: [
        {
          name: 'FeedbackModule.Probe',
          attributes: [
            { name: 'Name', type: 'string' },
            { name: 'Amount', type: 'decimal' },
            { name: 'Count', type: 'integer' },
            { name: 'Active', type: 'boolean' },
            { name: 'When', type: 'datetime' },
          ],
        },
      ],
    },
  ],
} as ApplicationSchema;
const stored = {
  guid: 'old',
  Name: 'Restored',
  Amount: '9007199254740993.12345678',
  Count: '12',
  Active: false,
  When: 1767323045000,
};
const record: EntityRecord = {
  id: 'new',
  type: 'FeedbackModule.Probe',
  new_record: true,
  draft_token: 'capability',
  attributes: {
    Name: 'Restored',
    Amount: { __mxrb_decimal: stored.Amount },
    Count: 12,
    Active: false,
    When: '2026-01-02T03:04:05.000Z',
  },
};
const missing = () => Object.assign(new Error('Not found'), { status: 404 });
beforeEach(() => {
  vi.resetAllMocks();
  const data = new Map<string, string>();
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => {
      data.set(key, value);
    },
    clear: () => data.clear(),
  });
  registerObjectStorageSchema(schema);
});
afterEach(() => {
  registerObjectStorageSchema(null);
  registerJavaScriptActions({});
  vi.unstubAllGlobals();
});

describe('Feedback object restoration', () => {
  it('recreates a previously read persistent object after the server reports it deleted', async () => {
    localStorage.setItem('object', JSON.stringify(stored));
    vi.mocked(api)
      .mockResolvedValueOnce({ ...record, id: 'old', new_record: false, draft_token: undefined })
      .mockRejectedValueOnce(missing())
      .mockResolvedValueOnce(structuredClone(record));
    await readStorageObject({ Key: 'object', Entity: record.type });
    expect(await readStorageObject({ Key: 'object', Entity: record.type })).toEqual(record);
    expect(api).toHaveBeenCalledTimes(3);
    expect(JSON.parse(localStorage.getItem('object')!).guid).toBe('new');
  });
  it('reuses existing records and refreshes stale storage without creating or overwriting the object', async () => {
    localStorage.setItem('object', JSON.stringify(stored));
    vi.mocked(api).mockResolvedValue({
      ...record,
      id: 'old',
      attributes: { ...record.attributes, Name: 'Current' },
    });
    const result = await readStorageObject({ Key: 'object', Entity: 'FeedbackModule.Probe' });
    expect(result).toMatchObject({ id: 'old', attributes: { Name: 'Current' } });
    expect(JSON.parse(localStorage.getItem('object')!).Name).toBe('Current');
    expect(api).toHaveBeenCalledTimes(1);
  });
  it('recreates missing records without committing, rewrites the guid and reuses the new identity', async () => {
    localStorage.setItem('object', JSON.stringify(stored));
    vi.mocked(api).mockRejectedValueOnce(missing()).mockResolvedValueOnce(structuredClone(record));
    const actions = feedbackStorageActions(['JS_GetFeedbackStorageObject', 'GetStorageItemObject']);
    expect(
      await actions['FeedbackModule.JS_GetFeedbackStorageObject']({
        key: 'object',
        entity: 'FeedbackModule.Probe',
      }),
    ).toEqual(record);
    expect(api).toHaveBeenLastCalledWith('/api/records/restore', {
      method: 'POST',
      body: JSON.stringify({ type: record.type, attributes: record.attributes }),
    });
    expect(JSON.parse(localStorage.getItem('object')!)).toEqual({ ...stored, guid: 'new' });
    expect(
      await actions['FeedbackModule.GetStorageItemObject']({
        Key: 'object',
        Entity: 'FeedbackModule.Probe',
      }),
    ).toEqual(record);
    expect(api).toHaveBeenCalledTimes(2);
  });
  it('uses current nanoflow parameters before a stale storage snapshot or cached object', async () => {
    localStorage.setItem('object', JSON.stringify({ ...stored, guid: 'new' }));
    registerJavaScriptActions(feedbackStorageActions(['GetStorageItemObject']));
    const runtime = new NanoflowRuntime({ Item: record }, { name: 'FeedbackModule.Read' } as never);
    runtime.change('Item', { Name: "'Edited now'" });
    const result = await runtime.callJavaScript('FeedbackModule.GetStorageItemObject', {
      Key: "'object'",
      Entity: "'FeedbackModule.Probe'",
    });
    expect(result).toMatchObject({ attributes: { Name: 'Edited now' } });
    expect(api).not.toHaveBeenCalled();
    expect(JSON.parse(localStorage.getItem('object')!).Name).toBe('Edited now');
  });
  it('preserves storage on missing input, invalid JSON, network errors and creation failure', async () => {
    for (const parameters of [{}, { Key: 'object' }])
      await expect(readStorageObject(parameters)).rejects.toThrow('required');
    const args = { Key: 'object', Entity: record.type };
    await expect(readStorageObject(args)).rejects.toThrow('does not exist');
    for (const source of ['broken', 'null', '[]', '{}', '{"guid":42}']) {
      localStorage.setItem('object', source);
      await expect(readStorageObject(args)).rejects.toThrow();
      expect(localStorage.getItem('object')).toBe(source);
    }
    localStorage.setItem('object', JSON.stringify(stored));
    vi.mocked(api).mockRejectedValueOnce(Object.assign(new Error('Forbidden'), { status: 403 }));
    await expect(readStorageObject(args)).rejects.toThrow('Forbidden');
    vi.mocked(api)
      .mockRejectedValueOnce(missing())
      .mockRejectedValueOnce(new Error('Creation denied'));
    await expect(readStorageObject(args)).rejects.toThrow('Creation denied');
    expect(JSON.parse(localStorage.getItem('object')!)).toEqual(stored);
  });
  it('rejects unsafe numeric values and unavailable members before creating anything', async () => {
    for (const extra of [{ Count: '9007199254740993' }, { When: 'bad' }, { Unknown: 2 }]) {
      localStorage.setItem('object', JSON.stringify({ ...stored, ...extra }));
      vi.mocked(api).mockRejectedValueOnce(missing());
      await expect(readStorageObject({ Key: 'object', Entity: record.type })).rejects.toThrow();
    }
    expect(api).toHaveBeenCalledTimes(3);
  });
  it('clears cached object identities when loading another application', async () => {
    localStorage.setItem('object', JSON.stringify(stored));
    vi.mocked(api).mockResolvedValue(structuredClone(record));
    await readStorageObject({ Key: 'object', Entity: record.type });
    registerObjectStorageSchema(schema);
    await readStorageObject({ Key: 'object', Entity: record.type });
    expect(api).toHaveBeenCalledTimes(2);
  });
});
