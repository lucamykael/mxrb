import type { StudioRpc } from './rpc';
import type { ProjectStatus, StudioContext } from './types';

export type Revisions = { model: string; ruby: string };
export type Diagnostic = { file?: string; path?: string; line: number; column?: number; severity?: string; message: string };
export type RubyChange = { path: string; action: string; diagnostics: Diagnostic[];
  artifacts: { kind: string; name: string; qualified_name: string; line: number }[] };
export type MendixChange = { unit_id: string; action: string; type?: string; name?: string };
export type SyncDocument = { unit_id: string; type?: string | null; qualified_name?: string | null; ruby?: string | null;
  mendix?: string | null; files: string[]; diagnostics: Diagnostic[]; conflicts: string[]; state: SyncState };
export type Value = { present: boolean; value?: unknown };
export type Conflict = {
  id: string; kind: 'element' | 'unit' | 'file'; resolutions: Resolution[];
  unit_id?: string; type?: string; name?: string; key?: string; reason?: string;
  element?: { type?: string; name?: string; path?: string } | null;
  ruby_operation?: string; mendix_operation?: string; base?: Value; mendix?: Value | string | null; ruby?: Value | string | null;
  path?: string; hunks?: number;
};
export type SyncState = 'synced' | 'pending' | 'conversion_error' | 'conflict';
export type Resolution = 'ruby' | 'mendix';
export type SyncStatus = { linked: false; state: 'unlinked'; model: string; ruby_root: string } | {
  linked: true; state: SyncState; model: string; ruby_root: string; synced_at: string; revisions: Revisions;
  ruby_changes: RubyChange[]; mendix_changes: MendixChange[]; conflicts: Conflict[]; diverged: string[];
  documents: SyncDocument[] };
export type Comparison = { dry_run: boolean; applied: boolean; state: string; revisions: Revisions;
  ruby_units: string[]; mendix_units: string[]; files: { path: string; action: string }[]; conflicts: Conflict[] };
export type ApplyResult = Comparison & { history?: unknown };

/** Wording shared with the native document bar and the Ruby editor indicator. */
export const STATE_LABELS: Record<SyncState | 'unlinked' | 'unconverted', string> = {
  synced: 'In sync', pending: 'Changes pending', conversion_error: 'Ruby has errors', conflict: 'Conflict',
  unlinked: 'Not linked', unconverted: 'No Ruby representation',
};

export const CHANGE_LABELS: Record<string, string> = {
  added: 'Added', removed: 'Deleted', modified: 'Modified', delete: 'Deleted', write: 'Updated',
};

export function documentName(document: Pick<SyncDocument, 'qualified_name' | 'type' | 'unit_id'>) {
  if (document.qualified_name) return document.type === 'DomainModels$DomainModel'
    ? `${document.qualified_name} (domain model)` : document.qualified_name;
  return document.type ? `${typeName(document.type)} ${document.unit_id.slice(0, 8)}` : document.unit_id;
}

/** `Microflows$Microflow` → `Microflow`. */
export function typeName(type?: string | null) {
  return (type ?? '').split('$').pop()!.replace(/([a-z])([A-Z])/g, '$1 $2');
}

export function conflictTitle(conflict: Conflict) {
  if (conflict.kind === 'file') return `Ruby file ${conflict.path}`;
  const document = conflict.name ? `${conflict.name}` : typeName(conflict.type);
  if (conflict.kind === 'unit') return `${document}: ${conflict.reason}`;
  const element = conflict.element?.name ? `${conflict.element.name}` : typeName(conflict.element?.type);
  return `${document} › ${element}${conflict.key ? `.${conflict.key}` : ''}`;
}

export function display(value: Value | string | null | undefined): string {
  if (value === null || value === undefined) return '(absent)';
  if (typeof value === 'string') return value;
  if (!value.present) return '(absent)';
  return typeof value.value === 'string' ? value.value : JSON.stringify(value.value, null, 2) ?? '(empty)';
}

/** Apply needs a comparison of the current revisions and a choice for every conflict it found. */
export function readiness(status: SyncStatus | undefined, comparison: Comparison | undefined, choices: Record<string, Resolution>) {
  if (!status?.linked) return { ready: false, reason: 'Link the Ruby project first.' };
  if (!comparison) return { ready: false, reason: 'Compare the Ruby and Mendix changes first.' };
  if (comparison.revisions.model !== status.revisions.model || comparison.revisions.ruby !== status.revisions.ruby)
    return { ready: false, reason: 'The model or the Ruby files changed after the comparison. Compare again.' };
  const open = comparison.conflicts.filter(conflict => !choices[conflict.id]);
  if (open.length) return { ready: false, reason: `Choose Ruby or Mendix for ${open.length} conflict${open.length === 1 ? '' : 's'}.` };
  if (!comparison.ruby_units.length && !comparison.files.length && !comparison.mendix_units.length)
    return { ready: false, reason: 'Nothing to synchronize.' };
  return { ready: true, reason: '' };
}

export function applyParameters(context: StudioContext, comparison: Comparison, choices: Record<string, Resolution>) {
  const resolutions = Object.fromEntries(comparison.conflicts.map(conflict => [conflict.id, choices[conflict.id]]));
  return { source_model: context.source_model, expected_revisions: comparison.revisions, resolutions };
}

/** Resolve at call time: Explorer may just have converted or linked the project. */
export async function rubyProject(rpc: Pick<StudioRpc, 'call'>, context: StudioContext, signal: AbortSignal) {
  if (!context.source_model) return undefined;
  const project = await rpc.call<ProjectStatus>('project/status', { source_model: context.source_model }, { signal });
  return project.state === 'ready' && project.root ? project.root : undefined;
}
