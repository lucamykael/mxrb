// Opens URL in headless Chromium, clicks each selector in turn and prints the
// console messages and exceptions as JSON lines.
//   node script/cdp_console.mjs URL SELECTOR[,SELECTOR...] [WAIT_MS]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [url, selectors, wait = '3000'] = process.argv.slice(2);
const port = 9300 + Math.floor(Math.random() * 500);
const profile = mkdtempSync(join(tmpdir(), 'mxrb-cdp-'));
const chrome = spawn(
  process.env.CHROMIUM || 'chromium',
  ['--headless=new', '--no-sandbox', '--disable-gpu', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, 'about:blank'],
  { stdio: 'ignore' },
);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const finish = async (code) => {
  const exited = new Promise((resolve) => chrome.once('exit', resolve));
  chrome.kill('SIGTERM');
  await exited;
  rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  process.exit(code);
};

let target;
for (let attempt = 0; attempt < 50 && !target; attempt += 1) {
  try {
    const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    target = pages.find((page) => page.type === 'page');
  } catch {
    await sleep(200);
  }
}
if (!target) await finish(1);
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve) => socket.addEventListener('open', resolve));
let sequence = 0;
const pending = new Map();
const send = (method, params = {}) =>
  new Promise((resolve) => {
    sequence += 1;
    pending.set(sequence, resolve);
    socket.send(JSON.stringify({ id: sequence, method, params }));
  });
const emit = (type, text) => console.log(JSON.stringify({ type, text }));
socket.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) {
    pending.get(message.id)(message.result ?? message.error);
    pending.delete(message.id);
  }
  if (message.method === 'Runtime.consoleAPICalled')
    emit(message.params.type, message.params.args.map((arg) => arg.value ?? arg.description ?? '').join(' '));
  if (message.method === 'Runtime.exceptionThrown') {
    const details = message.params.exceptionDetails;
    emit('exception', details.exception?.description ?? details.text);
  }
});
const evaluate = async (expression) =>
  (await send('Runtime.evaluate', { expression, returnByValue: true }))?.result?.value;

await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url });
const list = selectors.split(',');
for (let attempt = 0; attempt < 120; attempt += 1) {
  if (await evaluate(`!!document.querySelector(${JSON.stringify(list[0])})`)) break;
  await sleep(500);
}
for (const selector of list) {
  const result = await evaluate(
    `(() => { const element = document.querySelector(${JSON.stringify(selector)}); if (!element) return 'missing'; element.click(); return 'clicked'; })()`,
  );
  emit('harness', `${selector} ${result}`);
  await sleep(Number(wait));
}
socket.close();
await finish(0);
