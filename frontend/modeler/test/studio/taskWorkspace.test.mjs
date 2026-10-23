import assert from 'node:assert/strict';
import { test } from 'node:test';
import { taskWorkspace } from '../../src/studio/taskWorkspace.ts';

const native = { root: '/native/Shop', source_model: '/native/Shop/Shop.mpr' };
const signal = () => new AbortController().signal;

test('resolves a separately converted project again before each run', async () => {
  let root = '/state/first ruby';
  const requests = [];
  const rpc = { call: async (...args) => { requests.push(args); return { state: 'ready', root }; } };
  const first = await taskWorkspace(rpc, native, signal(), true);
  assert.deepEqual(first, {
    directory: root,
    substitutions: { '{root}': root, '{ruby}': root, '{mpr}': native.source_model }
  });
  root = '/state/reattached ruby';
  assert.equal((await taskWorkspace(rpc, native, signal(), true)).directory, root);
  assert.equal(requests.length, 2);
  assert.equal(requests[0][0], 'project/status');
  assert.deepEqual(requests[0][1], { source_model: native.source_model });
});

test('retains an explicit host Ruby root without querying the native project', async () => {
  const rpc = { call: () => assert.fail('host already supplied the Ruby root') };
  assert.equal((await taskWorkspace(rpc, { ...native, ruby_root: '/host/ruby' }, signal(), true)).directory, '/host/ruby');
});

test('keeps native commands available before conversion without inventing a Ruby substitution', async () => {
  const rpc = { call: async () => ({ state: 'missing', root: null }) };
  assert.deepEqual(await taskWorkspace(rpc, native, signal()), {
    directory: native.root, substitutions: { '{root}': native.root, '{mpr}': native.source_model }
  });
  await assert.rejects(taskWorkspace(rpc, native, signal(), true), /Convert or link this project/);
});

test('does not reuse a representation after it has been unlinked', async () => {
  let linked = true;
  const rpc = { call: async () => ({ state: linked ? 'ready' : 'missing', root: linked ? '/linked/ruby' : null }) };
  await taskWorkspace(rpc, native, signal(), true);
  linked = false;
  await assert.rejects(taskWorkspace(rpc, native, signal(), true), /Convert or link this project/);
});

test('rejects a late lookup when the project changed or Stop was pressed', async () => {
  const controller = new AbortController();
  let resolve;
  const rpc = { call: (_method, _params, options) => {
    assert.equal(options.signal, controller.signal);
    return new Promise(done => { resolve = done; });
  } };
  const pending = taskWorkspace(rpc, native, controller.signal);
  controller.abort();
  resolve({ state: 'ready', root: '/obsolete/ruby' });
  await assert.rejects(pending, { name: 'AbortError' });
});

test('does not query when already cancelled or hide lookup errors by running in a fallback directory', async () => {
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(taskWorkspace({ call: () => assert.fail('cancelled') }, native, controller.signal), { name: 'AbortError' });
  await assert.rejects(taskWorkspace({ call: async () => { throw new Error('backend unavailable'); } }, native, signal()), /backend unavailable/);
});

test('requires an open project and preserves source-only host contexts', async () => {
  const rpc = { call: () => assert.fail('no model was supplied') };
  await assert.rejects(taskWorkspace(rpc, {}, signal()), /Open a project/);
  assert.deepEqual(await taskWorkspace(rpc, { root: '/source' }, signal()), {
    directory: '/source', substitutions: { '{root}': '/source' }
  });
});
