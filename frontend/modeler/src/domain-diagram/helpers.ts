import type {
  Anchor,
  AttributeMode,
  DiagramAssociation,
  DiagramEntity,
  PathGeometry,
  RoutingMode,
} from "./types";

export const CARD_WIDTH = 248;
export const HEAD_HEIGHT = 34;
export const ROW_HEIGHT = 23;
export const WORLD_WIDTH = 6000;
export const WORLD_HEIGHT = 4000;

export function visibleAttributes(entity: DiagramEntity, mode: AttributeMode) {
  if (mode === "none") return [];
  if (mode === "keys") return entity.attributes.filter((attribute) => attribute.key);
  return entity.attributes;
}

export function cardHeight(entity: DiagramEntity, mode: AttributeMode) {
  const attributes = visibleAttributes(entity, mode);
  return HEAD_HEIGHT + (attributes.length ? attributes.length * ROW_HEIGHT + 6 : 30);
}

export function kindLabel(entity: DiagramEntity) {
  if (entity.kind === "oql_view") return "OQL view";
  if (entity.kind === "dto") return "DTO / non-persistent";
  return "Entidade persistente";
}

export function kindCode(entity: DiagramEntity) {
  if (entity.kind === "oql_view") return "OQL";
  if (entity.kind === "dto") return "DTO";
  return "E";
}

export function anchorPoint(
  entity: DiagramEntity,
  side: Anchor,
  mode: AttributeMode,
): [number, number] {
  const height = cardHeight(entity, mode);
  if (side === "north") return [entity.x + CARD_WIDTH / 2, entity.y];
  if (side === "east") return [entity.x + CARD_WIDTH, entity.y + height / 2];
  if (side === "south") return [entity.x + CARD_WIDTH / 2, entity.y + height];
  return [entity.x, entity.y + height / 2];
}

export function pathFor(
  association: DiagramAssociation,
  entities: Record<string, DiagramEntity>,
  mode: AttributeMode,
  routing: RoutingMode,
): PathGeometry | null {
  const from = entities[association.from];
  const to = entities[association.to];
  if (!from || !to) return null;

  const [x1, y1] = anchorPoint(from, association.source_anchor, mode);
  const [x2, y2] = anchorPoint(to, association.target_anchor, mode);
  if (routing === "shortest") {
    return { d: `M${x1},${y1} L${x2},${y2}`, x: (x1 + x2) / 2, y: (y1 + y2) / 2 };
  }

  const vertical = association.source_anchor === "north" || association.source_anchor === "south";
  const d = vertical
    ? `M${x1},${y1} L${x1},${(y1 + y2) / 2} L${x2},${(y1 + y2) / 2} L${x2},${y2}`
    : `M${x1},${y1} L${(x1 + x2) / 2},${y1} L${(x1 + x2) / 2},${y2} L${x2},${y2}`;
  return { d, x: (x1 + x2) / 2, y: (y1 + y2) / 2 };
}

export function closestAnchor(
  entity: DiagramEntity,
  x: number,
  y: number,
  mode: AttributeMode,
): Anchor {
  const anchors: Anchor[] = ["north", "east", "south", "west"];
  return anchors
    .map((anchor) => ({ anchor, point: anchorPoint(entity, anchor, mode) }))
    .sort(
      (a, b) =>
        Math.hypot(a.point[0] - x, a.point[1] - y) -
        Math.hypot(b.point[0] - x, b.point[1] - y),
    )[0].anchor;
}
