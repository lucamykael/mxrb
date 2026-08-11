export type EntityKind = "entity" | "dto" | "oql_view";
export type Anchor = "north" | "east" | "south" | "west";
export type AttributeMode = "all" | "keys" | "none";
export type RoutingMode = "orthogonal" | "shortest";

export interface DiagramAttribute {
  key: boolean;
  name: string;
  required: boolean;
  type: string;
}

export interface DiagramEntity {
  attributes: DiagramAttribute[];
  id: string;
  kind: EntityKind;
  module: string;
  name: string;
  qualified_name: string;
  x: number;
  y: number;
}

export interface DiagramAssociation {
  anchor_dirty?: boolean;
  anchor_storage: "native" | string;
  cross_module?: boolean;
  from: string;
  id: string;
  module?: string;
  name: string;
  owner: string;
  source_anchor: Anchor;
  target_anchor: Anchor;
  to: string;
  type: string;
}

export interface DiagramModule {
  associations: DiagramAssociation[];
  entities: DiagramEntity[];
  name: string;
}

export interface DiagramData {
  csrf_token: string;
  module_filter_applied: boolean;
  modules: DiagramModule[];
  output: string;
  project: {
    mendix_version: string;
    name: string;
  };
}

export type Selection =
  | { kind: "entity"; id: string }
  | { kind: "association"; id: string }
  | null;

export interface PathGeometry {
  d: string;
  x: number;
  y: number;
}

export interface LayoutPayload {
  modules: Array<{
    name: string;
    entities: Array<{ id: string; x: number; y: number }>;
    associations: Array<{
      id: string;
      source_anchor: Anchor;
      target_anchor: Anchor;
    }>;
  }>;
}

export interface LayoutResult {
  changed: number;
  error?: string;
}
