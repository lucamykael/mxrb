export type DiagramKind = "class" | "activity" | "sequence";

export type SequenceMode = "root" | "module";

export type SourceFormat = "mermaid" | "plantuml";

export interface Catalog {
  modules: string[];
  microflows: string[];
}

export interface DiagramPayload {
  mermaid: string;
  plantuml: string;
}

export interface DiagramSelection {
  kind: DiagramKind;
  modules: string;
  microflow: string;
  sequenceMode: SequenceMode;
  sequenceValue: string;
  depth: string;
}
