import { useEffect, useRef, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { Command, StudioContext } from './types';

export function Tasks({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [catalog, setCatalog] = useState<Command[]>([]);
  const [command, setCommand] = useState<Command>();
  const [values, setValues] = useState<Record<string, string | boolean>>({});
  const [filter, setFilter] = useState('');
  const [error, setError] = useState('');
  const [output, setOutput] = useState('');
  const [status, setStatus] = useState('');
  const [running, setRunning] = useState(false);
  const active = useRef<{ id: string; cancel: AbortController } | null>(null);
  const alive = useRef(true);
  const directory = context.ruby_root ?? context.root;

  useEffect(() => {
    alive.current = true;
    const controller = new AbortController();
    rpc.call<Command[]>('catalog/list', {}, { signal: controller.signal }).then(setCatalog)
      .catch(reason => { if (!controller.signal.aborted) setError(String(reason)); });
    const unsubscribe = rpc.subscribe((method, params) => {
      if (params.task !== active.current?.id) return;
      if (method === 'tasks/output') setOutput(previous => (previous + String(params.text ?? '')).slice(-1_048_576));
    });
    return () => { alive.current = false; controller.abort(); active.current?.cancel.abort(); unsubscribe(); };
  }, [rpc]);

  useEffect(() => {
    active.current?.cancel.abort(); active.current = null;
    setRunning(false); setOutput(''); setStatus(''); setError('');
  }, [context.root, context.source_model, context.ruby_root]);

  function select(item: Command) {
    if (running) return;
    setCommand(item); setValues({}); setError('');
  }

  async function run() {
    if (!command || !directory || active.current) return;
    const task = { id: crypto.randomUUID(), cancel: new AbortController() };
    active.current = task;
    setRunning(true); setOutput(''); setError(''); setStatus('Running');
    const substitutions: Record<string, string> = { '{root}': directory };
    if (context.source_model) substitutions['{mpr}'] = context.source_model;
    if (context.ruby_root) substitutions['{ruby}'] = context.ruby_root;
    try {
      const result = await rpc.call<{ success: boolean; exit_code: number | null; cancelled: boolean }>('tasks/run', {
        command_id: command.name, values, directory, task_id: task.id, substitutions
      }, { signal: task.cancel.signal });
      if (alive.current && active.current === task) setStatus(result.cancelled ? 'Stopped' : result.success ? 'Completed' : `Failed (exit ${result.exit_code ?? 'signal'})`);
    } catch (reason) {
      if (alive.current && active.current === task) {
        if (task.cancel.signal.aborted) setStatus('Stopped');
        else { setError(String(reason)); setStatus('Failed'); }
      }
    } finally {
      if (alive.current && active.current === task) { active.current = null; setRunning(false); }
    }
  }

  const groups = new Map<string, Command[]>();
  for (const item of catalog.filter(entry => `${entry.name} ${entry.summary}`.toLowerCase().includes(filter.toLowerCase()))) {
    const group = item.context ?? 'global';
    groups.set(group, [...(groups.get(group) ?? []), item]);
  }
  return <section className="tasks-panel" aria-label="MXRB tasks">
    <div className="tool-heading">MXRB Tasks</div>
    <div className="tasks-content">
      <aside className="task-catalog" aria-label="MXRB command catalog">
        <input aria-label="Filter MXRB tasks" placeholder="Search tasks" value={filter} onChange={event => setFilter(event.target.value)} />
        {[...groups].map(([name, items]) => <details key={name} open><summary>{name}</summary>
          {items.map(item => <button key={item.name} title={item.summary} className={command?.name === item.name ? 'selected' : ''}
            disabled={running} onClick={() => select(item)}>{item.name}</button>)}
        </details>)}
        {catalog.length > 0 && groups.size === 0 && <p>No matching tasks.</p>}
      </aside>
      <div className="task-detail">
        {command ? <form onSubmit={event => { event.preventDefault(); void run(); }}>
          <h2>{command.name}</h2><p>{command.summary}</p>
          {command.fields.map(field => <label key={field.key} className="command-field">
            <span>{field.label}{field.required ? ' *' : ''}</span>
            {field.kind === 'boolean' ? <input type="checkbox" checked={Boolean(values[field.key] ?? field.default)} disabled={running}
              onChange={event => setValues(previous => ({ ...previous, [field.key]: event.target.checked }))} />
              : field.choices.length > 0 ? <select value={String(values[field.key] ?? field.default ?? '')} disabled={running}
                onChange={event => setValues(previous => ({ ...previous, [field.key]: event.target.value }))}>
                <option value="">Choose…</option>{field.choices.map(choice => <option key={choice}>{choice}</option>)}</select>
                : <input value={String(values[field.key] ?? field.default ?? '')} required={field.required} disabled={running}
                  onChange={event => setValues(previous => ({ ...previous, [field.key]: event.target.value }))} />}
          </label>)}
          <div className="task-actions"><button type="submit" disabled={running || !directory}>Run</button>
            <button type="button" disabled={!running} onClick={() => active.current?.cancel.abort()}>Stop</button></div>
        </form> : <p className="hint">Select an MXRB task to see its arguments.</p>}
        {!directory && <p className="hint">Open a project to run tasks.</p>}
        {error && <p className="error" role="alert">{error}</p>}
        <div className="task-status" role="status">{status}</div>
        <pre className="task-output" aria-label="Task output" tabIndex={0}>{output}</pre>
      </div>
    </div>
  </section>;
}
