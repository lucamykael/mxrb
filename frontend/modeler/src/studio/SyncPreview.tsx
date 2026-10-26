import { useEffect, useRef, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { StudioContext } from './types';

type Change = { op: string; key?: string; element?: unknown; before?: unknown; after?: unknown };
type Unit = { unit_id: string; name?: string; type?: string; action: string; changes: Change[] };
type Preview = {
  state: 'ready' | 'stale' | 'missing_project' | 'unavailable';
  source_model: string; root?: string; applied: false;
  units: Unit[]; limitations: string[]; message?: string;
  validation?: unknown;
};

/** A comparison of saved files. No apply action until the host coordinates native writes. */
export function SyncPreview({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [expanded, setExpanded] = useState(false);
  const [running, setRunning] = useState(false);
  const [result, setResult] = useState<Preview>();
  const [status, setStatus] = useState('');
  const [error, setError] = useState('');
  const active = useRef<AbortController | null>(null);

  useEffect(() => {
    active.current?.abort(); active.current = null;
    setResult(undefined); setStatus(''); setError(''); setRunning(false);
    return () => { active.current?.abort(); active.current = null; };
  }, [rpc, context.source_model, context.ruby_root, context.project_revision]);

  function stop() {
    active.current?.abort(); active.current = null;
    setRunning(false); setStatus('Preview stopped.');
  }

  async function preview() {
    if (!context.source_model || active.current) return;
    const controller = new AbortController(); active.current = controller;
    setExpanded(true); setRunning(true); setError(''); setResult(undefined); setStatus('Preparing preview…');
    try {
      const comparison = await rpc.call<Preview>('sync/preview', { source_model: context.source_model }, {
        signal: controller.signal,
        progress: update => {
          if (active.current === controller && !controller.signal.aborted && update.detail) setStatus(String(update.detail));
        },
      });
      if (active.current !== controller || controller.signal.aborted) return;
      if (comparison.source_model !== context.source_model || comparison.applied !== false)
        throw new Error('Unexpected preview response. Refresh the project and try again.');
      setResult(comparison);
      setStatus(comparison.state === 'ready' ? `${comparison.units.length} changed document${comparison.units.length === 1 ? '' : 's'} in the generated model.`
        : comparison.state === 'stale' ? 'Files changed during preview. Refresh before reviewing the differences.'
        : comparison.state === 'missing_project' ? 'Convert or link this project in Ruby App Explorer first.'
        : 'Preview is unavailable.');
    } catch (reason) {
      if (active.current === controller && !controller.signal.aborted) { setError(String(reason)); setStatus('Preview failed.'); }
    } finally {
      if (active.current === controller) { active.current = null; setRunning(false); }
    }
  }

  return <section className="sync-preview" aria-label="Ruby changes preview">
    <div className="task-actions">
      <button type="button" onClick={() => void preview()} disabled={!context.source_model || running}>Preview Ruby changes</button>
      {running && <button type="button" onClick={stop}>Stop preview</button>}
      {expanded && !running && <button type="button" onClick={() => setExpanded(false)}>Hide preview</button>}
      {!expanded && result && <button type="button" onClick={() => setExpanded(true)}>Show preview</button>}
    </div>
    {expanded && <div className="sync-preview-result">
      <p>Compares the saved Mendix model with the model generated from saved Ruby files. Unsaved edits are excluded. No changes are applied.</p>
      <p role="status">{status}</p>
      {error && <p role="alert" className="error">{error}</p>}
      {result?.message && <p className="error">{result.message}</p>}
      {result?.root && <p className="sync-source" title={result.root}>Ruby project: {result.root}</p>}
      {result?.state === 'ready' && result.units.length === 0 && <p>No differences found in this comparison.</p>}
      {result?.state === 'ready' && result.units.map(unit => <details className="sync-unit" key={unit.unit_id}>
        <summary>{unit.action}: {unit.name || unit.type || unit.unit_id}</summary>
        <p>{unit.type} · {unit.unit_id}</p>
        {unit.changes.map((change, index) => <details key={index}>
          <summary>{change.op}{change.key ? ` ${change.key}` : ''}</summary>
          <div className="sync-values"><div><strong>Saved model</strong><pre>{JSON.stringify(change.before, null, 2) ?? '(absent)'}</pre></div>
            <div><strong>Generated model</strong><pre>{JSON.stringify(change.after, null, 2) ?? '(absent)'}</pre></div></div>
        </details>)}
      </details>)}
      {result?.validation !== undefined && <details><summary>Generated model validation</summary><pre>{JSON.stringify(result.validation, null, 2)}</pre></details>}
      {result && <details><summary>Comparison limits</summary><ul>{result.limitations.map(item => <li key={item}>{item}</li>)}</ul></details>}
    </div>}
  </section>;
}
