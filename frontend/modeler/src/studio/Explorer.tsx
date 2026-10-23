import { useEffect, useRef, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { Entry, FileContent, ProjectStatus, StudioContext } from './types';

export function Explorer({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [root, setRoot] = useState(context.ruby_root);
  const [state, setState] = useState(context.ruby_root ? 'ready' : 'loading');
  const [entries, setEntries] = useState<Record<string, Entry[]>>({});
  const [expanded, setExpanded] = useState(new Set(['.']));
  const [selected, setSelected] = useState<FileContent>();
  const [error, setError] = useState('');
  const [progress, setProgress] = useState('');
  const [scroll, setScroll] = useState(0);
  const [opening, setOpening] = useState('');
  const epoch = useRef(0);
  const operations = useRef(new AbortController());
  const selection = useRef(0);
  const tree = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const current = ++epoch.current;
    const controller = new AbortController();
    operations.current = controller;
    setRoot(undefined);
    setSelected(undefined); setEntries({}); setExpanded(new Set(['.'])); setError(''); setOpening('');
    if (context.ruby_root) { setRoot(context.ruby_root); setState('ready'); }
    else if (context.source_model) {
      setState('loading');
      rpc.call<ProjectStatus>('project/status', { source_model: context.source_model }, { signal: controller.signal })
        .then(status => { if (current === epoch.current) { setRoot(status.root ?? undefined); setState(status.state); } })
        .catch(reason => { if (!controller.signal.aborted) { setError(String(reason)); setState('error'); } });
    } else { setRoot(undefined); setState('no-project'); }
    return () => { ++epoch.current; ++selection.current; controller.abort(); };
  }, [rpc, context.source_model, context.ruby_root, context.project_revision]);

  useEffect(() => {
    if (!root) return;
    const controller = new AbortController();
    rpc.call<Entry[]>('files/list', { root }, { signal: controller.signal })
      .then(items => setEntries({ '.': items }))
      .catch(reason => { if (!controller.signal.aborted) setError(String(reason)); });
    return () => controller.abort();
  }, [rpc, root, context.source_model, context.project_revision]);

  async function convert() {
    const current = epoch.current;
    setState('converting'); setError('');
    try {
      const result = await rpc.call<ProjectStatus>('project/convert', { source_model: context.source_model }, {
        signal: operations.current.signal,
        progress: value => { if (current === epoch.current) setProgress(String(value.detail ?? value.kind ?? '')); }
      });
      if (current === epoch.current) { setRoot(result.root ?? undefined); setState(result.state); }
    } catch (reason) { if (current === epoch.current) { setError(String(reason)); setState('missing'); } }
  }

  async function activate(entry: Entry) {
    const current = epoch.current;
    if (entry.directory) {
      setExpanded(previous => { const next = new Set(previous); if (next.has(entry.path)) next.delete(entry.path); else next.add(entry.path); return next; });
      if (!entries[entry.path]) {
        try {
          const items = await rpc.call<Entry[]>('files/list', { root, path: entry.path }, { signal: operations.current.signal });
          if (current === epoch.current) setEntries(previous => ({ ...previous, [entry.path]: items }));
        } catch (reason) { if (current === epoch.current) setError(String(reason)); }
      }
    } else {
      const token = ++selection.current;
      try {
        const content = await rpc.call<FileContent>('files/read', { root, path: entry.path }, { signal: operations.current.signal });
        if (current === epoch.current && token === selection.current) { setSelected(content); setError(''); }
      } catch (reason) { if (current === epoch.current && token === selection.current) setError(String(reason)); }
    }
  }

  async function openEditor(path: string) {
    if (!context.capabilities?.native_ruby_editor || !context.source_model || opening) return;
    const current = epoch.current;
    setOpening(path); setError('');
    try {
      await rpc.call('host/openFile', { source_model: context.source_model, path }, { signal: operations.current.signal });
    } catch (reason) {
      if (current === epoch.current && !operations.current.signal.aborted) setError(String(reason));
    } finally {
      if (current === epoch.current) setOpening('');
    }
  }

  const flat: { entry: Entry; depth: number }[] = [];
  function visit(path: string, depth: number) {
    for (const entry of entries[path] ?? []) {
      flat.push({ entry, depth });
      if (entry.directory && expanded.has(entry.path)) visit(entry.path, depth + 1);
    }
  }
  visit('.', 0);
  const start = Math.max(0, Math.floor(scroll / 24) - 8);
  const visible = flat.slice(start, start + 80);

  return <section className="explorer-panel" aria-label="Ruby App Explorer">
    <div className="tool-heading">Ruby App Explorer</div>
    {error && <div role="alert" className="error">{error}</div>}
    {state === 'no-project' && <p className="hint">Open a Mendix project to browse its Ruby representation.</p>}
    {state === 'loading' && <p role="status">Loading Ruby project…</p>}
    {state === 'missing' && <div className="hint"><p>This project has no linked Ruby representation.</p><button onClick={() => void convert()}>Convert to Ruby</button></div>}
    {state === 'converting' && <p role="status">Converting to Ruby… {progress}</p>}
    {root && <>
      <div className="project-path" title={root}>{root.split('/').pop()}</div>
      <div ref={tree} className="file-tree" role="tree" aria-label="Ruby files" onScroll={event => setScroll(event.currentTarget.scrollTop)}>
        <div style={{ height: flat.length * 24, position: 'relative' }}>
          {visible.map(({ entry, depth }, offset) => <button key={entry.path} role="treeitem"
            aria-level={depth + 1} aria-expanded={entry.directory ? expanded.has(entry.path) : undefined}
            aria-selected={selected?.path === entry.path} data-path={entry.path}
            className="tree-row" style={{ top: (start + offset) * 24, paddingLeft: 6 + depth * 16 }}
            title={entry.path} onClick={() => void activate(entry)}
            onDoubleClick={() => { if (!entry.directory) void openEditor(entry.path); }}
            onKeyDown={event => {
              const index = start + offset;
              const next = event.key === 'ArrowDown' ? index + 1 : event.key === 'ArrowUp' ? index - 1 : -1;
              if (next >= 0 && next < flat.length) {
                event.preventDefault(); tree.current?.scrollTo({ top: Math.max(0, (next - 3) * 24) });
                requestAnimationFrame(() => tree.current?.querySelector<HTMLButtonElement>(`[data-path="${CSS.escape(flat[next].entry.path)}"]`)?.focus());
              }
              if ((event.key === 'ArrowRight' && entry.directory && !expanded.has(entry.path)) ||
                  (event.key === 'ArrowLeft' && entry.directory && expanded.has(entry.path))) {
                event.preventDefault(); void activate(entry);
              }
            }}><span aria-hidden="true">{entry.directory ? expanded.has(entry.path) ? '▾' : '▸' : '·'}</span><span>{entry.name}</span></button>)}
        </div>
      </div>
      {flat.length === 0 && <p className="hint">No files in this Ruby project.</p>}
    </>}
    {selected && <section className="file-preview" aria-label="Ruby preview">
      <div className="tool-heading" title={selected.path}>{selected.path} <span>Ruby · read-only preview</span></div>
      {context.capabilities?.native_ruby_editor && <button className="open-editor" disabled={!!opening}
        onClick={() => void openEditor(selected.path)}>{opening ? 'Opening editor…' : 'Open in editor'}</button>}
      <pre tabIndex={0}>{selected.text}</pre>
    </section>}
  </section>;
}
