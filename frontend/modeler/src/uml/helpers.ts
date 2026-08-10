import { requestJson } from "../shared/api";
import { downloadText } from "../shared/download";
import type { Catalog, DiagramPayload, DiagramSelection, SourceFormat } from "./types";

function query(params: Record<string, string>): string {
  return new URLSearchParams(params).toString();
}

export function diagramEndpoint(selection: DiagramSelection): string {
  switch (selection.kind) {
    case "class":
      return `/api/class?${query({ modules: selection.modules })}`;
    case "activity":
      return `/api/activity?${query({ microflow: selection.microflow })}`;
    case "sequence":
      return `/api/sequence?${query({
        [selection.sequenceMode]: selection.sequenceValue,
        depth: selection.depth,
      })}`;
  }
}

export async function fetchCatalog(signal?: AbortSignal): Promise<Catalog> {
  return requestJson<Catalog>("/api/catalog", { signal });
}

export async function fetchDiagram(
  selection: DiagramSelection,
  signal?: AbortSignal,
): Promise<DiagramPayload> {
  return requestJson<DiagramPayload>(diagramEndpoint(selection), { signal });
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function downloadSource(
  payload: DiagramPayload,
  format: SourceFormat,
  kind: DiagramSelection["kind"],
): void {
  const extension = format === "mermaid" ? "mmd" : "puml";
  downloadText(`mxrb-${kind}.${extension}`, payload[format]);
}
