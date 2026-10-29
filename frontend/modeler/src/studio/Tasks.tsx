import { useEffect, useRef, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { Command, StudioContext } from './types';
import { taskWorkspace } from './taskWorkspace';
import { SyncPreview } from './SyncPreview';
import { ContextMenu, Icon, ToolButton, Toolbar, errorText, useDialogs } from './ui';
import type { MenuItem } from './ui';
import { appendOutput, changedValues, filterSaved, groupCommands, suggestName } from './taskTree';
import type { OutputChunk, SavedTask } from './taskTree';

type RunResult = { success: boolean; exit_code: number | null; cancelled: boolean; duration_ms?: number };
type Selection = { command: Command; saved?: SavedTask };

/** MXRB tasks as an IntelliJ Maven-style tool window: grouped tree, saved tasks per project, run output. */
export function Tasks({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [catalog, setCatalog] = useState<Command[]>([]);
  const [saved, setSaved] = useState<SavedTask[]>([]);
  const [selection, setSelection] = useState<Selection>();
  const [values, setValues] = useState<Record<string, string | boolean>>({});
  const [extra, setExtra] = useState('');
  const [filter, setFilter] = useState('');
  const [collapsed, setCollapsed] = useState(new Set<string>());
  const [error, setError] = useState('');
  const [output, setOutput] = useState<OutputChunk[]>([]);
  const [status, setStatus] = useState('');
  const [summary, setSummary] = useState('');
  const [running, setRunning] = useState(false);
  const [scrollLock, setScrollLock] = useState(false);
  const [menu, setMenu] = useState<{ x: number; y: number; item: Selection }>();
  const active = useRef<{ id: string; cancel: AbortController } | null>(null);
  const alive = useRef(true);
  const outputView = useRef<HTMLPreElement>(null);
  const dialogs = useDialogs(rpc, context);
  const directory = context.ruby_root ?? context.root;
  const project = context.source_model ?? context.root;
  const command = selection?.command;

  useEffect(() => {
    alive.current = true;
    const controller = new AbortController();
    rpc.call<Command[]>('catalog/list', {}, { signal: controller.signal }).then(setCatalog)
      .catch(reason => { if (!controller.signal.aborted) setError(errorText(reason)); });
    const unsubscribe = rpc.subscribe((method, params) => {
      if (params.task !== active.current?.id || method !== 'tasks/output') return;
      const stream = params.stream === 'stderr' ? 'stderr' : 'stdout';
      setOutput(previous => appendOutput(previous, { stream, text: String(params.text ?? '') }));
    });
    return () => { alive.current = false; controller.abort(); active.current?.cancel.abort(); unsubscribe(); };
  }, [rpc]);

  // A project switch stops the running task and forgets the previous project's output and saved tasks.
  useEffect(() => {
    active.current?.cancel.abort(); active.current = null;
    setRunning(false); setOutput([]); setStatus(''); setSummary(''); setError(''); setSaved([]);
    setSelection(previous => previous && { command: previous.command });
    if (!project) return;
    const controller = new AbortController();
    rpc.call<{ configurations: SavedTask[] }>('tasks/configurations', { project }, { signal: controller.signal })
      .then(result => setSaved(result.configurations))
      .catch(reason => { if (!controller.signal.aborted) setError(errorText(reason)); });
    return () => controller.abort();
  }, [rpc, project, context.root, context.ruby_root, context.project_revision]);

  useEffect(() => {
    if (!scrollLock && outputView.current) outputView.current.scrollTop = outputView.current.scrollHeight;
  }, [output, scrollLock]);

  function select(item: Selection) {
    if (running) return;
    setSelection(item); setError('');
    setValues(item.saved ? { ...item.saved.values } : {}); setExtra(item.saved?.extra ?? '');
  }

  async function run(item: Selection | undefined = selection, override?: { values: Record<string, string | boolean>; extra: string }) {
    if (!item || !directory || active.current) return;
    const task = { id: crypto.randomUUID(), cancel: new AbortController() };
    const runValues = override?.values ?? values;
    const runExtra = override?.extra ?? extra;
    active.current = task;
    setRunning(true); setOutput([]); setError(''); setStatus('Preparing'); setSummary('');
    try {
      const workspace = await taskWorkspace(rpc, context, task.cancel.signal, item.command.context === 'ruby');
      if (!alive.current || active.current !== task) return;
      setStatus('Running');
      setOutput([{ stream: 'system', text: `${item.saved?.name ?? item.command.name} — ${workspace.directory}\n` }]);
      const result = await rpc.call<RunResult>('tasks/run', {
        command_id: item.command.name, values: runValues, extra: runExtra, ...workspace, task_id: task.id
      }, { signal: task.cancel.signal });
      if (alive.current && active.current === task) {
        setStatus(result.cancelled ? 'Stopped' : result.success ? 'Completed' : `Failed (exit ${result.exit_code ?? 'signal'})`);
        if (result.duration_ms !== undefined) setSummary(`${(result.duration_ms / 1000).toFixed(1)} s`);
      }
    } catch (reason) {
      if (alive.current && active.current === task) {
        if (task.cancel.signal.aborted) setStatus('Stopped');
        else { setError(errorText(reason)); setStatus('Failed'); }
      }
    } finally {
      if (alive.current && active.current === task) { active.current = null; setRunning(false); }
    }
  }

  function stop() { active.current?.cancel.abort(); }

  async function save(asNew: boolean) {
    if (!command || !project) return;
    try {
      let name = selection?.saved?.name;
      if (asNew || !selection?.saved) {
        const answer = await dialogs.show({ kind: 'prompt', title: 'Save task', label: 'Name', value: suggestName(command, values) });
        if (answer.button === null || !answer.value?.trim()) return;
        name = answer.value.trim();
      }
      const configuration = { ...(asNew ? {} : { id: selection?.saved?.id }), name, command_id: command.name,
        values: changedValues(command, values), extra };
      const stored = await rpc.call<SavedTask>('tasks/saveConfiguration', { project, configuration });
      setSaved(previous => [...previous.filter(task => task.id !== stored.id), stored]);
      setSelection({ command, saved: stored });
    } catch (reason) { setError(errorText(reason)); }
  }

  async function renameSaved(task: SavedTask) {
    const item = catalog.find(entry => entry.name === task.command_id);
    const answer = await dialogs.show({ kind: 'prompt', title: 'Rename', label: 'Name', value: task.name });
    if (!item || answer.button === null || !answer.value?.trim() || answer.value.trim() === task.name) return;
    try {
      const stored = await rpc.call<SavedTask>('tasks/saveConfiguration', { project, configuration: { ...task, name: answer.value.trim() } });
      setSaved(previous => [...previous.filter(entry => entry.id !== stored.id), stored]);
      if (selection?.saved?.id === stored.id) setSelection({ command: item, saved: stored });
    } catch (reason) { setError(errorText(reason)); }
  }

  async function deleteSaved(task: SavedTask) {
    const answer = await dialogs.show({ kind: 'confirm', title: 'Warning', warning: true, buttons: ['Delete', 'Cancel'],
      message: `Are you sure you want to delete the saved task '${task.name}'?` });
    if (answer.button !== 'Delete') return;
    try {
      await rpc.call('tasks/deleteConfiguration', { project, id: task.id });
      setSaved(previous => previous.filter(entry => entry.id !== task.id));
      if (selection?.saved?.id === task.id) setSelection({ command: selection.command });
    } catch (reason) { setError(errorText(reason)); }
  }

  function menuItems(item: Selection): MenuItem[] {
    const items: MenuItem[] = [
      { label: `Run '${item.saved?.name ?? item.command.name}'`, disabled: running || !directory,
        action: () => { select(item); void run(item, { values: item.saved?.values ?? {}, extra: item.saved?.extra ?? '' }); } },
      { label: 'Stop', disabled: !running, action: stop },
      'separator'
    ];
    if (item.saved) {
      const task = item.saved;
      items.push({ label: 'Rename…', action: () => void renameSaved(task) }, { label: 'Delete', shortcut: 'Del', action: () => void deleteSaved(task) });
    } else {
      items.push({ label: 'Save as task…', disabled: !project, action: () => { select(item); void save(true); } });
    }
    return items;
  }

  const toggle = (key: string) => setCollapsed(previous => {
    const next = new Set(previous); if (next.has(key)) next.delete(key); else next.add(key); return next;
  });
  const leaf = (item: Selection, label: string, key: string) => {
    const isSelected = item.saved ? selection?.saved?.id === item.saved.id : !selection?.saved && command?.name === item.command.name;
    return <button key={key} type="button" title={item.saved ? `${item.saved.command_id} ${item.saved.extra}`.trim() : item.command.summary}
      className={isSelected ? 'selected' : ''} disabled={running} data-task={item.saved ? `saved:${item.saved.name}` : item.command.name}
      onClick={() => select(item)}
      onDoubleClick={() => { select(item); void run(item, { values: item.saved?.values ?? {}, extra: item.saved?.extra ?? '' }); }}
      onKeyDown={event => {
        if (event.key === 'Enter') { event.preventDefault(); select(item); void run(item, { values: item.saved?.values ?? {}, extra: item.saved?.extra ?? '' }); }
        if (event.key === 'Delete' && item.saved) { event.preventDefault(); void deleteSaved(item.saved); }
      }}
      onContextMenu={event => { event.preventDefault(); select(item); setMenu({ x: event.clientX, y: event.clientY, item }); }}
    >{label}</button>;
  };

  const groups = groupCommands(catalog, filter);
  const savedTasks = filterSaved(saved, filter);
  const byName = new Map(catalog.map(entry => [entry.name, entry]));
  return <section className="tasks-panel mx-panel" aria-label="MXRB tasks">
    <Toolbar label="MXRB task actions">
      <ToolButton icon="run" tone="run" label="Run selected task" onClick={() => void run()} disabled={running || !command || !directory} />
      <ToolButton icon="stop" tone="stop" label="Stop" onClick={stop} disabled={!running} />
      <span className="mx-separator" />
      <ToolButton icon="save" label="Save as task…" onClick={() => void save(true)} disabled={!command || !project} />
      <ToolButton icon="delete" label="Delete saved task" onClick={() => selection?.saved && void deleteSaved(selection.saved)}
        disabled={!selection?.saved} />
      <span className="mx-separator" />
      <ToolButton icon="expandAll" label="Expand all" onClick={() => setCollapsed(new Set())} />
      <ToolButton icon="collapseAll" label="Collapse all" onClick={() => setCollapsed(new Set(['saved', ...groups.map(group => group.key)]))} />
    </Toolbar>
    <div className="tasks-content">
      <aside className="task-catalog" aria-label="MXRB command catalog">
        <input type="search" aria-label="Filter MXRB tasks" placeholder="Search tasks" value={filter} onChange={event => setFilter(event.target.value)} />
        <details open={!collapsed.has('saved')} className="task-group task-saved">
          <summary onClick={event => { event.preventDefault(); toggle('saved'); }}><Icon name="saved" />Saved tasks</summary>
          {savedTasks.map(task => {
            const item = byName.get(task.command_id);
            return item ? leaf({ command: item, saved: task }, task.name, task.id)
              : <p key={task.id} className="mx-empty">{task.name}: unknown command {task.command_id}</p>;
          })}
          {savedTasks.length === 0 && <p className="mx-empty">{project ? 'Save a task to run it again with the same arguments.' : 'Open a project to save tasks.'}</p>}
        </details>
        {groups.map(group => <details key={group.key} open={!collapsed.has(group.key)} className="task-group">
          <summary onClick={event => { event.preventDefault(); toggle(group.key); }}><Icon name="task" />{group.title}</summary>
          {group.commands.map(item => leaf({ command: item }, item.name, item.name))}
        </details>)}
        {catalog.length > 0 && groups.length === 0 && savedTasks.length === 0 && <p>No matching tasks.</p>}
      </aside>
      <div className="task-detail">
        <SyncPreview rpc={rpc} context={context} />
        {command ? <form onSubmit={event => { event.preventDefault(); void run(); }}>
          <h2>{selection?.saved ? `${selection.saved.name}` : command.name}</h2>
          <p>{selection?.saved && <span className="mx-muted">mxrb {command.name} · </span>}{command.summary}</p>
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
          <label className="command-field"><span>Extra arguments</span>
            <input value={extra} disabled={running} placeholder="--json" onChange={event => setExtra(event.target.value)} /></label>
          <div className="task-actions"><button type="submit" disabled={running || !directory}>Run</button>
            <button type="button" disabled={!running} onClick={stop}>Stop</button>
            <button type="button" disabled={running || !project} onClick={() => void save(false)}>
              {selection?.saved ? 'Save' : 'Save as task…'}</button></div>
        </form> : <p className="hint">Select an MXRB task to see its arguments. Double-click or press Enter to run it.</p>}
        {!directory && <p className="hint">Open a project to run tasks.</p>}
        {error && <p className="error" role="alert">{error}</p>}
        <div className="task-console">
          <Toolbar label="Task output actions">
            <span className="task-status" role="status">{status}</span>
            {summary && <span className="mx-muted">{summary}</span>}
            <span className="mx-spacer" />
            <ToolButton icon="stop" tone="stop" label="Stop" onClick={stop} disabled={!running} />
            <ToolButton icon="clear" label="Clear" onClick={() => setOutput([])} disabled={output.length === 0} />
            <ToolButton icon="scrollLock" label="Scroll lock" pressed={scrollLock} onClick={() => setScrollLock(!scrollLock)} />
          </Toolbar>
          <pre ref={outputView} className="task-output" aria-label="Task output" tabIndex={0}>
            {output.map((chunk, index) => <span key={index} className={`task-${chunk.stream}`}>{chunk.text}</span>)}</pre>
        </div>
      </div>
    </div>
    {menu && <ContextMenu x={menu.x} y={menu.y} items={menuItems(menu.item)} onClose={() => setMenu(undefined)} />}
    {dialogs.element}
  </section>;
}
