import { useCallback, useEffect, useRef, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { StudioContext } from './types';
import {
  applyParameters, CHANGE_LABELS, conflictTitle, display, documentName, readiness, rubyProject, STATE_LABELS, typeName,
  type ApplyResult, type Comparison, type Conflict, type Diagnostic, type Resolution, type SyncDocument, type SyncStatus,
} from './syncModel';

type Phase = 'loading' | 'unconverted' | 'ready' | 'error';

/**
 * Ruby Sync tool window: what changed on each side since the last synchronization, the comparison of
 * both edits of the same element, the choice per conflict and the coordinated apply (performed by the
 * IDE, which locks and reloads the model).
 */
export function SyncPanel({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [phase, setPhase] = useState<Phase>('loading');
  const [status, setStatus] = useState<SyncStatus>();
  const [comparison, setComparison] = useState<Comparison>();
  const [choices, setChoices] = useState<Record<string, Resolution>>({});
  const [selected, setSelected] = useState<string>();
  const [busy, setBusy] = useState('');
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');
  const [diagnostics, setDiagnostics] = useState<Diagnostic[]>([]);
  const lifetime = useRef(new AbortController());
  const work = useRef<AbortController | null>(null);
  const loads = useRef(0);

  const load = useCallback(async () => {
    const current = ++loads.current;
    const signal = lifetime.current.signal;
    try {
      const root = await rubyProject(rpc, context, signal);
      if (current !== loads.current) return;
      if (!root) { setPhase(context.source_model ? 'unconverted' : 'error'); setStatus(undefined); return; }
      const next = await rpc.call<SyncStatus>('sync/status', { source_model: context.source_model }, { signal });
      if (current !== loads.current) return;
      setStatus(next); setPhase('ready'); setError('');
    } catch (reason) {
      if (!signal.aborted && current === loads.current) { setError(String(reason)); setPhase('error'); }
    }
  }, [rpc, context]);

  useEffect(() => {
    lifetime.current.abort();
    lifetime.current = new AbortController();
    work.current = null;
    setStatus(undefined); setComparison(undefined); setChoices({}); setSelected(undefined);
    setBusy(''); setMessage(''); setError(''); setDiagnostics([]); setPhase('loading');
    void load();
    const unsubscribe = rpc.subscribe(method => { if (method === 'host/syncChanged') void load(); });
    return () => { unsubscribe(); lifetime.current.abort(); };
  }, [rpc, context, load]);

  async function run<T>(label: string, action: (signal: AbortSignal) => Promise<T>) {
    if (work.current) return undefined;
    const controller = new AbortController();
    work.current = controller;
    const stopWithPanel = () => controller.abort();
    lifetime.current.signal.addEventListener('abort', stopWithPanel, { once: true });
    setBusy(label); setError(''); setMessage(''); setDiagnostics([]);
    try { return await action(controller.signal); }
    catch (reason) {
      if (!controller.signal.aborted) {
        const details = (reason as { details?: { locations?: Diagnostic[] } }).details;
        setDiagnostics(details?.locations ?? []);
        setError(reason instanceof Error ? reason.message : String(reason));
      }
      return undefined;
    } finally {
      lifetime.current.signal.removeEventListener('abort', stopWithPanel);
      if (work.current === controller) { work.current = null; setBusy(''); }
    }
  }

  async function link() {
    await run('Linking the Ruby project…', async signal => {
      await rpc.call('sync/link', { source_model: context.source_model }, { signal });
      setMessage('The current model and Ruby files are now the synchronization base.');
      await rpc.call('host/sync/changed', {}, { signal });
      await load();
    });
  }

  async function compare() {
    await run('Comparing Ruby and Mendix…', async signal => {
      const result = await rpc.call<Comparison>('sync/run', { source_model: context.source_model, dry_run: true }, {
        signal, progress: update => { if (update.detail) setBusy(`Comparing: ${String(update.detail)}`); },
      });
      setComparison(result);
      setChoices(previous => Object.fromEntries(result.conflicts.filter(item => previous[item.id]).map(item => [item.id, previous[item.id]])));
      setSelected(result.conflicts[0]?.id);
      setMessage(result.conflicts.length ? `${result.conflicts.length} conflict${result.conflicts.length === 1 ? '' : 's'}: choose which side to keep for each.`
        : `Ready to apply: ${result.ruby_units.length} Ruby document change${result.ruby_units.length === 1 ? '' : 's'} to the model, `
          + `${result.files.length} Ruby file update${result.files.length === 1 ? '' : 's'} from Studio Pro.`);
      await rpc.call('host/sync/changed', {}, { signal });
    });
  }

  async function apply() {
    if (!comparison) return;
    await run('Applying in Studio Pro…', async signal => {
      const result = await rpc.call<ApplyResult>('host/sync/apply', applyParameters(context, comparison, choices), { signal });
      if (result.applied) {
        setComparison(undefined); setChoices({}); setSelected(undefined);
        setMessage(`Synchronized: ${result.ruby_units.length} document${result.ruby_units.length === 1 ? '' : 's'} updated from Ruby, `
          + `${result.files.length} Ruby file${result.files.length === 1 ? '' : 's'} updated from Studio Pro.`);
      } else {
        setComparison(result);
        setMessage('New conflicts were found while applying. Review them and apply again.');
      }
      await load();
    });
  }

  function openDocument(document: SyncDocument) {
    void run('Opening…', signal => rpc.call('host/openDocument', { source_model: context.source_model, unit_id: document.unit_id }, { signal }));
  }

  function openFile(path: string, line?: number) {
    void run('Opening…', async signal => {
      const root = await rubyProject(rpc, context, signal);
      await rpc.call('host/openFile', { source_model: context.source_model, root, path, ...(line ? { line } : {}) }, { signal });
    });
  }

  const check = readiness(status, comparison, choices);
  const conflict = comparison?.conflicts.find(item => item.id === selected);
  const stateLabel = phase === 'unconverted' ? STATE_LABELS.unconverted
    : status ? (status.linked ? STATE_LABELS[status.state] : STATE_LABELS.unlinked) : '';

  return <section className="sync-panel" aria-label="Ruby Sync">
    <div className="sync-toolbar" role="toolbar" aria-label="Ruby Sync actions">
      <button type="button" onClick={() => void load()} disabled={!!busy}>Refresh</button>
      <button type="button" onClick={() => void compare()} disabled={!!busy || !status?.linked}>Compare</button>
      <button type="button" onClick={() => void apply()} disabled={!!busy || !check.ready} title={check.reason}>Apply</button>
      <span className={`sync-state sync-state-${status?.linked ? status.state : phase}`} role="status">{busy || stateLabel}</span>
    </div>
    {phase === 'loading' && <p role="status">Reading synchronization state…</p>}
    {phase === 'unconverted' && <p className="hint">This app has no Ruby representation. Convert it in Ruby App Explorer.</p>}
    {error && <div role="alert" className="error">{error}{diagnostics.length > 0 && <ul className="sync-diagnostics">
      {diagnostics.map((item, index) => <li key={index}><button type="button" className="link" onClick={() => openFile(item.path ?? item.file ?? '', item.line)}>
        {(item.path ?? item.file)}:{item.line}</button> {item.message}</li>)}</ul>}</div>}
    {message && <p className="sync-message">{message}</p>}
    {status && !status.linked && <div className="sync-unlinked">
      <p>The Ruby project is not linked for synchronization. Linking records the current model and Ruby files as the common base;
        edits made before linking are not applied in either direction.</p>
      <button type="button" onClick={() => void link()} disabled={!!busy}>Link for synchronization</button>
    </div>}
    {status?.linked && <div className="sync-body">
      {!check.ready && comparison && <p className="hint">{check.reason}</p>}
      <table className="sync-grid" aria-label="Changed documents">
        <thead><tr><th>Document</th><th>Type</th><th>Ruby</th><th>Studio Pro</th><th>State</th></tr></thead>
        <tbody>
          {status.documents.length === 0 && <tr><td colSpan={5} className="hint">No changes since the last synchronization.</td></tr>}
          {status.documents.map(document => <tr key={document.unit_id} onDoubleClick={() => openDocument(document)}
            className={`state-${document.state}`}>
            <td><button type="button" className="link" onClick={() => openDocument(document)}>{documentName(document)}</button></td>
            <td>{typeName(document.type)}</td>
            <td>{document.ruby ? <>{CHANGE_LABELS[document.ruby] ?? document.ruby}{document.files.map(file =>
              <button type="button" key={file} className="link file" title={file} onClick={() => openFile(file)}>{file.split('/').pop()}</button>)}</> : ''}</td>
            <td>{document.mendix ? CHANGE_LABELS[document.mendix] ?? document.mendix : ''}</td>
            <td>{STATE_LABELS[document.state]}</td>
          </tr>)}
        </tbody>
      </table>
      {status.ruby_changes.some(change => change.diagnostics.length) && <ul className="sync-diagnostics" aria-label="Ruby errors">
        {status.ruby_changes.flatMap(change => change.diagnostics.map((item, index) => <li key={change.path + index}>
          <button type="button" className="link" onClick={() => openFile(change.path, item.line)}>{change.path}:{item.line}</button> {item.message}</li>))}
      </ul>}
      {comparison && comparison.conflicts.length > 0 && <>
        <h2>Conflicts</h2>
        <table className="sync-grid" aria-label="Conflicts">
          <thead><tr><th>Element</th><th>Studio Pro</th><th>Ruby</th><th>Keep</th></tr></thead>
          <tbody>{comparison.conflicts.map(item => <tr key={item.id} aria-selected={item.id === selected} onClick={() => setSelected(item.id)}>
            <td>{conflictTitle(item)}</td>
            <td className="value">{item.kind === 'element' ? display(item.mendix) : item.kind === 'file' ? `${item.hunks} block${item.hunks === 1 ? '' : 's'}` : item.reason}</td>
            <td className="value">{item.kind === 'element' ? display(item.ruby) : ''}</td>
            <td className="choices"><Choice conflict={item} value={choices[item.id]} onChange={choice => setChoices(previous => ({ ...previous, [item.id]: choice }))} /></td>
          </tr>)}</tbody>
        </table>
        {conflict && <ConflictCompare conflict={conflict} />}
      </>}
    </div>}
  </section>;
}

function Choice({ conflict, value, onChange }: { conflict: Conflict; value?: Resolution; onChange(choice: Resolution): void }) {
  return <span role="radiogroup" aria-label={`Keep for ${conflictTitle(conflict)}`}>
    {(['mendix', 'ruby'] as Resolution[]).filter(choice => conflict.resolutions.includes(choice)).map(choice =>
      <label key={choice}><input type="radio" name={conflict.id} checked={value === choice} onChange={() => onChange(choice)} />
        {choice === 'mendix' ? 'Studio Pro' : 'Ruby'}</label>)}
  </span>;
}

/** Side-by-side comparison of the selected conflict, as in Studio Pro's merge views. */
function ConflictCompare({ conflict }: { conflict: Conflict }) {
  const columns = conflict.kind === 'file'
    ? [['Ruby file (your edits)', display(conflict.ruby)], ['Ruby file with the Studio Pro changes', display(conflict.mendix)]]
    : conflict.kind === 'element'
      ? [['Base', display(conflict.base)], ['Studio Pro', display(conflict.mendix)], ['Ruby', display(conflict.ruby)]]
      : [['Conflict', conflict.reason ?? '']];
  return <div className="sync-compare" aria-label="Conflict comparison">
    <div className="tool-heading">{conflictTitle(conflict)}<span>{conflict.kind === 'element'
      ? `${conflict.mendix_operation} in Studio Pro, ${conflict.ruby_operation} in Ruby` : ''}</span></div>
    <div className="sync-columns" style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(0, 1fr))` }}>
      {columns.map(([title, text]) => <div key={title}><strong>{title}</strong><pre tabIndex={0}>{text}</pre></div>)}
    </div>
  </div>;
}
