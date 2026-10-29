import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { StudioError } from './rpc';
import type { StudioRpc } from './rpc';
import type { StudioContext } from './types';
import { Icon, ToolButton, Toolbar, errorText } from './ui';
import './er.css';

export type Connection = {
  id: string; kind: string; label: string; engine: string; environment: string; environment_label: string;
  host: string; port: number; database: string; user: string; read_only: boolean; running: boolean;
  schema_current?: boolean; error?: { code: string; message: string };
};
type Column = { name: string; ordinal: number; type?: string; nullable?: boolean; default?: string | null; identity?: string };
type Constraint = { name: string; type: string; columns: string[]; definition?: string; target_schema?: string | null;
  target_table?: string | null; target_columns?: string[]; validated?: boolean };
type Index = { name: string; unique?: boolean; primary?: boolean; definition?: string; method?: string;
  columns?: { name: string | null; expression?: string; included?: boolean }[] };
type Table = { id: string; schema: string; name: string; kind: string; columns: Column[]; constraints: Constraint[];
  primary_key?: Constraint | null; foreign_keys: Constraint[]; indexes: Index[] };
type Physical = { status: string; confirmed?: boolean; tables: Table[]; error?: { code: string; message: string };
  connection?: Connection };
type QueryResult = { ok: boolean; rows?: Record<string, unknown>[]; row_count?: number; elapsed_ms?: number;
  warnings?: string[]; error?: { code: string; message: string }; connection?: Connection; sql?: string };
type PlanNode = Record<string, unknown> & { Plans?: PlanNode[] };
type Finding = { rule: string; severity: string; node_type?: string; relation?: string; message: string; suggestion?: string };
type ExplainResult = { ok: boolean; analyzed?: boolean; warnings?: string[]; error?: { code: string; message: string }; sql?: string;
  plan?: { planning_time_ms?: number | null; execution_time_ms?: number | null; total_cost?: number | null;
    findings?: Finding[]; raw?: { Plan?: PlanNode }[] };
  connection?: Connection };

const ROW_LIMIT = 500;

/** Parses a parameter value as JSON when it is valid JSON, otherwise keeps it as text. */
export function parameterValue(text: string): unknown {
  const trimmed = text.trim();
  if (/^(-?\d+(\.\d+)?([eE][+-]?\d+)?|true|false|null|".*"|\{.*\}|\[.*\])$/s.test(trimmed)) {
    try { return JSON.parse(trimmed); } catch { /* text */ }
  }
  return text;
}

export function describe(connection: Connection) {
  return `${connection.host}:${connection.port}/${connection.database} as ${connection.user}`;
}

/**
 * Physical schema, SQL/OQL and plans on a connection the user chose explicitly.
 * Nothing physical appears before a successful introspection of that connection.
 */
export function DatabaseExplorer({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [connections, setConnections] = useState<Connection[]>();
  const [chosen, setChosen] = useState('');
  const [loadError, setLoadError] = useState('');
  const [refresh, setRefresh] = useState(0);
  const [physical, setPhysical] = useState<Physical>();
  const [introspecting, setIntrospecting] = useState(false);
  const [expanded, setExpanded] = useState(new Set<string>());
  const [language, setLanguage] = useState<'sql' | 'oql'>('sql');
  const [texts, setTexts] = useState({ sql: 'SELECT 1 AS one', oql: '' });
  const [parameters, setParameters] = useState<{ name: string; value: string }[]>([]);
  const [analyze, setAnalyze] = useState(false);
  const [running, setRunning] = useState<'' | 'query' | 'explain'>('');
  const [result, setResult] = useState<{ kind: 'query'; data: QueryResult } | { kind: 'explain'; data: ExplainResult }>();
  const [error, setError] = useState('');
  const operations = useRef(new AbortController());

  const base = useMemo(() => ({ model: context.source_model,
    ...(context.database_port ? { database_port: context.database_port } : {}),
    ...(context.database_runtime_port ? { runtime_port: context.database_runtime_port } : {}) }),
  [context.source_model, context.database_port, context.database_runtime_port]);

  useEffect(() => {
    operations.current.abort();
    operations.current = new AbortController();
    setChosen(''); setPhysical(undefined); setResult(undefined); setError(''); setExpanded(new Set()); setRunning('');
    setIntrospecting(false);
  }, [context.source_model, context.project_revision, context.database_port]);

  useEffect(() => {
    const controller = new AbortController();
    setLoadError('');
    if (!context.source_model) { setConnections(undefined); return; }
    setConnections(undefined);
    rpc.call<Connection[]>('data/connections', base, { signal: controller.signal })
      .then(items => { if (!controller.signal.aborted) setConnections(items); })
      .catch(reason => { if (!controller.signal.aborted) setLoadError(errorText(reason)); });
    return () => controller.abort();
  }, [rpc, base, context.source_model, context.project_revision, refresh]);

  useEffect(() => () => operations.current.abort(), []);

  const connection = connections?.find(item => item.id === chosen);

  const choose = (id: string) => {
    operations.current.abort();
    operations.current = new AbortController();
    setChosen(id); setPhysical(undefined); setResult(undefined); setError(''); setExpanded(new Set());
    setRunning(''); setIntrospecting(false);
  };

  const cancel = () => {
    operations.current.abort();
    operations.current = new AbortController();
    setRunning(''); setIntrospecting(false);
  };

  const failed = useCallback((reason: unknown) => {
    if (reason instanceof StudioError && reason.code === -32020) {
      setError(`${reason.message}. Choose the connection again.`);
      setChosen(''); setRefresh(value => value + 1);
    } else setError(errorText(reason));
  }, []);

  async function introspect() {
    if (!connection) return;
    const signal = operations.current.signal;
    setIntrospecting(true); setError('');
    try {
      const value = await rpc.call<Physical>('data/physical', { ...base, connection: { id: connection.id } }, { signal });
      if (!signal.aborted) setPhysical(value);
    } catch (reason) { if (!signal.aborted) failed(reason); }
    finally { if (!signal.aborted) setIntrospecting(false); }
  }

  function payload() {
    const params = Object.fromEntries(parameters.filter(item => item.name.trim())
      .map(item => [item.name.trim().replace(/^[:$]/, ''), parameterValue(item.value)]));
    return { [language]: texts[language], params };
  }

  async function execute(kind: 'query' | 'explain') {
    if (!connection || running || !texts[language].trim()) return;
    const signal = operations.current.signal;
    setRunning(kind); setError('');
    try {
      if (kind === 'query') {
        const data = await rpc.call<QueryResult>('data/query', { ...base, connection: { id: connection.id }, payload: payload() }, { signal });
        if (!signal.aborted) setResult({ kind, data });
      } else {
        const data = await rpc.call<ExplainResult>('data/explain',
          { ...base, connection: { id: connection.id }, payload: { ...payload(), analyze } }, { signal });
        if (!signal.aborted) setResult({ kind, data });
      }
    } catch (reason) { if (!signal.aborted) failed(reason); }
    finally { if (!signal.aborted) setRunning(''); }
  }

  const toggle = (key: string) => setExpanded(previous => {
    const next = new Set(previous);
    if (next.has(key)) next.delete(key); else next.add(key);
    return next;
  });

  return <section className="mx-panel db-panel" aria-label="MXRB Database">
    <Toolbar label="Database">
      <ToolButton icon="refresh" label="Refresh connections" onClick={() => setRefresh(value => value + 1)} disabled={!context.source_model} />
      <span className="mx-separator" />
      <ToolButton icon="database" label="Introspect the physical schema of the chosen connection" text="Introspect schema"
        onClick={() => void introspect()} disabled={!connection?.running || introspecting} />
      <ToolButton icon="run" tone="run" label="Run query (Ctrl+Enter)" text="Run" onClick={() => void execute('query')}
        disabled={!connection?.running || !!running || !texts[language].trim()} />
      <ToolButton icon="explain" label="Explain query plan" text="Explain" onClick={() => void execute('explain')}
        disabled={!connection?.running || !!running || !texts[language].trim()} />
      <ToolButton icon="stop" tone="stop" label="Cancel the running request" onClick={cancel} disabled={!running && !introspecting} />
    </Toolbar>
    {!context.source_model ? <p className="mx-empty">Open a Mendix project to explore its database.</p> : <>
      <div className="db-connection">
        <label htmlFor="db-connection-select">Connection</label>
        <select id="db-connection-select" aria-label="Database connection" value={chosen} disabled={!connections}
          onChange={event => choose(event.target.value)}>
          <option value="">{connections ? 'Choose a connection…' : 'Loading connections…'}</option>
          {connections?.map(item => <option key={item.id} value={item.id}>
            {item.label} — {item.environment_label} ({item.running ? 'running' : 'not running'})</option>)}
        </select>
        {connection && <div className="db-connection-details" aria-label="Chosen connection">
          <span>{connection.environment_label}</span><span>{describe(connection)}</span>
          {connection.read_only && <span className="mx-badge mx-state-neutral">read-only</span>}
          <span className={`mx-badge ${connection.running ? 'mx-state-good' : 'mx-state-bad'}`}>{connection.running ? 'Running' : 'Not running'}</span>
          {connection.running && connection.schema_current === false && <span className="mx-badge mx-state-partial">Schema older than the model</span>}
        </div>}
      </div>
      <div className="db-main">
      {loadError && <p className="mx-empty error" role="alert">{loadError}</p>}
      {error && <p className="mx-empty error" role="alert">{error}</p>}
      {!connection && connections && <div className="mx-empty db-guidance">
        <p>Choose a database connection. Physical tables, SQL/OQL results and plans always come from the connection you choose,
          and each result names it.</p>
        {connections.length === 0 && <p>This project has no database connection.</p>}
      </div>}
      {connection && !connection.running && <div className="mx-empty db-guidance">
        <p>The {connection.label} for this project is not running{connection.error ? ` (${connection.error.message})` : ''}.</p>
        <p>Start it with the <strong>db up</strong> task in MXRB Tasks, then refresh the connections.</p>
      </div>}
      {connection?.running && <div className="db-body">
        <div className="db-schema" role="tree" aria-label="Physical schema">
          {!physical && <p className="mx-empty">{introspecting ? 'Reading the PostgreSQL catalog…'
            : 'The physical schema is shown only after you introspect this connection.'}</p>}
          {physical && physical.status !== 'available' && <p className="mx-empty error">
            Schema unavailable: {physical.error?.message ?? physical.status}</p>}
          {physical?.status === 'available' && <SchemaTree tables={physical.tables} expanded={expanded} toggle={toggle} />}
        </div>
        <div className="db-workspace">
          <form className="db-editor" onSubmit={event => { event.preventDefault(); void execute('query'); }}>
            <div className="db-row">
              <span className="db-language" role="group" aria-label="Query language">
                {(['sql', 'oql'] as const).map(item => <button key={item} type="button" aria-pressed={language === item}
                  onClick={() => setLanguage(item)}>{item.toUpperCase()}</button>)}
              </span>
              <label><input type="checkbox" checked={analyze} onChange={event => setAnalyze(event.target.checked)} /> Analyze</label>
              {analyze && <span className="db-warning">Explain with Analyze executes the query (read-only transaction).</span>}
            </div>
            <textarea aria-label={`${language.toUpperCase()} query`} spellCheck={false} value={texts[language]}
              placeholder={language === 'oql' ? 'SELECT Name FROM Module.Entity WHERE Name = $Name' : 'SELECT …'}
              onChange={event => setTexts(previous => ({ ...previous, [language]: event.target.value }))}
              onKeyDown={event => { if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); void execute('query'); } }} />
            <div className="db-row"><strong>Parameters</strong>
              <button type="button" onClick={() => setParameters(previous => [...previous, { name: '', value: '' }])}>Add parameter</button>
              <span className="mx-empty" style={{ margin: 0 }}>Values that parse as JSON are sent as JSON; others as text.</span></div>
            {parameters.length > 0 && <div className="db-params">
              {parameters.map((item, index) => <ParameterRow key={index} item={item}
                change={next => setParameters(previous => previous.map((value, position) => position === index ? next : value))}
                remove={() => setParameters(previous => previous.filter((_, position) => position !== index))} />)}
            </div>}
          </form>
          <div className="db-result" aria-live="polite">
            {running && <p role="status">{running === 'query' ? 'Running query…' : 'Explaining query…'}</p>}
            {!running && !result && <p className="mx-empty">Run a read-only query or explain its plan on {connection.label}.</p>}
            {!running && result?.kind === 'query' && <QueryView data={result.data} />}
            {!running && result?.kind === 'explain' && <ExplainView data={result.data} />}
          </div>
        </div>
      </div>}
      </div>
    </>}
    <div className="mx-status-bar" role="status">
      {connection ? <span>{connection.label} · {connection.environment_label} · {describe(connection)}</span>
        : <span>No connection chosen</span>}
      {physical?.status === 'available' && <span>{physical.tables.length} relations introspected · confirmed by the PostgreSQL catalog</span>}
    </div>
  </section>;
}

function ParameterRow({ item, change, remove }: { item: { name: string; value: string };
  change(next: { name: string; value: string }): void; remove(): void }) {
  return <>
    <input aria-label="Parameter name" placeholder="name" value={item.name} onChange={event => change({ ...item, name: event.target.value })} />
    <input aria-label="Parameter value" placeholder="value" value={item.value} onChange={event => change({ ...item, value: event.target.value })} />
    <button type="button" className="mx-tool" aria-label="Remove parameter" title="Remove parameter" onClick={remove}><Icon name="delete" /></button>
  </>;
}

function ExecutedSql({ sql }: { sql?: string }) {
  return sql ? <details className="db-sql"><summary>Executed SQL</summary><pre>{sql}</pre></details> : null;
}

function Source({ connection }: { connection?: Connection }) {
  return connection ? <span>Connection: {connection.label} · {connection.environment_label} · {describe(connection)}</span> : null;
}

function QueryView({ data }: { data: QueryResult }) {
  const rows = data.rows ?? [];
  const columns = useMemo(() => [...new Set(rows.slice(0, ROW_LIMIT).flatMap(row => Object.keys(row)))], [rows]);
  return <>
    <div className="db-result-meta"><Source connection={data.connection} />
      {data.elapsed_ms !== undefined && <span>{data.elapsed_ms} ms</span>}
      {data.ok && <span>{data.row_count ?? rows.length} rows</span>}</div>
    <ExecutedSql sql={data.sql} />
    {!data.ok && <p className="error" role="alert">{data.error?.message ?? 'The query failed.'}</p>}
    {data.warnings?.map(warning => <p key={warning} className="db-finding">{warning}</p>)}
    {data.ok && rows.length === 0 && <p className="mx-empty">The query returned no rows.</p>}
    {rows.length > 0 && <div className="db-grid-wrap"><table className="mx-grid" aria-label="Query results">
      <thead><tr>{columns.map(column => <th key={column}>{column}</th>)}</tr></thead>
      <tbody>{rows.slice(0, ROW_LIMIT).map((row, index) => <tr key={index}>{columns.map(column => <td key={column}>
        {row[column] === null || row[column] === undefined ? <span className="db-null">NULL</span> : String(row[column])}</td>)}</tr>)}</tbody>
    </table></div>}
    {rows.length > ROW_LIMIT && <p className="mx-empty">Showing the first {ROW_LIMIT} of {rows.length} rows.</p>}
  </>;
}

function ExplainView({ data }: { data: ExplainResult }) {
  const root = data.plan?.raw?.[0]?.Plan;
  return <>
    <div className="db-result-meta"><Source connection={data.connection} />
      <span>{data.analyzed ? 'Analyzed (executed)' : 'Estimated plan'}</span>
      {data.plan?.total_cost != null && <span>Total cost {data.plan.total_cost}</span>}
      {data.plan?.planning_time_ms != null && <span>Planning {data.plan.planning_time_ms} ms</span>}
      {data.plan?.execution_time_ms != null && <span>Execution {data.plan.execution_time_ms} ms</span>}</div>
    <ExecutedSql sql={data.sql} />
    {!data.ok && <p className="error" role="alert">{data.error?.message ?? 'The plan could not be produced.'}</p>}
    {data.warnings?.map(warning => <p key={warning} className="db-finding">{warning}</p>)}
    {data.plan?.findings?.map((finding, index) => <p key={index} className={`db-finding${finding.severity === 'warning' ? ' db-finding-warning' : ''}`}>
      <strong>{finding.severity}</strong> {finding.message}{finding.suggestion ? ` — ${finding.suggestion}` : ''}</p>)}
    {root && <ul className="db-plan" aria-label="Query plan"><PlanItem node={root} depth={0} /></ul>}
  </>;
}

function PlanItem({ node, depth }: { node: PlanNode; depth: number }) {
  const target = [node['Relation Name'], node['Index Name'] && `using ${String(node['Index Name'])}`].filter(Boolean).join(' ');
  const metrics = [
    node['Total Cost'] !== undefined && `cost ${String(node['Startup Cost'] ?? 0)}..${String(node['Total Cost'])}`,
    node['Plan Rows'] !== undefined && `rows ${String(node['Plan Rows'])}`,
    node['Actual Rows'] !== undefined && `actual ${String(node['Actual Rows'])}`,
    node['Actual Total Time'] !== undefined && `${String(node['Actual Total Time'])} ms`
  ].filter(Boolean).join(' · ');
  return <>
    <li style={{ paddingLeft: depth * 16 }}><span className="mx-twisty">{depth ? '└' : ''}</span>
      <span className="db-plan-node">{String(node['Node Type'] ?? 'Node')}</span>{target && <span> on {target}</span>}
      <span className="db-plan-metrics">{metrics}</span></li>
    {node.Plans?.map((child, index) => <PlanItem key={index} node={child} depth={depth + 1} />)}
  </>;
}

function SchemaTree({ tables, expanded, toggle }: { tables: Table[]; expanded: Set<string>; toggle(key: string): void }) {
  const schemas = useMemo(() => {
    const groups = new Map<string, Table[]>();
    for (const table of tables) groups.set(table.schema, [...(groups.get(table.schema) ?? []), table]);
    return [...groups];
  }, [tables]);
  if (tables.length === 0) return <p className="mx-empty">The connection has no relations visible to its user.</p>;
  const row = (key: string, depth: number, content: ReactNode, expandable: boolean) => <button key={key} type="button" role="treeitem"
    className="mx-tree-row" data-node={key} aria-level={depth + 1} aria-expanded={expandable ? expanded.has(key) : undefined}
    style={{ paddingLeft: 6 + depth * 14 }} onClick={() => { if (expandable) toggle(key); }}>
    <span className="mx-twisty" aria-hidden="true">{expandable ? expanded.has(key) ? '▾' : '▸' : ''}</span>{content}</button>;
  const items: ReactNode[] = [];
  for (const [schema, members] of schemas) {
    const schemaKey = `schema:${schema}`;
    items.push(row(schemaKey, 0, <><Icon name="database" /><span>{schema} ({members.length})</span></>, true));
    if (!expanded.has(schemaKey)) continue;
    for (const table of members) {
      const key = `table:${table.id}`;
      items.push(row(key, 1, <><Icon name="table" /><span>{table.name}{table.kind !== 'table' &&
        <span className="db-type">{table.kind.replace('_', ' ')}</span>}</span></>, true));
      if (!expanded.has(key)) continue;
      const primary = new Set(table.primary_key?.columns ?? []);
      const foreign = new Map(table.foreign_keys.flatMap(fk => fk.columns.map(column => [column, fk] as const)));
      for (const column of table.columns) {
        const target = foreign.get(column.name);
        items.push(row(`${key}:column:${column.name}`, 2, <><span className="db-markers">
          {primary.has(column.name) && <span className="mx-badge mx-state-partial" title="Primary key">PK</span>}
          {target && <span className="mx-badge mx-state-neutral" title={`References ${target.target_schema}.${target.target_table}`}>FK</span>}
        </span><span>{column.name}<span className="db-type">{column.type}{column.nullable === false ? ' not null' : ''}</span></span></>, false));
      }
      for (const fk of table.foreign_keys) {
        items.push(row(`${key}:fk:${fk.name}`, 2, <span>→ {fk.name}: ({fk.columns.join(', ')}) references {fk.target_schema}.{fk.target_table}
          ({fk.target_columns?.join(', ')}){fk.validated === false ? ' · not validated' : ''}</span>, false));
      }
      for (const index of table.indexes) {
        const columns = index.columns?.filter(column => !column.included).map(column => column.name ?? column.expression).join(', ');
        items.push(row(`${key}:index:${index.name}`, 2, <span><Icon name="key" />{index.name}<span className="db-type">
          {[index.primary ? 'primary' : index.unique ? 'unique' : '', index.method, columns && `(${columns})`].filter(Boolean).join(' ')}</span></span>, false));
      }
      for (const constraint of table.constraints.filter(item => item.type === 'c' || item.type === 'u' || item.type === 'x')) {
        items.push(row(`${key}:constraint:${constraint.name}`, 2, <span>{constraint.name}<span className="db-type">{constraint.definition}</span></span>, false));
      }
    }
  }
  return <>{items}</>;
}
