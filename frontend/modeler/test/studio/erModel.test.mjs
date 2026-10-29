import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BOX_WIDTH, MAX_ROWS, borderPoint, boxHeight, cardinality, category, edge, edgeOffsets, indexColumns, layout,
  neighbourhood, searchMatches, visibleGraph
} from '../../src/studio/erModel.ts';

const attribute = name => ({ name, type: 'string', required: false, key: false });
const entity = (qualified, extra = {}) => {
  const [module, name] = qualified.split('.');
  return { id: qualified, name, qualified_name: qualified, module, kind: 'entity', persistent: true,
    attributes: [attribute('Name')], x: 0, y: 0, ...extra };
};

const model = {
  modules: [{ name: 'Sales', entities: [] }, { name: 'Logistics', entities: [] }, { name: 'Empty', entities: [] }],
  entities: [
    entity('Sales.Customer', { x: 100, y: 100 }),
    entity('Sales.Order', { x: 400, y: 100 }),
    entity('Sales.Payload', { kind: 'dto', persistent: false, x: 100, y: 300 }),
    entity('Sales.Summary', { kind: 'oql_view', x: 400, y: 300 }),
    entity('Sales.Account', { persistent: null, generalization: 'System.User', x: 700, y: 100 }),
    entity('Logistics.Shipment', { x: 50, y: 40, attributes: [attribute('TrackingCode'), attribute('Carrier')] })
  ],
  relationships: [
    { id: 'a1', kind: 'association', name: 'Order_Customer', from: 'Sales.Order', to: 'Sales.Customer', type: 'Reference', owner: 'Default', cross_module: false },
    { id: 'a2', kind: 'association', name: 'Order_Shipment', from: 'Sales.Order', to: 'Logistics.Shipment', type: 'ReferenceSet', owner: 'Both', cross_module: true },
    { id: 'i1', kind: 'inheritance', from: 'Sales.Account', to: 'System.User', cross_module: true, target_resolved: false }
  ],
  external_entities: ['System.User']
};
const all = new Set(['Sales', 'Logistics']);

test('classifies persistable, non-persistable, view, unresolved and external entities', () => {
  assert.deepEqual(model.entities.map(category), ['persistent', 'persistent', 'non_persistent', 'view', 'unresolved', 'persistent']);
  assert.equal(category(undefined), 'external');
});

test('labels Reference as many-to-one and ReferenceSet as many-to-many, with owner both', () => {
  assert.deepEqual(cardinality(model.relationships[0]), { from: '*', to: '1', label: '* – 1' });
  assert.deepEqual(cardinality(model.relationships[1]), { from: '*', to: '*', label: '* – * (owner: both)' });
  assert.equal(cardinality(model.relationships[2]).label, 'generalization');
});

test('filters modules and relationship kinds, keeping placeholders only for entities outside the model', () => {
  const full = visibleGraph(model, { modules: all, relationships: 'all' });
  assert.equal(full.entities.length, 6);
  assert.deepEqual(full.relationships.map(r => r.id), ['a1', 'a2', 'i1']);
  assert.deepEqual(full.externals, ['System.User']);
  const sales = visibleGraph(model, { modules: new Set(['Sales']), relationships: 'all' });
  assert.deepEqual(sales.relationships.map(r => r.id), ['a1', 'i1'], 'an edge into a hidden module is hidden');
  assert.deepEqual(visibleGraph(model, { modules: all, relationships: 'cross_module' }).relationships.map(r => r.id), ['a2', 'i1']);
  assert.deepEqual(visibleGraph(model, { modules: all, relationships: 'inheritance' }).relationships.map(r => r.id), ['i1']);
  const associations = visibleGraph(model, { modules: all, relationships: 'associations' });
  assert.deepEqual(associations.externals, [], 'no placeholder without a visible edge');
});

test('searches entity and attribute names case-insensitively', () => {
  assert.equal(searchMatches(model.entities, ' '), null);
  assert.deepEqual([...searchMatches(model.entities, 'tracking')], ['Logistics.Shipment']);
  assert.deepEqual([...searchMatches(model.entities, 'sales.o')], ['Sales.Order']);
});

test('collects the neighbourhood in both directions up to the requested depth', () => {
  assert.deepEqual([...neighbourhood(model.relationships, 'Sales.Customer', 1)].sort(), ['Sales.Customer', 'Sales.Order']);
  assert.deepEqual([...neighbourhood(model.relationships, 'Sales.Customer', 2)].sort(),
    ['Logistics.Shipment', 'Sales.Customer', 'Sales.Order']);
});

test('keeps Mendix positions inside module frames, packs frames deterministically and never overlaps boxes', () => {
  const graph = visibleGraph(model, { modules: all, relationships: 'all' });
  const modules = model.modules.map(module => ({ name: module.name, entities: graph.entities.filter(e => e.module === module.name) }));
  const first = layout(modules, graph.externals);
  const second = layout(modules, graph.externals);
  assert.deepEqual([...first.boxes.entries()], [...second.boxes.entries()]);
  assert.deepEqual(first.frames.map(frame => frame.name), ['Sales', 'Logistics', 'Outside the model']);
  const customer = first.boxes.get('Sales.Customer'), order = first.boxes.get('Sales.Order');
  assert.equal(order.x - customer.x, 300, 'relative Mendix x positions are preserved');
  assert.equal(order.y, customer.y);
  const boxes = [...first.boxes.values()];
  for (const a of boxes) for (const b of boxes) {
    if (a === b) continue;
    assert.ok(a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y, `${a.name} overlaps ${b.name}`);
  }
  for (const frame of first.frames) for (const box of boxes.filter(box => box.name.startsWith(frame.name) || frame.external && box.name === 'System.User')) {
    assert.ok(box.x >= frame.x && box.x + box.width <= frame.x + frame.width && box.y + box.height <= frame.y + frame.height, `${box.name} in ${frame.name}`);
  }
});

test('nudges entities that share a Mendix position and caps attribute rows', () => {
  const crowded = Array.from({ length: 3 }, (_, index) => entity(`M.E${index}`, { x: 10, y: 10 }));
  const result = layout([{ name: 'M', entities: crowded }], []);
  const xs = [...result.boxes.values()].map(box => box.x);
  assert.equal(new Set(xs).size, 3);
  assert.ok(Math.min(...xs.slice(1).map((x, i) => x - xs[i])) >= BOX_WIDTH);
  assert.equal(boxHeight(40), boxHeight(MAX_ROWS + 1));
  const big = layout([{ name: 'M', entities: [entity('M.Big', { attributes: Array.from({ length: 30 }, (_, i) => attribute(`A${i}`)) })] }], []);
  assert.deepEqual([big.boxes.get('M.Big').rows, big.boxes.get('M.Big').hidden], [MAX_ROWS, 30 - MAX_ROWS]);
});

test('lays out 600 entities quickly', () => {
  const many = Array.from({ length: 20 }, (_, m) => ({ name: `Module${m}`, entities: Array.from({ length: 30 }, (_, e) =>
    entity(`Module${m}.Entity${e}`, { x: (e % 6) * 260, y: Math.floor(e / 6) * 220 })) }));
  const started = performance.now();
  const result = layout(many, []);
  assert.equal(result.boxes.size, 600);
  assert.ok(performance.now() - started < 500);
});

test('routes edges from box borders and spreads parallel associations', () => {
  const box = { name: 'A', x: 0, y: 0, width: 100, height: 50, rows: 0, hidden: 0 };
  assert.deepEqual(borderPoint(box, 200, 25), { x: 100, y: 25 });
  assert.deepEqual(borderPoint(box, 50, -100), { x: 50, y: 0 });
  const boxes = new Map([['A', box], ['B', { ...box, name: 'B', x: 300 }]]);
  const parallel = [{ id: 'p1', kind: 'association', from: 'A', to: 'B' }, { id: 'p2', kind: 'association', from: 'B', to: 'A' }];
  const offsets = edgeOffsets(parallel);
  const one = edge(parallel[0], boxes, offsets.get('p1')), two = edge(parallel[1], boxes, offsets.get('p2'));
  assert.notEqual(one.y1, two.y2);
  assert.equal(edge({ id: 'x', kind: 'association', from: 'A', to: 'Missing' }, boxes), null);
  assert.equal(edge({ id: 's', kind: 'association', from: 'A', to: 'A' }, boxes).self, true);
});

test('reads native index members as attribute names', () => {
  assert.deepEqual(indexColumns({ Attributes: [3, { Attribute: 'Sales.Order.Number' }, { Attribute: 'Sales.Order.Date', Ascending: false }] }),
    ['Number', 'Date (descending)']);
  assert.deepEqual(indexColumns(null), []);
});
