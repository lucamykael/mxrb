import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { buildInterfaces } from '../../build.ts';

async function snapshot(root, prefix = '') {
  const files = {};
  for (const item of await readdir(path.join(root, prefix), { withFileTypes: true })) {
    const name = path.join(prefix, item.name);
    if (item.isDirectory()) Object.assign(files, await snapshot(root, name));
    else files[name] = (await readFile(path.join(root, name))).toString('base64');
  }
  return files;
}

test('four entrypoints resolve assets, rebuild reproducibly and preserve non-Studio bundles', async () => {
  const output = await mkdtemp(path.join(tmpdir(), 'mxrb-ui-build-'));
  try {
    await buildInterfaces(output);
    for (const name of ['domain', 'modeler', 'uml', 'studio']) {
      const html = await readFile(path.join(output, `${name}.html`), 'utf8');
      assert.doesNotMatch(html, /\/src\//);
      const references = [...html.matchAll(/(?:src|href)="(\.\/assets\/[^\"]+)"/g)];
      assert.equal(references.length, 2, `${name}: stylesheet and module script`);
      for (const [, url] of references) assert.ok((await stat(path.join(output, url))).size > 0);
    }
    const original = await snapshot(output);
    await buildInterfaces(output, true);
    assert.deepEqual(await snapshot(output), original, 'Studio builds preserve every other entrypoint');
    await buildInterfaces(output);
    assert.deepEqual(await snapshot(output), original, 'clean builds are byte-for-byte reproducible');
  } finally {
    await rm(output, { recursive: true, force: true });
  }
});
