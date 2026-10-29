import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { StudioRpc } from './rpc';
import type { StudioContext } from './types';
import { Icon, ToolButton, Toolbar, errorText } from './ui';
import {
  CATEGORY_LABELS, HEADER_HEIGHT, ROW_HEIGHT, attributeLabel, bounds, cardinality, category, edge,
  edgeOffsets, indexColumns, layout, neighbourhood, searchMatches, visibleGraph
} from './erModel';
import type { Box, ErEntity, ErRelationship, Layout, LogicalModel, RelationshipFilter } from './erModel';
import './er.css';

type View = { scale: number; x: number; y: number };
const MIN_SCALE = 0.1, MAX_SCALE = 3;

/**
 * A read-only, IDE-only ER view of the logical model across modules. It never
 * changes the Mendix domain model layout and never claims physical tables.
 */
export function GlobalEr({ rpc, context }: { rpc: StudioRpc; context: StudioContext }) {
  const [model, setModel] = useState<LogicalModel>();
  const [state, setState] = useState<'idle' | 'loading' | 'ready' | 'error'>('idle');
  const [error, setError] = useState('');
  const [modules, setModules] = useState<Set<string>>(new Set());
  const [relationships, setRelationships] = useState<RelationshipFilter>('all');
  const [query, setQuery] = useState('');
  const [focus, setFocus] = useState(false);
  const [depth, setDepth] = useState(1);
  const [selected, setSelected] = useState<string>();
  const [view, setView] = useState<View>({ scale: 1, x: 0, y: 0 });
  const [modulePicker, setModulePicker] = useState(false);
  const [reload, setReload] = useState(0);
  const canvas = useRef<HTMLDivElement>(null);
  const fitted = useRef(false);

  useEffect(() => {
    const controller = new AbortController();
    setModel(undefined); setSelected(undefined); setError(''); setQuery(''); setFocus(false);
    fitted.current = false;
    if (!context.source_model) { setState('idle'); return; }
    setState('loading');
    rpc.call<LogicalModel>('data/logical', { model: context.source_model }, { signal: controller.signal })
      .then(result => {
        if (controller.signal.aborted) return;
        setModel(result);
        setModules(new Set(result.modules.filter(module => module.entities.length > 0).map(module => module.name)));
        setState('ready');
      })
      .catch(reason => { if (!controller.signal.aborted) { setError(errorText(reason)); setState('error'); } });
    return () => controller.abort();
  }, [rpc, context.source_model, context.project_revision, reload]);

  const entities = useMemo(() => new Map(model?.entities.map(entity => [entity.qualified_name, entity]) ?? []), [model]);
  const graph = useMemo(() => model ? visibleGraph(model, { modules, relationships }) : undefined, [model, modules, relationships]);
  const diagram = useMemo<Layout | undefined>(() => {
    if (!model || !graph) return undefined;
    const visible = new Set(graph.entities.map(entity => entity.qualified_name));
    return layout(model.modules.map(module => ({ name: module.name,
      entities: model.entities.filter(entity => entity.module === module.name && visible.has(entity.qualified_name)) })),
    graph.externals);
  }, [model, graph]);
  const matches = useMemo(() => graph ? searchMatches(graph.entities, query) : null, [graph, query]);
  const shown = useMemo(() => focus && selected && graph ? neighbourhood(graph.relationships, selected, depth) : null,
    [focus, selected, depth, graph]);

  const viewport = () => canvas.current?.getBoundingClientRect() ?? { width: 800, height: 600 };
  const fit = useCallback((minimum = MIN_SCALE) => {
    if (!diagram) return;
    const boxes = [...diagram.boxes.values()].filter(box => !shown || shown.has(box.name));
    const area = shown ? bounds(boxes) : { x: 0, y: 0, width: diagram.width, height: diagram.height };
    if (!area) return;
    const { width, height } = viewport();
    const scale = Math.max(minimum, Math.min(1.25, (width - 32) / Math.max(area.width, 1), (height - 32) / Math.max(area.height, 1)));
    // A diagram that does not fit at a readable scale starts at its top-left corner, like a document.
    setView({ scale, x: Math.max(16, (width - area.width * scale) / 2) - area.x * scale,
      y: Math.max(16, (height - area.height * scale) / 2) - area.y * scale });
  }, [diagram, shown]);

  useEffect(() => { if (diagram && !fitted.current) { fitted.current = true; fit(0.5); } }, [diagram, fit]);
  useEffect(() => { if (focus) fit(); }, [focus, depth, selected, fit]);

  const zoom = useCallback((factor: number, at?: { x: number; y: number }) => {
    setView(current => {
      const scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, current.scale * factor));
      const point = at ?? { x: viewport().width / 2, y: viewport().height / 2 };
      const ratio = scale / current.scale;
      return { scale, x: point.x - (point.x - current.x) * ratio, y: point.y - (point.y - current.y) * ratio };
    });
  }, []);

  const center = useCallback((name: string) => {
    const box = diagram?.boxes.get(name);
    if (!box) return;
    const { width, height } = viewport();
    setView(current => ({ ...current, x: width / 2 - (box.x + box.width / 2) * current.scale,
      y: height / 2 - (box.y + Math.min(box.height, 120) / 2) * current.scale }));
  }, [diagram]);

  const select = useCallback((name: string | undefined, reveal = false) => {
    setSelected(name);
    if (name && reveal) {
      const entity = entities.get(name);
      if (entity && !modules.has(entity.module)) setModules(previous => new Set(previous).add(entity.module));
      requestAnimationFrame(() => center(name));
    }
  }, [center, entities, modules]);

  useEffect(() => {
    const element = canvas.current;
    if (!element) return;
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      const box = element.getBoundingClientRect();
      if (event.ctrlKey || event.metaKey) zoom(event.deltaY < 0 ? 1.15 : 1 / 1.15, { x: event.clientX - box.left, y: event.clientY - box.top });
      else setView(current => ({ ...current, x: current.x - (event.shiftKey ? event.deltaY : event.deltaX), y: current.y - (event.shiftKey ? 0 : event.deltaY) }));
    };
    element.addEventListener('wheel', wheel, { passive: false });
    return () => element.removeEventListener('wheel', wheel);
  }, [zoom, state]);

  const drag = useRef<{ x: number; y: number; moved: boolean } | null>(null);
  const content = useMemo(() => diagram && graph
    ? <Diagram diagram={diagram} relationships={graph.relationships} entities={entities} matches={matches} shown={shown} />
    : null, [diagram, graph, entities, matches, shown]);
  const selectedBox = selected ? diagram?.boxes.get(selected) : undefined;
  const selectedEdges = useMemo(() => {
    if (!selected || !graph || !diagram) return [];
    const offsets = edgeOffsets(graph.relationships);
    return graph.relationships.filter(relationship => relationship.from === selected || relationship.to === selected)
      .map(relationship => edge(relationship, diagram.boxes, offsets.get(relationship.id)))
      .filter(item => item !== null);
  }, [selected, graph, diagram]);

  const allModules = model?.modules.filter(module => module.entities.length > 0).map(module => module.name) ?? [];
  const entity = selected ? entities.get(selected) : undefined;

  return <section className="mx-panel er-panel" aria-label="MXRB Global ER">
    <Toolbar label="Global ER">
      <ToolButton icon="refresh" label="Refresh diagram" onClick={() => setReload(value => value + 1)} disabled={!context.source_model} />
      <span className="mx-separator" />
      <span className="er-picker">
        <ToolButton icon="filter" label="Filter modules" text={`Modules (${modules.size}/${allModules.length})`}
          pressed={modulePicker} disabled={!model} onClick={() => setModulePicker(open => !open)} />
        {modulePicker && model && <div className="er-popover" role="group" aria-label="Modules shown in the diagram">
          <div className="er-popover-actions">
            <button type="button" onClick={() => setModules(new Set(allModules))}>All</button>
            <button type="button" onClick={() => setModules(new Set())}>None</button>
            <button type="button" onClick={() => setModulePicker(false)}>Close</button>
          </div>
          {allModules.map(name => <label key={name}><input type="checkbox" checked={modules.has(name)} data-module={name}
            onChange={event => setModules(previous => {
              const next = new Set(previous);
              if (event.target.checked) next.add(name); else next.delete(name);
              return next;
            })} />{name}</label>)}
        </div>}
      </span>
      <select aria-label="Relationships" value={relationships} disabled={!model}
        onChange={event => setRelationships(event.target.value as RelationshipFilter)}>
        <option value="all">All relationships</option>
        <option value="associations">Associations</option>
        <option value="inheritance">Generalizations</option>
        <option value="cross_module">Cross-module only</option>
      </select>
      <input type="search" className="er-search" aria-label="Search entities and attributes" placeholder="Search entity or attribute"
        value={query} disabled={!model} onChange={event => setQuery(event.target.value)}
        onKeyDown={event => {
          if (event.key !== 'Enter' || !matches?.size) return;
          const first = [...matches].sort()[0];
          select(first, true);
        }} />
      <ToolButton icon="connect" label="Show only the selected entity's neighbourhood" text="Neighbourhood"
        pressed={focus} disabled={!selected} onClick={() => setFocus(value => !value)} />
      <select aria-label="Neighbourhood depth" value={depth} disabled={!focus} onChange={event => setDepth(Number(event.target.value))}>
        {[1, 2, 3].map(value => <option key={value} value={value}>{value} {value === 1 ? 'level' : 'levels'}</option>)}
      </select>
      <span className="mx-spacer" />
      <ToolButton icon="zoomOut" label="Zoom out" onClick={() => zoom(1 / 1.25)} disabled={!diagram} />
      <span className="er-zoom" aria-live="polite">{Math.round(view.scale * 100)}%</span>
      <ToolButton icon="zoomIn" label="Zoom in" onClick={() => zoom(1.25)} disabled={!diagram} />
      <ToolButton icon="fit" label="Fit to window" onClick={() => fit()} disabled={!diagram} />
    </Toolbar>
    {state === 'idle' && <p className="mx-empty">Open a Mendix project to see the entities of all its modules.</p>}
    {state === 'loading' && <p className="mx-empty" role="status">Reading the domain models…</p>}
    {state === 'error' && <p className="mx-empty error" role="alert">{error}</p>}
    {state === 'ready' && model && <div className={`er-body${entity ? ' er-with-details' : ''}`}>
      <div ref={canvas} className="er-canvas" tabIndex={0} aria-label="Entity relationship diagram"
        onPointerDown={event => {
          if ((event.target as Element).closest('[data-entity]')) return;
          drag.current = { x: event.clientX, y: event.clientY, moved: false };
          event.currentTarget.setPointerCapture(event.pointerId);
        }}
        onPointerMove={event => {
          const start = drag.current;
          if (!start) return;
          const dx = event.clientX - start.x, dy = event.clientY - start.y;
          if (Math.abs(dx) + Math.abs(dy) > 2) start.moved = true;
          start.x = event.clientX; start.y = event.clientY;
          setView(current => ({ ...current, x: current.x + dx, y: current.y + dy }));
        }}
        onPointerUp={event => {
          const start = drag.current;
          drag.current = null;
          if (start && !start.moved && !(event.target as Element).closest('[data-entity]')) setSelected(undefined);
        }}
        onClick={event => {
          const target = (event.target as Element).closest('[data-entity]');
          if (target) select(target.getAttribute('data-entity') ?? undefined);
        }}
        onKeyDown={event => {
          if (event.key === '+' || event.key === '=') zoom(1.25);
          else if (event.key === '-') zoom(1 / 1.25);
          else if (event.key === '0') fit();
          else if (event.key === 'Escape') { setSelected(undefined); setFocus(false); }
          else return;
          event.preventDefault();
        }}>
        {graph && graph.entities.length === 0 && <p className="mx-empty er-overlay">No entities in the selected modules.</p>}
        <svg className="er-svg" role="img" aria-label={`${graph?.entities.length ?? 0} entities`}>
          <defs>
            <marker id="er-arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse">
              <path d="M0 1L10 5L0 9" className="er-arrow-head" />
            </marker>
            <marker id="er-generalization" viewBox="0 0 12 12" refX="12" refY="6" markerWidth="13" markerHeight="13" orient="auto-start-reverse">
              <path d="M0 0L12 6L0 12z" className="er-generalization-head" />
            </marker>
          </defs>
          <g transform={`translate(${view.x} ${view.y}) scale(${view.scale})`}>
            {content}
            {selectedEdges.map(item => <line key={item.relationship.id} className="er-edge-selected"
              x1={item.x1} y1={item.y1} x2={item.x2} y2={item.y2} />)}
            {selectedBox && <rect className="er-selection" x={selectedBox.x - 2} y={selectedBox.y - 2}
              width={selectedBox.width + 4} height={selectedBox.height + 4} rx="3" />}
          </g>
        </svg>
      </div>
      {entity && <EntityDetails entity={entity} relationships={model.relationships} entities={entities}
        onNavigate={name => select(name, true)} onClose={() => setSelected(undefined)} />}
    </div>}
    <div className="mx-status-bar" role="status">
      <span className="er-scope">Logical model · physical schema not confirmed</span>
      {graph && <span>{graph.entities.length} entities · {graph.relationships.length} relationships · {modules.size} modules</span>}
      {model?.project?.name && <span>{model.project.name}{model.project.mendix_version ? ` · Mendix ${model.project.mendix_version}` : ''}</span>}
      {matches && <span>{matches.size} matching</span>}
    </div>
  </section>;
}

const Diagram = memo(function Diagram({ diagram, relationships, entities, matches, shown }: {
  diagram: Layout; relationships: ErRelationship[]; entities: Map<string, ErEntity>;
  matches: Set<string> | null; shown: Set<string> | null;
}) {
  const offsets = edgeOffsets(relationships);
  const dim = (name: string) => matches !== null && !matches.has(name);
  const frames = shown ? [] : diagram.frames;
  const edges = relationships.filter(relationship => !shown || (shown.has(relationship.from) && shown.has(relationship.to)))
    .map(relationship => edge(relationship, diagram.boxes, offsets.get(relationship.id)))
    .filter(item => item !== null);
  return <>
    {frames.map(frame => <g key={frame.name} className={`er-frame${frame.external ? ' er-frame-external' : ''}`}>
      <rect x={frame.x} y={frame.y} width={frame.width} height={frame.height} rx="2" />
      <text x={frame.x + 10} y={frame.y + 17}>{frame.name}</text>
    </g>)}
    {edges.map(item => <EdgeView key={item.relationship.id} item={item}
      dimmed={dim(item.relationship.from) && dim(item.relationship.to)} />)}
    {[...diagram.boxes.values()].map(box => (!shown || shown.has(box.name)) &&
      <EntityBox key={box.name} box={box} entity={entities.get(box.name)} dimmed={dim(box.name)} />)}
    {edges.map(item => <EdgeLabel key={item.relationship.id} item={item}
      dimmed={dim(item.relationship.from) && dim(item.relationship.to)} />)}
  </>;
});

function EdgeView({ item, dimmed }: { item: NonNullable<ReturnType<typeof edge>>; dimmed: boolean }) {
  const { relationship, x1, y1, x2, y2 } = item;
  const label = relationship.name ?? '';
  const inheritance = relationship.kind === 'inheritance';
  const ends = cardinality(relationship);
  const length = Math.hypot(x2 - x1, y2 - y1) || 1;
  const ux = (x2 - x1) / length, uy = (y2 - y1) / length;
  const path = item.self ? `M${x1} ${y1} C${x1 + 50} ${y1} ${x2} ${y2 - 50} ${x2} ${y2}` : `M${x1} ${y1} L${x2} ${y2}`;
  return <g className={`er-edge${inheritance ? ' er-edge-inheritance' : ''}${relationship.cross_module ? ' er-edge-cross' : ''}${dimmed ? ' er-dim' : ''}`}
    data-relationship={relationship.id}>
    <title>{inheritance ? `${relationship.from} generalizes ${relationship.to}` : `${label}: ${relationship.from} → ${relationship.to} (${ends.label})`}</title>
    <path d={path} markerEnd={inheritance ? 'url(#er-generalization)' : 'url(#er-arrow)'} />
    {!inheritance && !item.self && <>
      <Multiplicity x={x1 + ux * 14} y={y1 + uy * 14} text={ends.from} />
      <Multiplicity x={x2 - ux * 22} y={y2 - uy * 22} text={ends.to} />
    </>}
  </g>;
}

/** Association names sit above the entity boxes, in small white boxes like Studio Pro. */
function EdgeLabel({ item, dimmed }: { item: NonNullable<ReturnType<typeof edge>>; dimmed: boolean }) {
  const { relationship, x1, y1, x2, y2 } = item;
  if (relationship.kind === 'inheritance' || !relationship.name) return null;
  const label = relationship.name + (relationship.owner === 'Both' ? ' ⇄' : '');
  const mid = item.self ? { x: x1 + 30, y: y1 - 30 } : { x: (x1 + x2) / 2, y: (y1 + y2) / 2 };
  return <g className={`er-label${dimmed ? ' er-dim' : ''}`}>
    <rect x={mid.x - label.length * 2.9 - 4} y={mid.y - 8} width={label.length * 5.8 + 8} height="15" />
    <text x={mid.x} y={mid.y + 3} textAnchor="middle">{label}</text>
  </g>;
}

function Multiplicity({ x, y, text }: { x: number; y: number; text: string }) {
  return <g className="er-multiplicity"><circle cx={x} cy={y} r="6.5" /><text x={x} y={y + 3.5} textAnchor="middle">{text}</text></g>;
}

function EntityBox({ box, entity, dimmed }: { box: Box; entity?: ErEntity; dimmed: boolean }) {
  const kind = category(entity);
  const name = entity?.name ?? box.name;
  const external = kind === 'external';
  return <g className={`er-entity er-${kind}${dimmed ? ' er-dim' : ''}`} data-entity={box.name} role="button" aria-label={box.name}>
    <title>{`${box.name} · ${CATEGORY_LABELS[kind]}`}</title>
    <rect className="er-box" x={box.x} y={box.y} width={box.width} height={box.height} rx="3" />
    <line className="er-box-line" x1={box.x} y1={box.y + HEADER_HEIGHT} x2={box.x + box.width} y2={box.y + HEADER_HEIGHT} />
    <rect className="er-glyph" x={box.x + 6} y={box.y + 5} width="12" height="12" rx="1" />
    <text className="er-glyph-text" x={box.x + 12} y={box.y + 14.5} textAnchor="middle">{kind === 'view' ? 'v' : 'e'}</text>
    <text className="er-name" x={box.x + 24} y={box.y + 15}>{clip(external ? box.name : name, 24)}</text>
    {external && <text className="er-attribute er-muted" x={box.x + 8} y={box.y + HEADER_HEIGHT + 14}>Not in this app's model</text>}
    {entity?.attributes.slice(0, box.rows).map((attribute, index) => <text key={attribute.name} className="er-attribute"
      x={box.x + 8} y={box.y + HEADER_HEIGHT + 13 + index * ROW_HEIGHT}>{clip(attributeLabel(attribute), 28)}</text>)}
    {box.hidden > 0 && <text className="er-attribute er-muted" x={box.x + 8}
      y={box.y + HEADER_HEIGHT + 13 + box.rows * ROW_HEIGHT}>+ {box.hidden} more…</text>}
  </g>;
}

function clip(text: string, length: number) { return text.length > length ? `${text.slice(0, length - 1)}…` : text; }

function EntityDetails({ entity, relationships, entities, onNavigate, onClose }: {
  entity: ErEntity; relationships: ErRelationship[]; entities: Map<string, ErEntity>;
  onNavigate(name: string): void; onClose(): void;
}) {
  const kind = category(entity);
  const outgoing = relationships.filter(relationship => relationship.from === entity.qualified_name);
  const incoming = relationships.filter(relationship => relationship.to === entity.qualified_name);
  const link = (name: string) => entities.has(name)
    ? <button type="button" className="er-link" onClick={() => onNavigate(name)}>{name}</button>
    : <span title="Not in this app's model">{name}</span>;
  const persistence = entity.persistent === true ? 'Persistable' : entity.persistent === false ? 'Non-persistable'
    : `Unresolved${entity.generalization ? ` (inherits ${entity.generalization})` : ''}`;
  return <aside className="er-details" aria-label={`Details of ${entity.qualified_name}`}>
    <div className="er-details-title"><Icon name="entity" /><strong>{entity.qualified_name}</strong>
      <button type="button" className="mx-tool" aria-label="Close details" title="Close details" onClick={onClose}>×</button></div>
    <dl className="er-properties">
      <dt>Kind</dt><dd>{CATEGORY_LABELS[kind]}</dd>
      <dt>Persistence</dt><dd>{persistence}</dd>
      <dt>Generalization</dt><dd>{entity.generalization ? link(entity.generalization) : 'None'}</dd>
      <dt>Physical table</dt><dd>Not confirmed (logical model only)</dd>
    </dl>
    <h3>Attributes ({entity.attributes.length})</h3>
    {entity.attributes.length ? <table className="mx-grid er-attributes">
      <thead><tr><th>Name</th><th>Type</th><th>Flags</th></tr></thead>
      <tbody>{entity.attributes.map(attribute => <tr key={attribute.name}><td>{attribute.name}</td>
        <td>{attributeLabel(attribute).slice(attribute.name.length + 2, -1)}</td>
        <td>{[attribute.key && 'key', attribute.required && 'required'].filter(Boolean).join(', ')}</td></tr>)}</tbody>
    </table> : <p className="mx-empty">No attributes.</p>}
    <h3>Indexes ({entity.indexes?.length ?? 0})</h3>
    {entity.indexes?.length ? <ul>{entity.indexes.map((index, position) =>
      <li key={position}>{indexColumns(index).join(', ') || 'Index'}</li>)}</ul> : <p className="mx-empty">No indexes declared.</p>}
    <h3>Relationships</h3>
    {outgoing.length + incoming.length === 0 && <p className="mx-empty">No relationships.</p>}
    <ul className="er-relations">
      {outgoing.map(relationship => <li key={relationship.id}>
        {relationship.kind === 'inheritance' ? 'Generalizes ' : `${relationship.name} (${cardinality(relationship).label}) → `}
        {link(relationship.to)}</li>)}
      {incoming.map(relationship => <li key={relationship.id}>
        {relationship.kind === 'inheritance' ? 'Specialized by ' : `${relationship.name} (${cardinality(relationship).label}) ← `}
        {link(relationship.from)}</li>)}
    </ul>
  </aside>;
}

