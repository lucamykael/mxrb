import { describe, expect, it } from 'vitest';
import { initializeVariables, resolveParameters, liveParameters } from './PageVariables';
import { eventArguments } from './value';
import type { ApplicationSchema, ValueDefinition } from '../types';

const schema = {
  modules: [
    {
      name: 'App',
      models: [{ name: 'App.Base' }, { name: 'App.Child', generalization: { target: 'App.Base' } }],
      enumerations: [{ name: 'App.Status', values: [{ name: 'Ready' }] }],
    },
  ],
} as ApplicationSchema;
const record = { type: 'App.Child', id: '1', attributes: {} };

describe('page value contracts', () => {
  it('refreshes named aliases and list entries after an active object changes without replacing other arguments', () => {
    const original = { ...record, attributes: { Enabled: false } };
    const updated = { ...record, attributes: { Enabled: true } };
    const differentId = { ...original, id: '2' };
    const differentType = { ...original, type: 'App.Other' };
    const parameters = {
      Item: original,
      Alias: original,
      Items: [original, differentId],
      Other: differentType,
      Empty: null,
      Caption: 'title',
    };
    const refreshed = liveParameters(parameters, updated);
    expect(refreshed.Item).toBe(updated);
    expect(refreshed.Alias).toBe(updated);
    expect(refreshed.Items).toEqual([updated, differentId]);
    expect(refreshed.Other).toBe(differentType);
    expect(refreshed.Empty).toBeNull();
    expect(refreshed.Caption).toBe('title');
    expect(parameters.Item.attributes.Enabled).toBe(false);
    expect(liveParameters(parameters, null)).toEqual(parameters);
  });
  it('resolves qualified named object and primitive arguments without replacing explicit empty values', () => {
    const definitions: ValueDefinition[] = [
      { name: 'Item', type: { kind: 'object', entity: 'App.Base' } },
      { name: 'Title', type: { kind: 'string' }, required: false, default: "'Fallback'" },
      { name: 'Count', type: { kind: 'integer' }, required: false, default: '42' },
    ];
    expect(
      resolveParameters(definitions, { 'App.Detail.Item': record, Title: null }, null, schema),
    ).toEqual({ Item: record, Title: null, Count: 42 });
    expect(() => resolveParameters(definitions, {}, null, schema)).toThrow(
      'Missing required parameter: Item',
    );
    expect(() =>
      resolveParameters(definitions, { Item: { ...record, type: 'App.Other' } }, null, schema),
    ).toThrow('Invalid object');
    expect(() =>
      resolveParameters(definitions, { Item: record, Count: 'invalid' }, null, schema),
    ).toThrow('Invalid integer');
  });

  it('rejects ambiguous arguments and keeps explicit parameter sources separate from row context', () => {
    expect(() =>
      resolveParameters([], { 'App.Page.Name': 'one', Name: 'two' }, null, schema),
    ).toThrow('Duplicate page argument Name');
    expect(
      eventArguments(
        {
          event: 'on_click',
          kind: 'page',
          handler: 'Detail',
          arguments: {
            item: { kind: 'page_parameter', name: 'App.Page.Item' },
            count: '$Count + 1',
          },
        },
        { ...record, id: 'row' },
        { pageParameters: { Item: record, Count: 2 } },
      ),
    ).toEqual({ item: record, count: 3 });
  });

  it('initializes local variables in dependency order and detects cycles while ignoring quoted names', () => {
    expect(
      initializeVariables(
        [
          { name: 'Next', type: { kind: 'integer' }, default: '$Start + 1' },
          { name: 'Label', type: { kind: 'string' }, default: "'$Label'" },
          { name: 'Start', type: { kind: 'integer' }, default: '$Count + 1' },
        ],
        { Count: 2 },
        null,
        schema,
      ),
    ).toEqual({ Start: 3, Next: 4, Label: '$Label' });
    expect(() =>
      initializeVariables(
        [
          { name: 'A', default: '$B' },
          { name: 'B', default: '$A' },
        ],
        {},
        null,
        schema,
      ),
    ).toThrow('Cyclic local variables');
  });
});
