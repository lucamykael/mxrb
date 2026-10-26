// Browser lifecycle fixture only. Real compilation is accepted separately.
type RpcRequest = { id?: number; method: string; params?: Record<string, unknown> };
type RpcListener = (event: { data: unknown }) => void;

(() => {
  const listeners = new Set<RpcListener>();
  let revision = 0, mode = 'ready', pending: RpcRequest | undefined, opens = 0;
  const emit = (data: unknown) => listeners.forEach(listener => listener({ data }));
  const reply = (request: RpcRequest, result: unknown) => emit({ jsonrpc: '2.0', id: request.id, result });
  const context = () => ({ root: '/native/project', source_model: '/native/project/App.mpr',
    ruby_root: '/ruby/project', project_revision: revision, capabilities: { native_ruby_editor: true } });
  const result = (state: string) => ({ state, source_model: context().source_model, root: '/ruby/project', applied: false,
    units: [{ unit_id: 'one', name: 'ExampleFlow', type: 'Microflows$Microflow', action: 'modified',
      changes: [{ op: 'set', key: 'Caption', before: 'old caption', after: 'new caption' }] }],
    limitations: ['Bidirectional conflicts have not been assessed.'], validation: { valid: true } });
  const host = window as unknown as { chrome?: { webview?: unknown } };
  host.chrome ??= {};
  host.chrome.webview = {
    addEventListener: (_: string, listener: RpcListener) => listeners.add(listener),
    removeEventListener: (_: string, listener: RpcListener) => listeners.delete(listener),
    postMessage: (request: RpcRequest) => queueMicrotask(() => {
      switch (request.method) {
        case 'initialize': return reply(request, {});
        case 'host/context': return reply(request, context());
        case 'files/list': return reply(request, [{ name: 'flow.rb', path: 'flow.rb', directory: false, size: 30 }]);
        case 'files/read': throw new Error('File selection must not read code');
        case 'catalog/list': return reply(request, []);
        case 'host/openFile':
          if (request.params?.root !== '/ruby/project' || request.params?.path !== 'flow.rb') throw new Error('Wrong editor context');
          document.querySelector('#opens')!.textContent = `Editor opens: ${++opens}`;
          return reply(request, { path: 'flow.rb', opened: true });
        case 'sync/preview':
          if (mode === 'pending') { pending = request; return; }
          if (mode === 'error') return emit({ jsonrpc: '2.0', id: request.id, error: { code: -32000, message: 'Compilation failed' } });
          return reply(request, result(mode));
        case '$/cancelRequest':
          document.querySelector('#cancelled')!.textContent = 'Preview request cancelled'; return;
        default: throw new Error(`Unexpected fixture RPC ${request.method}`);
      }
    }),
  };
  window.addEventListener('DOMContentLoaded', () => {
    const controls = document.createElement('div');
    controls.style.cssText = 'position:fixed;bottom:0;right:0;z-index:100;background:white;padding:4px;color:black;max-width:280px';
    controls.innerHTML = ['ready', 'stale', 'unavailable', 'error', 'pending'].map(value =>
      `<button id="mode-${value}">${value}</button>`).join('') +
      '<button id="change-project">Change project revision</button><button id="late-reply">Late reply</button>' +
      '<button id="enter-file">Enter file</button><button id="double-file">Double click file</button>' +
      '<span id="opens">Editor opens: 0</span><span id="cancelled"></span>';
    document.body.appendChild(controls);
    for (const value of ['ready', 'stale', 'unavailable', 'error', 'pending'])
      (controls.querySelector(`#mode-${value}`) as HTMLButtonElement).onclick = () => { mode = value; };
    (controls.querySelector('#change-project') as HTMLButtonElement).onclick = () => emit({ jsonrpc: '2.0', method: 'host/contextChanged', params: { ...context(), project_revision: ++revision } });
    (controls.querySelector('#late-reply') as HTMLButtonElement).onclick = () => { if (pending) reply(pending, result('ready')); };
    (controls.querySelector('#enter-file') as HTMLButtonElement).onclick = () => document.querySelector('[data-path="flow.rb"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    (controls.querySelector('#double-file') as HTMLButtonElement).onclick = () => document.querySelector('[data-path="flow.rb"]')!.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
  });
})();
