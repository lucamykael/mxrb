import { useEffect, useMemo, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { StudioContext } from './types';
import { ToolButton, Toolbar, errorText } from './ui';

type Row = { id: string; family: string; capability: string; studio_pro: string; mxrb: string[];
  states: Record<string, string>; gaps: string[]; evidence?: string[] };
type Matrix = { studio_pro_baseline: string; policy: string[]; states: Record<string, string>;
  ide_surfaces?: Record<string, { state: string; scope: string }>;
  studio_pro_to_mxrb: Row[]; mxrb_to_studio_pro: Row[] };

const DIRECTIONS = [['studio_pro_to_mxrb', 'Studio Pro → MXRB'], ['mxrb_to_studio_pro', 'MXRB → Studio Pro']] as const;
const COLUMNS: Record<string, [string, string][]> = {
  studio_pro_to_mxrb: [['ruby_api', 'Ruby API'], ['ruby_dsl', 'DSL'], ['ide', 'IDE'], ['typed_editing', 'Typed editing'],
    ['semantic_equivalence', 'Equivalence'], ['runtime_behavior', 'Runtime'], ['independent_of_studio_backend', 'Independent']],
  mxrb_to_studio_pro: [['ruby_api', 'Ruby API'], ['ide', 'IDE'], ['independent_of_studio_backend', 'Independent']]
};
const GOOD = new Set(['implemented_tested_scope', 'accepted_integrated_studio', 'validated_scope', 'yes']);
const PARTIAL = new Set(['partial', 'source_present_coverage_unassessed', 'implemented_unaccepted', 'accepted_harness', 'task_catalog']);
const BAD = new Set(['missing', 'no', 'original_backend']);

export function stateTone(state: string) {
  return GOOD.has(state) ? 'good' : PARTIAL.has(state) ? 'partial' : BAD.has(state) ? 'bad' : 'neutral';
}

/** Read-only parity matrix in both directions. States are per capability; nothing is summed into a percentage. */
export function Parity({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [matrix, setMatrix] = useState<Matrix>();
  const [error, setError] = useState('');
  const [direction, setDirection] = useState<'studio_pro_to_mxrb' | 'mxrb_to_studio_pro'>('studio_pro_to_mxrb');
  const [family, setFamily] = useState('');
  const [state, setState] = useState('');
  const [search, setSearch] = useState('');
  const [selected, setSelected] = useState<string>();
  const [reload, setReload] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    setError('');
    rpc.call<Matrix>('parity/matrix', {}, { signal: controller.signal }).then(setMatrix)
      .catch(reason => { if (!controller.signal.aborted) setError(errorText(reason)); });
    return () => controller.abort();
  }, [rpc, reload, context.project_revision]);

  const rows = useMemo(() => matrix?.[direction] ?? [], [matrix, direction]);
  const families = useMemo(() => [...new Set(rows.map(row => row.family))].sort(), [rows]);
  const states = useMemo(() => [...new Set(rows.flatMap(row => Object.values(row.states)))].sort(), [rows]);
  const needle = search.trim().toLowerCase();
  const visible = rows.filter(row => (!family || row.family === family) && (!state || Object.values(row.states).includes(state))
    && (!needle || `${row.id} ${row.capability} ${row.studio_pro} ${row.mxrb.join(' ')}`.toLowerCase().includes(needle)));
  const columns = COLUMNS[direction];
  const detail = rows.find(row => row.id === selected);

  return <section className="mx-panel parity-panel" aria-label="MXRB parity">
    <Toolbar label="Parity filters">
      {DIRECTIONS.map(([key, label]) => <button key={key} type="button" className="mx-tool" aria-pressed={direction === key}
        onClick={() => { setDirection(key); setFamily(''); setState(''); setSelected(undefined); }}>{label}</button>)}
      <span className="mx-separator" />
      <select aria-label="Family" value={family} onChange={event => setFamily(event.target.value)}>
        <option value="">All families</option>{families.map(name => <option key={name}>{name}</option>)}</select>
      <select aria-label="State" value={state} onChange={event => setState(event.target.value)}>
        <option value="">Any state</option>{states.map(name => <option key={name}>{name}</option>)}</select>
      <input type="search" aria-label="Search capabilities" placeholder="Search" value={search} onChange={event => setSearch(event.target.value)} />
      <span className="mx-spacer" />
      <ToolButton icon="refresh" label="Refresh" onClick={() => setReload(reload + 1)} />
    </Toolbar>
    {error && <p role="alert" className="error">{error}</p>}
    {!matrix && !error && <p role="status" className="mx-empty">Loading parity matrix…</p>}
    {matrix && <div className="mx-fill parity-grid">
      <table className="mx-grid">
        <thead><tr><th>Capability</th><th>{direction === 'studio_pro_to_mxrb' ? 'Studio Pro' : 'IDE surface'}</th>
          <th>MXRB</th>{columns.map(([, label]) => <th key={label}>{label}</th>)}</tr></thead>
        <tbody>{visible.map(row => <tr key={row.id} aria-selected={selected === row.id} data-capability={row.id}
          onClick={() => setSelected(row.id)}>
          <td><span className="parity-capability">{row.capability}</span><br /><span className="mx-muted">{row.family}</span></td>
          <td>{row.studio_pro}</td>
          <td>{row.mxrb.length ? row.mxrb.join('; ') : <span className="mx-muted">none</span>}</td>
          {columns.map(([key]) => <td key={key}>{row.states[key]
            ? <span className={`mx-badge mx-state-${stateTone(row.states[key])}`} title={matrix.states[row.states[key]] ?? row.states[key]}>
              {row.states[key].replaceAll('_', ' ')}</span> : <span className="mx-muted">—</span>}</td>)}
        </tr>)}</tbody>
      </table>
      {visible.length === 0 && <p className="mx-empty">No capability matches these filters.</p>}
    </div>}
    {detail && <div className="parity-detail" aria-label="Capability details">
      <b>{detail.capability}</b> <span className="mx-muted">{detail.id}</span>
      {detail.gaps.length > 0 && <ul>{detail.gaps.map(gap => <li key={gap}>{gap}</li>)}</ul>}
      {detail.evidence && detail.evidence.length > 0 && <p className="mx-muted">Evidence: {detail.evidence.join(', ')}</p>}
      {detail.gaps.length === 0 && !detail.evidence?.length && <p className="mx-muted">No gaps recorded.</p>}
    </div>}
    {matrix && <div className="mx-status-bar">
      <span>Studio Pro {matrix.studio_pro_baseline} baseline</span>
      <span>{visible.length} of {rows.length} capabilities shown</span>
      <span title={matrix.policy.join('\n')}>States are per capability and are not combined into a completion score.</span>
    </div>}
  </section>;
}
