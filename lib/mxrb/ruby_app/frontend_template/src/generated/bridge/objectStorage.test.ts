import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ApplicationSchema, EntityRecord } from '../types';
import {
  registerObjectStorageSchema,
  serializeStorageObject,
  writeStorageObject,
} from './objectStorage';
import { feedbackStorageActions } from './feedbackStorage';

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
            { name: 'Empty', type: 'string' },
          ],
        },
      ],
      associations: [
        {
          name: 'FeedbackModule.Probe_Related',
          from_entity: 'FeedbackModule.Probe',
          type: 'Reference',
        },
        {
          name: 'FeedbackModule.Probe_Links',
          from_entity: 'FeedbackModule.Probe',
          type: 'ReferenceSet',
        },
      ],
    },
  ],
} as ApplicationSchema;
const record: EntityRecord = {
  id: 'probe-id',
  type: 'FeedbackModule.Probe',
  attributes: {
    Name: 'Object oracle',
    Amount: { __mxrb_decimal: '9007199254740993.12345678' },
    Count: 12,
    Active: true,
    When: '2026-01-02T03:04:05Z',
    Empty: '',
  },
};

beforeEach(() => {
  const data = new Map<string, string>();
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => {
      data.set(key, value);
    },
    clear: () => data.clear(),
  });
});
afterEach(() => {
  registerObjectStorageSchema(null);
  localStorage.clear();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('verified object storage writers', () => {
  it('uses native numeric strings, epoch dates, qualified references and the object guid', async () => {
    registerObjectStorageSchema(schema);
    await writeStorageObject({ Key: 'object', Value: record });
    expect(JSON.parse(localStorage.getItem('object')!)).toEqual({
      guid: 'probe-id',
      Name: 'Object oracle',
      Amount: '9007199254740993.12345678',
      Count: '12',
      Active: true,
      When: 1767323045000,
      Empty: '',
      'FeedbackModule.Probe_Related': null,
      'FeedbackModule.Probe_Links': [],
    });
    expect(record.attributes.When).toBe('2026-01-02T03:04:05Z');
  });

  it('preserves reference identifiers, false, null and empty strings without serializing nested objects', () => {
    registerObjectStorageSchema(schema);
    expect(
      serializeStorageObject({
        ...record,
        attributes: {
          ...record.attributes,
          Active: false,
          When: null,
          Probe_Related: {
            id: 'related',
            type: 'FeedbackModule.Related',
            attributes: { Secret: 'omit' },
          },
          Probe_Links: [{ id: 'partial', type: 'FeedbackModule.Related' }, 'another'],
          'FeedbackModule.Probe.Name': 'Latest',
        },
      }),
    ).toMatchObject({
      Name: 'Latest',
      Active: false,
      When: null,
      Empty: '',
      'FeedbackModule.Probe_Related': 'related',
      'FeedbackModule.Probe_Links': ['partial', 'another'],
    });
  });

  it('registers both verified Feedback action names', async () => {
    registerObjectStorageSchema(schema);
    const actions = feedbackStorageActions(['JS_SetFeedbackStorageObject', 'SetStorageItemObject']);
    await actions['FeedbackModule.JS_SetFeedbackStorageObject']({ key: 'object', value: record });
    await actions['FeedbackModule.SetStorageItemObject']({ Key: 'object', Value: record });
    expect(JSON.parse(localStorage.getItem('object')!).Count).toBe('12');
  });

  it('preserves required parameter and browser storage errors', async () => {
    await expect(writeStorageObject({ Value: record })).rejects.toThrow(
      "Input parameter 'Key' is required",
    );
    await expect(writeStorageObject({ Key: 'object' })).rejects.toThrow(
      "Input parameter 'Value' is required",
    );
    registerObjectStorageSchema(schema);
    vi.spyOn(localStorage, 'setItem').mockImplementation(() => {
      throw new Error('Quota exceeded');
    });
    await expect(writeStorageObject({ Key: 'object', Value: record })).rejects.toThrow(
      'Quota exceeded',
    );
  });

  it('rejects unsafe integers, invalid dates and invalid records before touching storage', async () => {
    registerObjectStorageSchema(schema);
    for (const attributes of [
      { Count: Number.MAX_SAFE_INTEGER + 1 },
      { Count: 1.5 },
      { When: 'invalid' },
      { Probe_Related: 4 },
      { Unknown: 'not in schema' },
    ]) {
      await expect(
        writeStorageObject({
          Key: 'object',
          Value: { ...record, attributes: { ...record.attributes, ...attributes } },
        }),
      ).rejects.toThrow();
    }
    await expect(writeStorageObject({ Key: 'object', Value: 'not an object' })).rejects.toThrow(
      'application record',
    );
    expect(localStorage.getItem('object')).toBeNull();
  });

  it('clears application metadata when a new application starts loading', async () => {
    registerObjectStorageSchema(schema);
    registerObjectStorageSchema(null);
    await expect(writeStorageObject({ Key: 'object', Value: record })).rejects.toThrow(
      'schema is unavailable',
    );
  });

  it('rejects incomplete object snapshots instead of silently omitting native attributes', async () => {
    registerObjectStorageSchema(schema);
    await expect(
      writeStorageObject({ Key: 'object', Value: { ...record, attributes: { Name: 'partial' } } }),
    ).rejects.toThrow('loaded attribute: Amount');
    expect(localStorage.getItem('object')).toBeNull();
  });
});
