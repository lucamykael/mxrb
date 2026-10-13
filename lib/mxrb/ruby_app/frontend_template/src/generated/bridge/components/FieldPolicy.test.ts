import { describe, expect, it } from 'vitest';
import type { EntityRecord } from '../../types';
import { editable, matchesCondition } from './FieldPolicy';

const item = (attributes: EntityRecord['attributes']): EntityRecord => ({
  id: '1',
  type: 'App.Item',
  attributes,
});

const values = (...pairs: [string, boolean][]) =>
  pairs.map(([AttributeValue, EditableVisible]) => ({ AttributeValue, EditableVisible }));

describe('attribute-based conditions', () => {
  it('match when the attribute equals one of the matching values', () => {
    const rule = {
      attribute: 'App.Item.Unlocked',
      conditions: values(['true', true], ['false', false]),
    };
    expect(matchesCondition(rule, item({ Unlocked: true }))).toBe(true);
    expect(matchesCondition(rule, item({ Unlocked: false }))).toBe(false);
    expect(matchesCondition(rule, null)).toBe(false);
    const stage = {
      attribute: 'App.Item.Stage',
      conditions: values(['Draft', true], ['Done', false], ['(empty)', true]),
    };
    expect(matchesCondition(stage, item({ Stage: 'Draft' }))).toBe(true);
    expect(matchesCondition(stage, item({ Stage: 'App.Stage.Draft' }))).toBe(true);
    expect(matchesCondition(stage, item({ Stage: 'Done' }))).toBe(false);
    expect(matchesCondition(stage, item({ Stage: null }))).toBe(true);
    expect(matchesCondition(stage, item({ Stage: '' }))).toBe(true);
    expect(matchesCondition(stage, null)).toBe(true);
  });

  it('reads the object of a named data widget and fails closed otherwise', () => {
    const rule = {
      attribute: 'App.Item.Unlocked',
      conditions: values(['true', true]),
      source_variable: { kind: 'widget', name: 'Details' },
    };
    const objects = { Details: item({ Unlocked: true }) };
    expect(matchesCondition(rule, item({ Unlocked: false }), [], objects)).toBe(true);
    expect(matchesCondition(rule, item({ Unlocked: true }))).toBe(false);
    expect(matchesCondition(rule, item({ Unlocked: true }), [], { Details: 'text' })).toBe(false);
    expect(
      matchesCondition({ ...rule, source_variable: { kind: 'current' } }, item({ Unlocked: true })),
    ).toBe(true);
    expect(
      matchesCondition({ ...rule, source_variable: { kind: 'page_parameter', name: 'P' } }, null),
    ).toBe(false);
    expect(matchesCondition({ ...rule, source_variable: 'Details' }, null)).toBe(false);
    expect(
      matchesCondition(
        {
          expression: '$currentObject/Unlocked',
          source_variable: { kind: 'widget', name: 'Details' },
        },
        null,
        [],
        objects,
      ),
    ).toBe(true);
  });

  it('rejects malformed values and still requires the module roles', () => {
    const subject = item({ Unlocked: true });
    expect(matchesCondition({ attribute: '', conditions: values(['true', true]) }, subject)).toBe(
      false,
    );
    expect(matchesCondition({ attribute: 'App.Item.Unlocked', conditions: 'true' }, subject)).toBe(
      false,
    );
    expect(
      matchesCondition(
        { attribute: 'App.Item.Unlocked', conditions: [null, { AttributeValue: 1 }] },
        subject,
      ),
    ).toBe(false);
    const roles = {
      attribute: 'App.Item.Unlocked',
      conditions: values(['true', true]),
      roles: ['App.Admin'],
    };
    expect(matchesCondition(roles, subject, ['App.User'])).toBe(false);
    expect(matchesCondition(roles, subject, ['App.Admin'])).toBe(true);
    expect(
      editable(
        {
          editable: 'conditional',
          editability: { attribute: 'App.Item.Unlocked', conditions: values(['true', true]) },
        },
        subject,
      ),
    ).toBe(true);
  });
});
