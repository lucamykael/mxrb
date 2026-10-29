import assert from 'node:assert/strict';
import { test } from 'node:test';
import { childPath, forget, moveExpansion, parentOf, targetFolder, validateName, worktreePath } from '../../src/studio/explorerOperations.ts';

test('places new items in the selected folder or next to the selected file', () => {
  assert.equal(targetFolder(undefined), '.');
  assert.equal(targetFolder({ name: 'app', path: 'app', directory: true, size: 0 }), 'app');
  assert.equal(targetFolder({ name: 'a.rb', path: 'app/models/a.rb', directory: false, size: 1 }), 'app/models');
  assert.equal(targetFolder({ name: 'b.rb', path: 'b.rb', directory: false, size: 1 }), '.');
  assert.equal(childPath('.', 'x.rb'), 'x.rb');
  assert.equal(childPath('app', 'x.rb'), 'app/x.rb');
  assert.equal(parentOf('app/models/a.rb'), 'app/models');
});

test('rejects names the backend would treat as paths', () => {
  assert.equal(validateName('ação.rb'), '');
  for (const name of ['', '  ', '.', '..', 'a/b', '.git', 'x'.repeat(256)]) assert.notEqual(validateName(name), '', name);
});

test('forgets cached listings below a deleted folder and keeps renamed folders expanded', () => {
  const entries = { '.': [], app: [], 'app/models': [], application: [] };
  const expanded = new Set(['.', 'app', 'app/models', 'application']);
  const cleared = forget(entries, expanded, 'app');
  assert.deepEqual(Object.keys(cleared.entries), ['.', 'application']);
  assert.deepEqual([...cleared.expanded], ['.', 'application']);
  assert.deepEqual([...moveExpansion(expanded, 'app', 'core')], ['.', 'core', 'core/models', 'application']);
});

test('derives a sibling worktree directory from the branch', () => {
  assert.equal(worktreePath('/work/shop-ruby/', 'feature/new orders'), '/work/shop-ruby-feature-new-orders');
  assert.equal(worktreePath('/work/r', '///'), '/work/r-worktree');
});
