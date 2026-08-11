import { requestJson } from "../shared/api";
import type { ProjectCatalog } from "./types";

export function fetchProject(signal?: AbortSignal): Promise<ProjectCatalog> {
  return requestJson<ProjectCatalog>("./api/project", { signal });
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function matchesSearch(value: string, search: string): boolean {
  return value.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase());
}

export function readableType(type: string): string {
  return type.split("$").at(-1)?.replaceAll(/([a-z])([A-Z])/g, "$1 $2") ?? type;
}
