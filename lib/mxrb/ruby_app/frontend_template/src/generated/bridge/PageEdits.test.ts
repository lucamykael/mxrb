import { describe, expect, it } from 'vitest';
import { PageEdits } from './PageEdits';

describe('new object draft identity', () => {
  it('accepts microflow changes while preserving edits made during the request and a pending draft Save', () => {
    const edits = new PageEdits(true);
    const draft = {
      type: 'App.Item',
      id: 'draft',
      new_record: true,
      draft_token: 'token',
      attributes: { Name: 'First' },
    };
    edits.stage(draft, { Name: 'Submitted' });
    const submitted = edits.changes.get('App.Item/draft');
    edits.stage(draft, { Note: 'While waiting' });
    const response = { ...draft, attributes: { Name: 'Changed by microflow' } };
    expect(edits.refresh(response, submitted).attributes).toEqual({
      Name: 'Changed by microflow',
      Note: 'While waiting',
    });
    expect(edits.pending()[0]).toMatchObject({
      draft_token: 'token',
      attributes: { Note: 'While waiting' },
    });
    const other = { ...response, id: 'other' };
    expect(edits.refresh(other)).toBe(other);
  });

  it('carries a server draft capability through Save without resubmitting readonly defaults', () => {
    const edits = new PageEdits(true);
    const draft = {
      type: 'App.Item',
      id: 'draft',
      new_record: true,
      draft_token: 'opaque-token',
      attributes: { Name: 'Initial', Readonly: 'Server-owned' },
    };
    edits.stage(draft, {});
    expect(edits.pending()).toEqual([
      {
        type: 'App.Item',
        id: 'draft',
        new_record: true,
        draft_token: 'opaque-token',
        attributes: {},
      },
    ]);
    edits.stage(draft, { Name: 'Changed' });
    expect(edits.pending()[0].attributes).toEqual({ Name: 'Changed' });
    edits.accept([{ type: 'App.Item', id: 'draft', attributes: { Name: 'Changed' } }]);
    expect(edits.resolve(draft)).not.toHaveProperty('draft_token');
    expect(edits.pending()).toEqual([]);
  });

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
