import { useEffect, useRef, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { Entry, ProjectStatus, StudioContext } from './types';
import { ContextMenu, Icon, ToolButton, Toolbar, errorText, useDialogs } from './ui';
import type { MenuItem } from './ui';
import { childPath, forget, moveExpansion, parentOf, targetFolder, validateName } from './explorerOperations';
import { Worktrees } from './Worktrees';

export function Explorer({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [root, setRoot] = useState(context.ruby_root);
  const [state, setState] = useState(context.ruby_root ? 'ready' : 'loading');
  const [entries, setEntries] = useState<Record<string, Entry[]>>({});
  const [expanded, setExpanded] = useState(new Set(['.']));
  const [selected, setSelected] = useState<string>();
  const [error, setError] = useState('');
  const [progress, setProgress] = useState('');
  const [scroll, setScroll] = useState(0);
  const [opening, setOpening] = useState('');
  const epoch = useRef(0);
  const operations = useRef(new AbortController());
  const openingRequest = useRef(false);
  const tree = useRef<HTMLDivElement>(null);
  const [menu, setMenu] = useState<{ x: number; y: number; entry?: Entry }>();
  const [busy, setBusy] = useState(false);
  const [reveal, setReveal] = useState<string>();
  const dialogs = useDialogs(rpc, context);

  useEffect(() => {
    const current = ++epoch.current;
    const controller = new AbortController();
    operations.current = controller;
    setRoot(undefined);
    setSelected(undefined); setEntries({}); setExpanded(new Set(['.'])); setError(''); setOpening('');
    setScroll(0); openingRequest.current = false;
    tree.current?.scrollTo({ top: 0 });
    if (context.ruby_root) { setRoot(context.ruby_root); setState('ready'); }
    else if (context.source_model) {
      setState('loading');
      rpc.call<ProjectStatus>('project/status', { source_model: context.source_model }, { signal: controller.signal })
        .then(status => { if (current === epoch.current) { setRoot(status.root ?? undefined); setState(status.state); } })
        .catch(reason => { if (!controller.signal.aborted) { setError(String(reason)); setState('error'); } });
    } else { setRoot(undefined); setState('no-project'); }
    return () => { ++epoch.current; controller.abort(); };
  }, [rpc, context.source_model, context.ruby_root, context.project_revision]);

  useEffect(() => {
    if (!root) return;
    const controller = new AbortController();
    rpc.call<Entry[]>('files/list', { root }, { signal: controller.signal })
      .then(items => { if (!controller.signal.aborted) setEntries({ '.': items }); })
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
      // Other panels (Ruby Sync) and native editors show the new representation's state.
      rpc.call('host/sync/changed', {}).catch(() => undefined);
    } catch (reason) { if (current === epoch.current) { setError(String(reason)); setState('missing'); } }
  }

  async function activate(entry: Entry) {
    const current = epoch.current;
    setSelected(entry.path);
    if (entry.directory) {
      setExpanded(previous => { const next = new Set(previous); if (next.has(entry.path)) next.delete(entry.path); else next.add(entry.path); return next; });
      if (!entries[entry.path]) {
        try {
          const items = await rpc.call<Entry[]>('files/list', { root, path: entry.path }, { signal: operations.current.signal });
          if (current === epoch.current) setEntries(previous => ({ ...previous, [entry.path]: items }));
        } catch (reason) { if (current === epoch.current) setError(String(reason)); }
      }
    }
  }

  async function openEditor(path: string) {
    if (openingRequest.current) return;
    if (!context.capabilities?.native_ruby_editor || !context.source_model) {
      setError('Open this file in Studio Pro with the Ruby editor enabled.'); return;
    }
    const current = epoch.current;
    openingRequest.current = true;
    setOpening(path); setError('');
    try {
      await rpc.call('host/openFile', { source_model: context.source_model, root, path }, { signal: operations.current.signal });
    } catch (reason) {
      if (current === epoch.current && !operations.current.signal.aborted) setError(String(reason));
    } finally {
      if (current === epoch.current) { openingRequest.current = false; setOpening(''); }
    }
  }

  async function reload(folder: string) {
    const items = await rpc.call<Entry[]>('files/list', { root, path: folder }, { signal: operations.current.signal });
    setEntries(previous => ({ ...previous, [folder]: items }));
    return items;
  }

  function entryAt(path: string | undefined) {
    if (!path) return undefined;
    return entries[parentOf(path)]?.find(item => item.path === path);
  }

  async function operate(action: () => Promise<void>) {
    if (busy || !root) return;
    const current = epoch.current;
    setBusy(true); setError('');
    try { await action(); }
    catch (reason) { if (current === epoch.current) setError(errorText(reason)); }
    finally { if (current === epoch.current) setBusy(false); }
  }

  const create = (directory: boolean, at?: Entry) => operate(async () => {
    const folder = targetFolder(at ?? entryAt(selected));
    const answer = await dialogs.show({ kind: 'prompt', title: directory ? 'Add folder' : 'Add file',
      label: 'Name', value: directory ? 'new_folder' : 'new_file.rb' });
    if (answer.button === null || answer.value === undefined) return;
    const problem = validateName(answer.value);
    if (problem) throw new Error(problem);
    const path = childPath(folder, answer.value.trim());
    await rpc.call('files/create', { root, path, directory, text: '' }, { signal: operations.current.signal });
    await reload(folder);
    setExpanded(previous => new Set(previous).add(folder));
    setSelected(path); setReveal(path);
    if (!directory && context.capabilities?.native_ruby_editor) await openEditor(path);
  });

  const rename = (entry: Entry) => operate(async () => {
    const answer = await dialogs.show({ kind: 'prompt', title: 'Rename', label: 'Name', value: entry.name });
    if (answer.button === null || answer.value === undefined || answer.value.trim() === entry.name) return;
    const problem = validateName(answer.value);
    if (problem) throw new Error(problem);
    const folder = parentOf(entry.path);
    const destination = childPath(folder, answer.value.trim());
    await rpc.call('files/move', { root, path: entry.path, destination }, { signal: operations.current.signal });
    const moved = moveExpansion(expanded, entry.path, destination);
    const cleared = forget(entries, moved, entry.path);
    setEntries(cleared.entries);
    setExpanded(entry.directory ? moved : cleared.expanded);
    await reload(folder);
    for (const key of moved) if (key !== '.' && (key === destination || key.startsWith(`${destination}/`))) await reload(key);
    setSelected(destination); setReveal(destination);
  });

  const remove = (entry: Entry) => operate(async () => {
    const answer = await dialogs.show({ kind: 'confirm', title: 'Warning', warning: true, buttons: ['Delete', 'Cancel'],
      message: entry.directory
        ? `Are you sure you want to delete the folder '${entry.path}' and everything in it? You cannot undo this.`
        : `Are you sure you want to delete '${entry.path}'? You cannot undo this.` });
    if (answer.button !== 'Delete') return;
    await rpc.call('files/delete', { root, path: entry.path, recursive: entry.directory }, { signal: operations.current.signal });
    const cleared = forget(entries, expanded, entry.path);
    setEntries(cleared.entries); setExpanded(cleared.expanded);
    await reload(parentOf(entry.path));
    setSelected(undefined);
  });

  const refresh = () => operate(async () => {
    const folders = ['.', ...[...expanded].filter(folder => folder !== '.')];
    setEntries({});
    for (const folder of folders) {
      try { await reload(folder); }
      catch { setExpanded(previous => { const next = new Set(previous); next.delete(folder); return next; }); }
    }
  });

  function menuItems(entry?: Entry): MenuItem[] {
    const items: MenuItem[] = [];
    if (entry && !entry.directory) items.push({ label: 'Open', shortcut: 'Enter', action: () => void openEditor(entry.path) }, 'separator');
    items.push({ label: 'Add file…', action: () => void create(false, entry) },
      { label: 'Add folder…', action: () => void create(true, entry) });
    if (entry) items.push('separator', { label: 'Rename…', shortcut: 'F2', action: () => void rename(entry) },
      { label: 'Delete', shortcut: 'Del', action: () => void remove(entry) });
    items.push('separator', { label: 'Refresh', action: () => void refresh() });
    return items;
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
  const revealIndex = reveal ? flat.findIndex(item => item.entry.path === reveal) : -1;
  useEffect(() => {
    // Like App Explorer, a created or renamed item is scrolled into view in the virtualized tree.
    if (revealIndex < 0 || !tree.current) return;
    const top = revealIndex * 24, view = tree.current;
    if (top < view.scrollTop || top + 24 > view.scrollTop + view.clientHeight) view.scrollTo({ top: Math.max(0, top - view.clientHeight / 2) });
    setReveal(undefined);
  }, [revealIndex]);
  const visible = flat.slice(start, start + 80);

  return <section className="explorer-panel" aria-label="Ruby App Explorer">
    {root && <Toolbar label="Ruby App Explorer actions">
      <ToolButton icon="newFile" label="Add file…" onClick={() => void create(false)} disabled={busy} />
      <ToolButton icon="newFolder" label="Add folder…" onClick={() => void create(true)} disabled={busy} />
      <ToolButton icon="rename" label="Rename… (F2)" onClick={() => { const entry = entryAt(selected); if (entry) void rename(entry); }}
        disabled={busy || !entryAt(selected)} />
      <ToolButton icon="delete" label="Delete (Del)" onClick={() => { const entry = entryAt(selected); if (entry) void remove(entry); }}
        disabled={busy || !entryAt(selected)} />
      <span className="mx-spacer" />
      <ToolButton icon="refresh" label="Refresh" onClick={() => void refresh()} disabled={busy} />
    </Toolbar>}
    {error && <div role="alert" className="error">{error}</div>}
    {state === 'no-project' && <p className="hint">Open a Mendix project to browse its Ruby representation.</p>}
    {state === 'loading' && <p role="status">Loading Ruby project…</p>}
    {state === 'missing' && <div className="hint"><p>This project has no linked Ruby representation.</p><button onClick={() => void convert()}>Convert to Ruby</button></div>}
    {state === 'converting' && <p role="status">Converting to Ruby… {progress}</p>}
    {root && <>
      <div className="project-path" title={root}>{root.split('/').pop()}</div>
      <div ref={tree} className="file-tree" role="tree" aria-label="Ruby files" onScroll={event => setScroll(event.currentTarget.scrollTop)}
        onContextMenu={event => { if (event.target === event.currentTarget || (event.target as HTMLElement).parentElement === event.currentTarget) {
          event.preventDefault(); setSelected(undefined); setMenu({ x: event.clientX, y: event.clientY }); } }}>
        <div style={{ height: flat.length * 24, position: 'relative' }}>
          {visible.map(({ entry, depth }, offset) => <button key={entry.path} role="treeitem"
            aria-level={depth + 1} aria-expanded={entry.directory ? expanded.has(entry.path) : undefined}
            aria-selected={selected === entry.path} data-path={entry.path}
            className="tree-row" style={{ top: (start + offset) * 24, paddingLeft: 6 + depth * 16 }}
            title={entry.path} onClick={() => void activate(entry)}
            onDoubleClick={() => { if (!entry.directory) void openEditor(entry.path); }}
            onContextMenu={event => { event.preventDefault(); event.stopPropagation(); setSelected(entry.path); setMenu({ x: event.clientX, y: event.clientY, entry }); }}
            onKeyDown={event => {
              if (event.key === 'F2') { event.preventDefault(); void rename(entry); return; }
              if (event.key === 'Delete') { event.preventDefault(); void remove(entry); return; }
              if (event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey)) {
                event.preventDefault(); const box = event.currentTarget.getBoundingClientRect();
                setMenu({ x: box.left + 24, y: box.bottom, entry }); return;
              }
              if (event.key === 'Enter' && !entry.directory) {
                event.preventDefault(); setSelected(entry.path); void openEditor(entry.path); return;
              }
              const index = start + offset;
              const next = event.key === 'ArrowDown' ? index + 1 : event.key === 'ArrowUp' ? index - 1 : -1;
              if (next >= 0 && next < flat.length) {
                event.preventDefault(); tree.current?.scrollTo({ top: Math.max(0, (next - 3) * 24) });
                setSelected(flat[next].entry.path);
                requestAnimationFrame(() => tree.current?.querySelector<HTMLButtonElement>(`[data-path="${CSS.escape(flat[next].entry.path)}"]`)?.focus());
              }
              if ((event.key === 'ArrowRight' && entry.directory && !expanded.has(entry.path)) ||
                  (event.key === 'ArrowLeft' && entry.directory && expanded.has(entry.path))) {
                event.preventDefault(); void activate(entry);
              }
            }}><span className="mx-chevron" aria-hidden="true">{entry.directory ? <svg viewBox="0 0 16 16" width="12" height="12">
              <path d={expanded.has(entry.path) ? 'M4 6l4 4 4-4' : 'M6 4l4 4-4 4'} fill="none" stroke="currentColor" strokeWidth="1.2" /></svg> : null}</span>
              <Icon name={entry.directory ? 'folder' : entry.name.endsWith('.rb') ? 'ruby' : 'file'} /><span>{entry.name}</span></button>)}
        </div>
      </div>
      {flat.length === 0 && <p className="hint">No files in this Ruby project.</p>}
      <Worktrees rpc={rpc} context={context} root={root} signal={operations.current.signal}
        onSwitched={next => { setRoot(next); setEntries({}); setExpanded(new Set(['.'])); setSelected(undefined); }} />
    </>}
    {menu && <ContextMenu x={menu.x} y={menu.y} items={menuItems(menu.entry)} onClose={() => setMenu(undefined)} />}
    {dialogs.element}
    {opening && <p role="status">Opening {opening}…</p>}
  </section>;
}
