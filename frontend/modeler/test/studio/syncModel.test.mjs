import assert from 'node:assert/strict';
import { test } from 'node:test';
import { applyParameters, conflictTitle, display, documentName, readiness, rubyProject } from '../../src/studio/syncModel.ts';

const revisions = { model: 'a'.repeat(64), ruby: 'b'.repeat(64) };
const status = { linked: true, state: 'conflict', revisions, documents: [] };
const element = { id: 'element:1:x:Length:set', kind: 'element', resolutions: ['ruby', 'mendix'], name: 'Domain model',
  element: { type: 'DomainModels$StringAttributeType' }, key: 'Length', base: { present: true, value: 200 },
  mendix: { present: true, value: 50 }, ruby: { present: true, value: 100 } };
const file = { id: 'file:modules/Shop/product.rb', kind: 'file', path: 'modules/Shop/product.rb', hunks: 1,
  resolutions: ['ruby', 'mendix'], ruby: 'mine', mendix: 'theirs' };
const comparison = { dry_run: true, applied: false, state: 'conflict', revisions, ruby_units: ['1'], mendix_units: ['1'],
  files: [{ path: file.path, action: 'write' }], conflicts: [element, file] };

test('apply waits for a current comparison and a choice for every conflict', () => {
  assert.match(readiness(undefined, undefined, {}).reason, /Link/);
  assert.match(readiness(status, undefined, {}).reason, /Compare/);
  assert.match(readiness(status, comparison, { [element.id]: 'ruby' }).reason, /1 conflict/);
  assert.equal(readiness(status, comparison, { [element.id]: 'ruby', [file.id]: 'mendix' }).ready, true);
  const moved = { ...status, revisions: { ...revisions, ruby: 'c'.repeat(64) } };
  assert.match(readiness(moved, comparison, { [element.id]: 'ruby', [file.id]: 'mendix' }).reason, /changed after the comparison/);
  const empty = { ...comparison, conflicts: [], ruby_units: [], mendix_units: [], files: [] };
  assert.match(readiness(status, empty, {}).reason, /Nothing/);
});

test('apply sends exactly the compared revisions and one resolution per conflict', () => {
  const parameters = applyParameters({ source_model: '/app/App.mpr' }, comparison, { [element.id]: 'ruby', [file.id]: 'mendix', stale: 'ruby' });
  assert.deepEqual(parameters, { source_model: '/app/App.mpr', expected_revisions: revisions,
    resolutions: { [element.id]: 'ruby', [file.id]: 'mendix' } });
});

test('names conflicts, documents and values the way the grid shows them', () => {
  assert.equal(conflictTitle(element), 'Domain model › String Attribute Type.Length');
  assert.equal(conflictTitle(file), 'Ruby file modules/Shop/product.rb');
  assert.equal(display(element.mendix), '50');
  assert.equal(display({ present: false }), '(absent)');
  assert.equal(display('text'), 'text');
  assert.equal(documentName({ qualified_name: 'Shop', type: 'DomainModels$DomainModel', unit_id: 'u' }), 'Shop (domain model)');
  assert.equal(documentName({ qualified_name: null, type: 'Microflows$Microflow', unit_id: '0123456789' }), 'Microflow 01234567');
});

test('resolves the Ruby project at call time', async () => {
  const signal = new AbortController().signal;
  assert.equal(await rubyProject({ call: async () => ({ state: 'ready', root: '/ruby' }) }, { source_model: '/m.mpr' }, signal), '/ruby');
  assert.equal(await rubyProject({ call: async () => ({ state: 'missing', root: null }) }, { source_model: '/m.mpr' }, signal), undefined);
  assert.equal(await rubyProject({ call: () => assert.fail('no project') }, {}, signal), undefined);
});
