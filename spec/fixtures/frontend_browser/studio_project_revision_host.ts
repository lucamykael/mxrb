// Synthetic host for the project-revision browser regression; never shipped in the app.
type RpcRequest = { id?: number; method: string; params: Record<string, any> };
type RpcListener = (event: { data: unknown }) => void;

(() => {
  const listeners = new Set<RpcListener>();
  let revision = 0;
  let cancelled = 0;
  let staleTask: RpcRequest | undefined;
  const context = () => ({ root: '/native/project', source_model: '/native/project/App.mpr', project_revision: revision });
  const rubyRoot = () => revision === 1 ? '/ruby/first' : '/ruby/second';
  const emit = (data: unknown) => listeners.forEach(listener => listener({ data }));
  const reply = (request: RpcRequest, result: unknown) => emit({ jsonrpc: '2.0', id: request.id, result });
  const notify = (method: string, params: unknown) => emit({ jsonrpc: '2.0', method, params });
  const catalog = [{ name: 'Revision task', summary: 'Synthetic context lifecycle task', context: 'ruby', effect: 'read', fields: [] }];
  const host = window as unknown as { chrome?: { webview?: unknown } };
  host.chrome ??= {};
  host.chrome.webview = {
    addEventListener: (_: string, listener: RpcListener) => listeners.add(listener),
    removeEventListener: (_: string, listener: RpcListener) => listeners.delete(listener),
    postMessage: (request: RpcRequest) => queueMicrotask(() => {
      switch (request.method) {
        case 'initialize': return reply(request, {});
        case 'host/context': return reply(request, context());
        case 'catalog/list': return reply(request, catalog);
        case 'project/status': return reply(request, { source_model: context().source_model,
          state: revision ? 'ready' : 'missing', root: revision ? rubyRoot() : null });
        case 'files/list': {
          const name = request.params.root === '/ruby/first' ? 'first.rb' : 'second.rb';
          return reply(request, [{ name, path: name, directory: false, size: 30 }]);
        }
        case 'files/read': throw new Error('Selecting a file must not read a preview');
        case 'tasks/run':
          if (revision === 1) {
            staleTask = request;
            return notify('tasks/output', { task: request.params.task_id, text: 'Task from first workspace' });
          }
          notify('tasks/output', { task: request.params.task_id,
            text: `Task workspace ${request.params.directory}; Ruby ${request.params.substitutions['{ruby}']}` });
          return reply(request, { success: true, cancelled: false, exit_code: 0 });
        case '$/cancelRequest':
          if (request.params.id === staleTask?.id) {
            cancelled += 1;
            document.querySelector('#cancelled-task-count')!.textContent = `Cancelled tasks: ${cancelled}`;
          }
          return;
        default: throw new Error(`Unexpected fixture RPC ${request.method}`);
      }
    })
  };
  window.addEventListener('DOMContentLoaded', () => {
    const controls = document.createElement('div');
    controls.style.cssText = 'position:fixed;bottom:0;right:0;z-index:100;background:white;padding:8px;color:black';
    controls.innerHTML = '<button id="advance-project-revision">Advance project revision</button>' +
      '<button id="finish-stale-task">Finish stale task</button><span id="cancelled-task-count">Cancelled tasks: 0</span>';
    document.body.appendChild(controls);
    (controls.querySelector('#advance-project-revision') as HTMLButtonElement).onclick = () => {
      revision += 1;
      notify('host/contextChanged', context());
    };
    (controls.querySelector('#finish-stale-task') as HTMLButtonElement).onclick = () => {
      if (!staleTask) throw new Error('Expected a pending old task');
      notify('tasks/output', { task: staleTask.params.task_id, text: 'OBSOLETE TASK OUTPUT' });
      reply(staleTask, { success: false, cancelled: false, exit_code: 9 });
    };
  });
})();
