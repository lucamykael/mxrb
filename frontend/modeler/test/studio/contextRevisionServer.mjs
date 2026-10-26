// Serves the packaged UI with a synthetic host for the Studio browser scenarios:
// studio_project_revision_flow.json (/studio.html) and the sync preview flows (/studio.html?fixture=sync).
// Usage: node frontend/modeler/test/studio/contextRevisionServer.mjs [port] [bundle-root]
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';
import { resolve, sep } from 'node:path';

const repository = fileURLToPath(new URL('../../../../', import.meta.url));
const root = resolve(process.argv[3] ?? resolve(repository, 'lib/mxrb/web_ui'));
const fixture = async name => stripTypeScriptTypes(
  await readFile(resolve(repository, `spec/fixtures/frontend_browser/${name}.ts`), 'utf8'));
const hosts = { revision: await fixture('studio_project_revision_host'), sync: await fixture('studio_sync_preview_host') };
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://localhost');
    const path = resolve(root, '.' + url.pathname);
    if (!path.startsWith(root + sep)) { response.writeHead(403).end(); return; }
    let body = await readFile(path);
    const host = hosts[url.searchParams.get('fixture') === 'sync' ? 'sync' : 'revision'];
    if (path.endsWith('/studio.html')) body = Buffer.from(body.toString().replace('<head>', `<head><script>${host}</script>`));
    response.writeHead(200, { 'content-type': path.endsWith('.html') ? 'text/html' : path.endsWith('.js') ? 'text/javascript' : 'text/css' });
    response.end(body);
  } catch { response.writeHead(404).end(); }
});
server.listen(Number(process.argv[2] ?? 4587), '127.0.0.1', () => console.log(`Revision fixture: http://127.0.0.1:${server.address().port}`));
