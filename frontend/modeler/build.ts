import { build, context } from 'esbuild';
import type { BuildOptions, Metafile, Plugin } from 'esbuild';
import { readFile, mkdir, rm, writeFile } from 'node:fs/promises';
import { createServer, request } from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const workspace = path.dirname(fileURLToPath(import.meta.url));
export const distribution = path.resolve(workspace, '../../lib/mxrb/web_ui');
const entries = {
  domain: 'src/domain-diagram/main.tsx', modeler: 'src/modeler/main.tsx',
  uml: 'src/uml/main.tsx', studio: 'src/studio/main.tsx'
};
type EntryName = keyof typeof entries;

function htmlPlugin(names: EntryName[], outdir: string): Plugin {
  return {
    name: 'html-entrypoints',
    setup(builder) {
      // Keep the HTML templates in esbuild's watch graph as well as the TS imports.
      builder.onLoad({ filter: /main\.tsx$/ }, async ({ path: source }) => {
        const name = names.find(name => path.resolve(workspace, entries[name]) === source);
        if (!name) return;
        return { contents: await readFile(source, 'utf8'), loader: 'tsx',
          resolveDir: path.dirname(source), watchFiles: [path.join(workspace, `${name}.html`)] };
      });
      builder.onEnd(async result => {
        if (result.errors.length || !result.metafile) return;
        await writeHtml(result.metafile, names, outdir);
      });
    }
  };
}

async function writeHtml(meta: Metafile, names: EntryName[], outdir: string) {
  const assetUrl = (file: string) => './' + path.relative(outdir, path.resolve(workspace, file)).split(path.sep).join('/');
  await Promise.all(names.map(async name => {
    const entry = Object.entries(meta.outputs).find(([file, info]) =>
      file.endsWith('.js') && info.entryPoint === entries[name]);
    if (!entry) throw new Error(`Missing output for ${name}`);
    const [js, info] = entry;
    const script = `<script type="module" src="${assetUrl(js)}"></script>`;
    const css = info.cssBundle ? `<link rel="stylesheet" href="${assetUrl(info.cssBundle)}">` : '';
    const template = await readFile(path.join(workspace, `${name}.html`), 'utf8');
    await writeFile(path.join(outdir, `${name}.html`),
      template.replace(/<script type="module" src="[^"]+"><\/script>/, `${css}${script}`));
  }));
}

function options(names: EntryName[], outdir: string, studio = false, watch = false): BuildOptions {
  const assets = studio ? 'assets/studio' : 'assets';
  return {
    absWorkingDir: workspace, entryPoints: Object.fromEntries(names.map(name => [name, entries[name]])),
    outdir, entryNames: `${assets}/[name]-[hash]`, chunkNames: `${assets}/chunk-[hash]`,
    assetNames: `${assets}/[name]-[hash]`, bundle: true, splitting: true, format: 'esm',
    platform: 'browser', target: 'es2022', jsx: 'automatic', minify: !watch, metafile: true,
    define: { 'process.env.NODE_ENV': JSON.stringify(watch ? 'development' : 'production') },
    loader: { '.woff': 'file', '.woff2': 'file', '.ttf': 'file', '.svg': 'file', '.png': 'file' },
    plugins: [htmlPlugin(names, outdir)], logLevel: 'info',
    banner: watch ? { js: "new EventSource('/esbuild').addEventListener('change', () => location.reload());" } : undefined
  };
}

export async function buildInterfaces(outdir = distribution, studioOnly = false) {
  await rm(studioOnly ? path.join(outdir, 'assets/studio') : outdir, { recursive: true, force: true });
  await mkdir(outdir, { recursive: true });
  if (!studioOnly) await build(options(['domain', 'modeler', 'uml'], outdir));
  // Studio stays independent: changing an IDE panel does not invalidate other entrypoints.
  await build(options(['studio'], outdir, true));
}

async function development() {
  // Development assets must not overwrite the gem's production bundles.
  const outdir = path.resolve(workspace, '../../tmp/modeler-dev');
  await mkdir(outdir, { recursive: true });
  const buildContext = await context(options(Object.keys(entries) as EntryName[], outdir, false, true));
  await buildContext.watch();
  const assets = await buildContext.serve({ servedir: outdir, host: '127.0.0.1', port: 0 });
  const apiPort = Number(process.env.MXRB_UI_API_PORT ?? '4568');
  const port = Number(process.env.MXRB_UI_PORT ?? '5173');
  const server = createServer((incoming, response) => {
    const url = incoming.url === '/' ? '/domain.html' : incoming.url;
    const api = url?.startsWith('/api/') || url === '/api';
    const upstream = request({ hostname: '127.0.0.1', port: api ? apiPort : assets.port,
      path: url, method: incoming.method, headers: incoming.headers }, reply => {
      response.writeHead(reply.statusCode ?? 502, reply.headers);
      reply.pipe(response);
    });
    upstream.on('error', () => { response.writeHead(502); response.end('Local backend unavailable'); });
    incoming.pipe(upstream);
  });
  server.listen(port, '127.0.0.1', () => console.log(`Modeler development: http://127.0.0.1:${port}`));
  const shutdown = async () => { server.close(); await buildContext.dispose(); };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.includes('--watch')) await development();
  else await buildInterfaces(distribution, process.argv.includes('--studio'));
}
