import { describe, expect, it } from 'vitest';
import { selectable } from './selectable';

describe('public selectable XPath', () => {
  const records = [
    { id: '1', type: 'App.Tag', attributes: { Name: "A]B's", Rank: 2, Active: true } },
    { id: '2', type: 'App.Tag', attributes: { Name: 'Other', Rank: 3, Active: false } },
  ];
  it('supports quoted brackets, escaped quotes, boolean and comparison predicates', () => {
    expect(selectable(records, "[Name = 'A]B''s'][Active and Rank >= 2]", null)).toEqual([
      records[0],
    ]);
    expect(selectable(records, "[contains(Name, 'Other') or Rank > 5]", null)).toEqual([
      records[1],
    ]);
    expect(selectable(records, '[Rank = $currentObject/Rank]', records[1])).toEqual([records[1]]);
    expect(selectable(records, '', null)).toEqual(records);
  });
  it.each(['[', '[]', ']', "[Name = 'bad]", 'Name = 1', '[Link/Tag/Name = 1]', '[[Name = 1]]'])(
    'rejects unsupported or malformed constraints instead of exposing all choices: %s',
    (xpath) => {
      expect(() => selectable(records, xpath, null)).toThrow();
    },
  );
});
