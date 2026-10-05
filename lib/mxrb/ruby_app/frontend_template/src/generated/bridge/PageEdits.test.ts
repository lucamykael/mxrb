import { describe, expect, it } from 'vitest';
import { PageEdits } from './PageEdits';

describe('new object draft identity', () => {
  it('keeps edits made during save and resolves old references after assigning a persisted id', () => {
    const edits = new PageEdits(true);
    const draft = {
      type: 'App.Item',
      id: 'draft',
      new_record: true,
      attributes: { Name: 'Original' },
    };
    edits.stage(draft, { Name: 'Saved' });
    const submitted = new Map(edits.changes);
    edits.stage(draft, { Name: 'While saving' });
    const committed = {
      type: 'App.Item',
      id: 'persisted',
      draft_id: 'draft',
      attributes: { Name: 'Saved' },
    };
    edits.accept([committed], submitted);
    expect(edits.resolve(draft)).toEqual({ ...committed, attributes: { Name: 'While saving' } });
    expect(edits.pending()).toEqual([
      { type: 'App.Item', id: 'persisted', attributes: { Name: 'While saving' } },
    ]);
    edits.stage(draft, { Name: 'Second edit' });
    expect(edits.resolve(draft)?.attributes.Name).toBe('Second edit');
    expect(edits.resolve(committed)?.attributes.Name).toBe('Second edit');
    edits.cancel();
    expect(edits.resolve(draft)?.attributes.Name).toBe('Saved');
    expect(edits.pending()).toEqual([]);
  });
});
