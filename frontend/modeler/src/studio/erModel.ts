/** Pure model helpers for the global ER view: no DOM, no RPC, deterministic for tests. */

export type ErAttribute = { name: string; type: string; required?: boolean; key?: boolean };
export type ErEntity = {
  id: string; name: string; qualified_name: string; module: string;
  kind: 'entity' | 'dto' | 'oql_view' | string;
  persistent?: boolean | null; persistence_resolved?: boolean; generalization?: string | null;
  x?: number; y?: number; attributes: ErAttribute[]; indexes?: unknown[];
  system_members?: Record<string, boolean>;
};
export type ErRelationship = {
  id: string; kind: 'association' | 'inheritance'; name?: string | null; from: string; to: string;
  type?: 'Reference' | 'ReferenceSet' | string | null; owner?: string | null; cross_module?: boolean;
  target_resolved?: boolean;
};
export type ErModule = { name: string; entities: ErEntity[] };
export type LogicalModel = {
  project?: { name?: string; mendix_version?: string };
  modules: ErModule[]; entities: ErEntity[]; relationships: ErRelationship[];
  external_entities: string[]; source?: string; physical_schema_confirmed?: boolean;
};

export type Category = 'persistent' | 'non_persistent' | 'view' | 'unresolved' | 'external';

export function category(entity: ErEntity | undefined): Category {
  if (!entity) return 'external';
  if (entity.kind === 'oql_view') return 'view';
  if (entity.kind === 'dto' || entity.persistent === false) return 'non_persistent';
  if (entity.persistent === true) return 'persistent';
  return 'unresolved';
}

export const CATEGORY_LABELS: Record<Category, string> = {
  persistent: 'Persistable entity', non_persistent: 'Non-persistable entity', view: 'View entity (OQL)',
  unresolved: 'Persistence unresolved', external: 'Outside the model'
};

/** Multiplicity at each end: a Reference is many-to-one, a ReferenceSet many-to-many. */
export function cardinality(relationship: ErRelationship): { from: string; to: string; label: string } {
  if (relationship.kind !== 'association') return { from: '', to: '', label: 'generalization' };
  const both = relationship.owner === 'Both';
  if (relationship.type === 'ReferenceSet') return { from: '*', to: '*', label: both ? '* – * (owner: both)' : '* – *' };
  return { from: '*', to: '1', label: both ? '* – 1 (owner: both)' : '* – 1' };
}

export type RelationshipFilter = 'all' | 'associations' | 'inheritance' | 'cross_module';
export type Filter = { modules: Set<string>; relationships: RelationshipFilter; query: string };

export function moduleOf(qualifiedName: string) { return qualifiedName.split('.')[0] ?? ''; }

/** Entities and relationships visible for the module and relationship filters (search does not hide). */
export function visibleGraph(model: LogicalModel, filter: Pick<Filter, 'modules' | 'relationships'>) {
  const entities = model.entities.filter(entity => filter.modules.has(entity.module));
  const names = new Set(entities.map(entity => entity.qualified_name));
  const relationships = model.relationships.filter(relationship => {
    if (filter.relationships === 'associations' && relationship.kind !== 'association') return false;
    if (filter.relationships === 'inheritance' && relationship.kind !== 'inheritance') return false;
    if (filter.relationships === 'cross_module' && !relationship.cross_module) return false;
    const fromVisible = names.has(relationship.from);
    const toVisible = names.has(relationship.to);
    // An edge to an entity outside the model (System.User) keeps a placeholder;
    // an edge into a filtered-out module is hidden with that module.
    const external = (name: string) => model.external_entities.includes(name);
    return (fromVisible || external(relationship.from)) && (toVisible || external(relationship.to)) && (fromVisible || toVisible);
  });
  const externals = [...new Set(relationships.flatMap(relationship => [relationship.from, relationship.to])
    .filter(name => !names.has(name) && model.external_entities.includes(name)))].sort();
  return { entities, relationships, externals };
}

export function searchMatches(entities: ErEntity[], query: string) {
  const text = query.trim().toLowerCase();
  if (!text) return null;
  return new Set(entities.filter(entity => entity.qualified_name.toLowerCase().includes(text) ||
    entity.attributes.some(attribute => attribute.name.toLowerCase().includes(text))).map(entity => entity.qualified_name));
}

/** Entities reachable from `start` within `depth` hops, ignoring direction. */
export function neighbourhood(relationships: ErRelationship[], start: string, depth: number) {
  const adjacent = new Map<string, string[]>();
  for (const { from, to } of relationships) {
    adjacent.set(from, [...(adjacent.get(from) ?? []), to]);
    adjacent.set(to, [...(adjacent.get(to) ?? []), from]);
  }
  const seen = new Set([start]);
  let frontier = [start];
  for (let level = 0; level < depth && frontier.length; level++) {
    const next: string[] = [];
    for (const name of frontier) for (const other of adjacent.get(name) ?? []) {
      if (!seen.has(other)) { seen.add(other); next.push(other); }
    }
    frontier = next;
  }
  return seen;
}

export const BOX_WIDTH = 176;
export const HEADER_HEIGHT = 22;
export const ROW_HEIGHT = 15;
export const MAX_ROWS = 12;
const FRAME_PADDING = 16;
const FRAME_TITLE = 24;
const FRAME_GAP = 40;

export type Box = { name: string; x: number; y: number; width: number; height: number; rows: number; hidden: number };
export type Frame = { name: string; x: number; y: number; width: number; height: number; external: boolean };
export type Layout = { boxes: Map<string, Box>; frames: Frame[]; width: number; height: number };

export function boxHeight(attributeCount: number) {
  const rows = Math.min(attributeCount, MAX_ROWS) + (attributeCount > MAX_ROWS ? 1 : 0);
  return HEADER_HEIGHT + Math.max(rows, 1) * ROW_HEIGHT + 6;
}

function overlaps(a: { x: number; y: number; width: number; height: number }, b: typeof a, gap = 12) {
  return a.x < b.x + b.width + gap && b.x < a.x + a.width + gap && a.y < b.y + b.height + gap && b.y < a.y + a.height + gap;
}

/**
 * Keeps each module's own Mendix positions (normalised to the frame origin),
 * nudges overlapping boxes right, then shelf-packs module frames in model order.
 */
export function layout(modules: { name: string; entities: ErEntity[] }[], externals: string[]): Layout {
  const boxes = new Map<string, Box>();
  const groups = modules.filter(module => module.entities.length > 0)
    .map(module => ({ name: module.name, external: false, items: module.entities }))
    .concat(externals.length ? [{ name: 'Outside the model', external: true,
      items: externals.map((name, index) => ({ id: name, name: name.split('.').pop() ?? name, qualified_name: name,
        module: moduleOf(name), kind: 'external', attributes: [], x: index * (BOX_WIDTH + 24), y: 0 }) as ErEntity) }] : []);
  const local = groups.map(group => {
    const placed: Box[] = [];
    const known = group.items.filter(entity => Number.isFinite(entity.x) && Number.isFinite(entity.y));
    const minX = known.length ? Math.min(...known.map(entity => entity.x!)) : 0;
    const minY = known.length ? Math.min(...known.map(entity => entity.y!)) : 0;
    let fallbackX = 0;
    const ordered = [...group.items].sort((a, b) => (a.y ?? Infinity) - (b.y ?? Infinity) || (a.x ?? Infinity) - (b.x ?? Infinity)
      || a.qualified_name.localeCompare(b.qualified_name));
    const bottom = known.length ? Math.max(...known.map(entity => entity.y! - minY)) + 200 : 0;
    for (const entity of ordered) {
      const count = entity.attributes.length;
      const box: Box = {
        name: entity.qualified_name, width: BOX_WIDTH, height: entity.kind === 'external' ? HEADER_HEIGHT + 21 : boxHeight(count),
        rows: Math.min(count, MAX_ROWS), hidden: Math.max(0, count - MAX_ROWS),
        x: Number.isFinite(entity.x) ? entity.x! - minX : (fallbackX += BOX_WIDTH + 24) - BOX_WIDTH - 24,
        y: Number.isFinite(entity.y) ? entity.y! - minY : bottom
      };
      while (placed.some(other => overlaps(box, other))) box.x += 24;
      placed.push(box);
    }
    const width = Math.max(...placed.map(box => box.x + box.width), 160);
    const height = Math.max(...placed.map(box => box.y + box.height), 40);
    return { group, placed, width: width + FRAME_PADDING * 2, height: height + FRAME_PADDING * 2 + FRAME_TITLE };
  });
  const area = local.reduce((sum, item) => sum + item.width * item.height, 0);
  const rowWidth = Math.max(900, Math.sqrt(area) * 1.6, ...local.map(item => item.width));
  const frames: Frame[] = [];
  let x = 0, y = 0, shelf = 0, width = 0;
  for (const item of local) {
    if (x > 0 && x + item.width > rowWidth) { x = 0; y += shelf + FRAME_GAP; shelf = 0; }
    frames.push({ name: item.group.name, x, y, width: item.width, height: item.height, external: item.group.external });
    for (const box of item.placed) {
      boxes.set(box.name, { ...box, x: x + FRAME_PADDING + box.x, y: y + FRAME_TITLE + FRAME_PADDING + box.y });
    }
    x += item.width + FRAME_GAP; shelf = Math.max(shelf, item.height); width = Math.max(width, x - FRAME_GAP);
  }
  return { boxes, frames, width, height: y + shelf };
}

/** The point where the segment from the box centre towards (tx, ty) leaves the box. */
export function borderPoint(box: Box, tx: number, ty: number) {
  const cx = box.x + box.width / 2, cy = box.y + box.height / 2;
  const dx = tx - cx, dy = ty - cy;
  if (dx === 0 && dy === 0) return { x: cx, y: cy };
  const scale = Math.min(Math.abs(dx) > 0 ? box.width / 2 / Math.abs(dx) : Infinity,
    Math.abs(dy) > 0 ? box.height / 2 / Math.abs(dy) : Infinity);
  return { x: cx + dx * scale, y: cy + dy * scale };
}

export type Edge = { relationship: ErRelationship; x1: number; y1: number; x2: number; y2: number; self: boolean };

export function edge(relationship: ErRelationship, boxes: Map<string, Box>, offset = 0): Edge | null {
  const from = boxes.get(relationship.from), to = boxes.get(relationship.to);
  if (!from || !to) return null;
  if (from === to) {
    return { relationship, self: true, x1: from.x + from.width, y1: from.y + 10 + offset, x2: from.x + from.width - 30 - offset, y2: from.y };
  }
  const fc = { x: from.x + from.width / 2, y: from.y + from.height / 2 };
  const tc = { x: to.x + to.width / 2, y: to.y + to.height / 2 };
  // Parallel associations between the same pair are spread perpendicular to the line.
  const length = Math.hypot(tc.x - fc.x, tc.y - fc.y) || 1;
  const nx = -(tc.y - fc.y) / length * offset, ny = (tc.x - fc.x) / length * offset;
  const start = borderPoint(from, tc.x + nx, tc.y + ny);
  const end = borderPoint(to, fc.x + nx, fc.y + ny);
  return { relationship, self: false, x1: start.x + nx, y1: start.y + ny, x2: end.x + nx, y2: end.y + ny };
}

/** Offsets for relationships sharing the same unordered entity pair. */
export function edgeOffsets(relationships: ErRelationship[]) {
  const groups = new Map<string, ErRelationship[]>();
  for (const relationship of relationships) {
    const key = [relationship.from, relationship.to].sort().join('\u0000');
    groups.set(key, [...(groups.get(key) ?? []), relationship]);
  }
  const offsets = new Map<string, number>();
  for (const group of groups.values()) {
    group.forEach((relationship, index) => {
      const sign = relationship.from <= relationship.to ? 1 : -1;
      offsets.set(relationship.id, (index - (group.length - 1) / 2) * 18 * sign);
    });
  }
  return offsets;
}

export function bounds(boxes: Iterable<Box>) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const box of boxes) {
    minX = Math.min(minX, box.x); minY = Math.min(minY, box.y);
    maxX = Math.max(maxX, box.x + box.width); maxY = Math.max(maxY, box.y + box.height);
  }
  return Number.isFinite(minX) ? { x: minX, y: minY, width: maxX - minX, height: maxY - minY } : null;
}

/** Attribute names of a native index; members carry `Attribute` as a qualified name. */
export function indexColumns(index: unknown): string[] {
  if (!index || typeof index !== 'object') return [];
  const members = (index as Record<string, unknown>).Attributes ?? (index as Record<string, unknown>).attributes;
  if (!Array.isArray(members)) return [];
  return members.filter((member): member is Record<string, unknown> => !!member && typeof member === 'object')
    .map(member => {
      const name = String(member.Attribute ?? member.attribute ?? '?').split('.').pop();
      return member.Ascending === false ? `${name} (descending)` : String(name);
    });
}

export function attributeLabel(attribute: ErAttribute) {
  const types: Record<string, string> = {
    string: 'String', integer: 'Integer', long: 'Long', decimal: 'Decimal', boolean: 'Boolean',
    datetime: 'Date and time', enum: 'Enumeration', autonumber: 'AutoNumber', binary: 'Binary',
    hashstring: 'Hashed string', float: 'Float', currency: 'Currency'
  };
  return `${attribute.name} (${types[attribute.type?.toLowerCase()] ?? attribute.type})`;
}
