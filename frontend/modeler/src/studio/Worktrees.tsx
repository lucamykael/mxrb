import { useEffect, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { ProjectStatus, StudioContext } from './types';
import { ToolButton, Toolbar, errorText, useDialogs } from './ui';
import { validateName, worktreePath } from './explorerOperations';

export type Worktree = { path: string; branch?: string; head?: string; detached: boolean; current: boolean };

const branchLabel = (worktree: Worktree) =>
  worktree.detached ? `detached ${worktree.head?.slice(0, 8) ?? ''}` : (worktree.branch ?? '').replace(/^refs\/heads\//, '');

/**
 * Git worktrees of the linked Ruby project. Switching links this Mendix project
 * to another worktree of the same Ruby project (the backend checks identity).
 */
export function Worktrees({ rpc, context, root, onSwitched, signal }: {
  rpc: StudioRpc; context: StudioContext; root: string; signal: AbortSignal; onSwitched(root: string): void;
}) {
  const [open, setOpen] = useState(false);
  const [items, setItems] = useState<Worktree[]>();
  const [selected, setSelected] = useState<string>();
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const dialogs = useDialogs(rpc, context);

  async function load() {
    try {
      const list = await rpc.call<Worktree[]>('files/worktrees', { root }, { signal });
      if (!signal.aborted) setItems(list);
    } catch (reason) { if (!signal.aborted) setError(errorText(reason)); }
  }
  useEffect(() => { setItems(undefined); setSelected(undefined); setError(''); if (open) void load(); },
    [root, open]);

  async function run(label: string, action: () => Promise<void>) {
    setBusy(label); setError('');
    try { await action(); } catch (reason) { if (!signal.aborted) setError(errorText(reason)); }
    finally { if (!signal.aborted) setBusy(''); }
  }

  const add = () => run('Creating worktree…', async () => {
    const answer = await dialogs.show({ kind: 'input', title: 'New worktree', label: 'Branch',
      message: 'Creates a Git worktree next to this Ruby project. An existing branch is checked out; a new name creates the branch from the current commit.',
      value: '' });
    if (answer.button === null || !answer.value) return;
    const problem = validateName(answer.value.replace(/\//g, '-'));
    if (problem) throw new Error(problem);
    const path = worktreePath(root, answer.value);
    const created = await rpc.call<Worktree>('files/worktreeAdd', { root, path, branch: answer.value.trim() }, { signal });
    await load(); setSelected(created.path);
  });

  const remove = (worktree: Worktree) => run('Removing worktree…', async () => {
    const answer = await dialogs.show({ kind: 'confirm', title: 'Warning', warning: true, buttons: ['Remove', 'Cancel'],
      message: `Remove the worktree '${worktree.path}'? Git keeps the branch '${branchLabel(worktree)}'. A worktree with uncommitted changes is not removed.` });
    if (answer.button !== 'Remove') return;
    await rpc.call('files/worktreeRemove', { root, path: worktree.path }, { signal });
    await load(); setSelected(undefined);
  });

  const switchTo = (worktree: Worktree) => run('Switching worktree…', async () => {
    if (!context.source_model) throw new Error('Open the Mendix project first.');
    const status = await rpc.call<ProjectStatus>('project/attach', { source_model: context.source_model, root: worktree.path }, { signal });
    if (status.root) onSwitched(status.root);
  });

  const chosen = items?.find(item => item.path === selected);
  return <div className="mx-worktrees">
    <button type="button" className="mx-section-header" aria-expanded={open} onClick={() => setOpen(!open)}>
      <span className="mx-twisty" aria-hidden="true">{open ? '▾' : '▸'}</span>Worktrees</button>
    {open && <>
      <Toolbar label="Worktree actions">
        <ToolButton icon="branch" label="New worktree…" onClick={() => void add()} disabled={!!busy || items?.length === 0} />
        <ToolButton icon="connect" label="Switch Ruby App Explorer to the selected worktree"
          onClick={() => chosen && void switchTo(chosen)} disabled={!!busy || !chosen || chosen.current} />
        <ToolButton icon="delete" label="Remove worktree…" onClick={() => chosen && void remove(chosen)}
          disabled={!!busy || !chosen || chosen.current || chosen === items?.[0]} />
        <ToolButton icon="refresh" label="Refresh worktrees" onClick={() => void load()} disabled={!!busy} />
      </Toolbar>
      <div className="mx-worktree-list" role="listbox" aria-label="Worktrees">
        {items?.map(item => <div key={item.path} role="option" tabIndex={0} aria-selected={selected === item.path}
          className="mx-tree-row" title={item.path} data-worktree={item.path}
          onClick={() => setSelected(item.path)} onDoubleClick={() => { if (!item.current) void switchTo(item); }}
          onKeyDown={event => { if (event.key === 'Enter' && !item.current) void switchTo(item); }}>
          <span className="mx-twisty" aria-hidden="true">{item.current ? '●' : ''}</span>
          <span><b>{branchLabel(item) || '(no branch)'}</b> <span className="mx-muted">{item.path.split('/').pop()}</span>
            {item.current && <span className="mx-muted"> · current</span>}</span>
        </div>)}
        {items?.length === 0 && <p className="mx-empty">This Ruby project is not in a Git repository.</p>}
      </div>
      {busy && <p role="status" className="mx-empty">{busy}</p>}
      {error && <p role="alert" className="error">{error}</p>}
    </>}
    {dialogs.element}
  </div>;
}
