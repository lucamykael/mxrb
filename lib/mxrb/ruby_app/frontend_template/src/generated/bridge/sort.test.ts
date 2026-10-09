import { describe, expect, it } from 'vitest';
import { decimal } from './decimal';
import { sortRecords } from './value';

// Rows and orders verified on the Mendix 11.12.1 Runtime (spec/fixtures/native_retrieve_sort).
const rows: Array<Record<string, string | number | boolean | null>> = [
  { Name: 'North', Nick: 'SELECT WHERE FROM', Amount: '9007199254740993.125', Active: true, Rank: 3 },
  { Name: 'South', Nick: "O'Brien", Amount: '2.5', Active: false, Rank: 1 },
  { Name: 'Empty', Nick: null, Amount: null, Active: true, Rank: null },
  { Name: 'Zero', Nick: '', Amount: '0', Active: false, Rank: 1 },
  { Name: 'Negative', Nick: '', Amount: '-1.25', Active: false, Rank: 2 },
  { Name: 'north', Nick: 'abc_def%', Amount: '7', Active: true, Rank: 3 },
  { Name: 'Nor', Nick: 'A', Amount: '2.5', Active: true, Rank: 2 },
];
const records = rows.map((row, index) => ({
  id: String(index),
  type: 'Views.Location',
  attributes: { ...row, Amount: row.Amount === null ? null : decimal(String(row.Amount)) },
}));
const order = (...keys: Array<[string, string]>) =>
  sortRecords(
    records,
    keys.map(([attribute, direction]) => ({ attribute: `Views.Location.${attribute}`, direction })),
  ).map((record) => record.attributes.Name);

describe('database sort order', () => {
  it('matches native NULL placement, case-insensitive strings and booleans', () => {
    const native: Record<string, [Array<[string, string]>, string[]]> = {
      NameAsc: [[['Name', 'Ascending'], ['Amount', 'Ascending']], ['Empty', 'Negative', 'Nor', 'north', 'North', 'South', 'Zero']],
      NameDesc: [[['Name', 'Descending'], ['Amount', 'Ascending']], ['Zero', 'South', 'north', 'North', 'Nor', 'Negative', 'Empty']],
      NickAsc: [[['Nick', 'Ascending'], ['Name', 'Ascending'], ['Amount', 'Ascending']], ['Empty', 'Negative', 'Zero', 'Nor', 'north', 'South', 'North']],
      NickDesc: [[['Nick', 'Descending'], ['Name', 'Ascending'], ['Amount', 'Ascending']], ['Empty', 'North', 'South', 'north', 'Nor', 'Negative', 'Zero']],
      AmountAsc: [[['Amount', 'Ascending'], ['Name', 'Ascending']], ['Empty', 'Negative', 'Zero', 'Nor', 'South', 'north', 'North']],
      AmountDesc: [[['Amount', 'Descending'], ['Name', 'Ascending']], ['Empty', 'North', 'north', 'Nor', 'South', 'Zero', 'Negative']],
      RankDescNameAsc: [[['Rank', 'Descending'], ['Name', 'Ascending'], ['Amount', 'Ascending']], ['Empty', 'north', 'North', 'Negative', 'Nor', 'South', 'Zero']],
      ActiveAsc: [[['Active', 'Ascending'], ['Name', 'Descending'], ['Amount', 'Ascending']], ['Zero', 'South', 'Negative', 'north', 'North', 'Nor', 'Empty']],
    };
    for (const [name, [keys, expected]] of Object.entries(native)) {
      expect(order(...keys), name).toEqual(expected);
    }
  });

  it('keeps stored order for equal keys and does not collate digits numerically', () => {
    const items = ['a10', 'A9', 'a10'].map((Name, index) => ({ id: String(index), type: 'App.Item', attributes: { Name } }));
    expect(sortRecords(items, [{ attribute: 'Name' }]).map((record) => record.id)).toEqual(['0', '2', '1']);
    expect(sortRecords(items).map((record) => record.id)).toEqual(['0', '1', '2']);
  });
});
