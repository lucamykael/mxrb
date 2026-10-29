import assert from 'node:assert/strict';
import { test } from 'node:test';
import { appendOutput, changedValues, filterSaved, groupCommands, suggestName } from '../../src/studio/taskTree.ts';

const field = (key, extra = {}) => ({ key, label: key, kind: 'text', required: false, default: null, choices: [], ...extra });
const catalog = [
  { name: 'validate', summary: 'Validate a model', context: 'model', effect: 'read', fields: [field('model', { default: '{mpr}', required: true })] },
  { name: 'db up', summary: 'Start the database', context: 'database', effect: 'service', fields: [field('json', { kind: 'boolean', default: false })] },
  { name: 'analyze', summary: 'Analyze queries', context: 'model', effect: 'read', fields: [] },
  { name: 'weird', summary: 'Unknown context', context: 'future', effect: 'read', fields: [] }
];

test('groups the catalog like Maven lifecycle groups, sorted, with unknown contexts kept', () => {
  assert.deepEqual(groupCommands(catalog, '').map(group => [group.title, group.commands.map(command => command.name)]),
    [['Model', ['analyze', 'validate']], ['Database', ['db up']], ['Other', ['weird']]]);
  assert.deepEqual(groupCommands(catalog, 'DATABASE').map(group => group.key), ['database']);
});

test('stores only explicit values and suggests a readable name', () => {
  const validate = catalog[0];
  assert.deepEqual(changedValues(validate, { model: '{mpr}' }), {});
  assert.deepEqual(changedValues(validate, { model: '/apps/Shop.mpr', stray: 'x' }), { model: '/apps/Shop.mpr' });
  assert.deepEqual(changedValues(catalog[1], { json: false }), {});
  assert.deepEqual(changedValues(catalog[1], { json: true }), { json: true });
  assert.equal(suggestName(validate, { model: '/apps/Shop.mpr' }), 'validate Shop.mpr');
  assert.equal(suggestName(validate, {}), 'validate');
  assert.deepEqual(filterSaved([{ id: '2', name: 'b', command_id: 'lint' }, { id: '1', name: 'a', command_id: 'validate' }], 'VALID')
    .map(task => task.id), ['1']);
});

test('merges output by stream and keeps the newest characters within the limit', () => {
  let output = appendOutput([], { stream: 'stdout', text: 'abc' }, 5);
  output = appendOutput(output, { stream: 'stdout', text: 'de' }, 5);
  assert.deepEqual(output, [{ stream: 'stdout', text: 'abcde' }]);
  output = appendOutput(output, { stream: 'stderr', text: 'XY' }, 5);
  assert.deepEqual(output, [{ stream: 'stdout', text: 'cde' }, { stream: 'stderr', text: 'XY' }]);
  output = appendOutput(output, { stream: 'stderr', text: '12345678' }, 5);
  assert.deepEqual(output, [{ stream: 'stderr', text: '45678' }]);
});
