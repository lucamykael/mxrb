import type { Command } from './types';

export type SavedTask = { id: string; name: string; command_id: string; values: Record<string, string | boolean>;
  extra: string; created_at?: string; updated_at?: string };

/** Catalog contexts as IntelliJ-style groups, in the order a Mendix developer reaches for them. */
export const GROUPS: [string, string][] = [
  ['model', 'Model'], ['ruby', 'Ruby project'], ['database', 'Database'], ['repository', 'Repository'], ['global', 'General']
];

export function matches(command: Command, filter: string) {
  const needle = filter.trim().toLowerCase();
  return !needle || `${command.name} ${command.summary}`.toLowerCase().includes(needle);
}

export function groupCommands(catalog: Command[], filter: string) {
  const known = new Set(GROUPS.map(([key]) => key));
  const groups = GROUPS.map(([key, title]) => ({ key, title, commands: [] as Command[] }));
  const other = { key: 'other', title: 'Other', commands: [] as Command[] };
  for (const command of catalog) {
    if (!matches(command, filter)) continue;
    (known.has(command.context) ? groups.find(group => group.key === command.context)! : other).commands.push(command);
  }
  for (const group of [...groups, other]) group.commands.sort((left, right) => left.name.localeCompare(right.name));
  return [...groups, other].filter(group => group.commands.length > 0);
}

export function filterSaved(saved: SavedTask[], filter: string) {
  const needle = filter.trim().toLowerCase();
  return saved.filter(task => !needle || `${task.name} ${task.command_id}`.toLowerCase().includes(needle))
    .sort((left, right) => left.name.localeCompare(right.name));
}

/** Only values that differ from the catalog default are stored, so defaults keep tracking the catalog. */
export function changedValues(command: Command, values: Record<string, string | boolean>) {
  const result: Record<string, string | boolean> = {};
  for (const field of command.fields) {
    if (!(field.key in values)) continue;
    const value = values[field.key];
    if (value !== (field.default ?? (field.kind === 'boolean' ? false : ''))) result[field.key] = value;
  }
  return result;
}

/** A readable default name: the command plus its first explicit argument. */
export function suggestName(command: Command, values: Record<string, string | boolean>) {
  const first = Object.values(changedValues(command, values)).find(value => typeof value === 'string' && value);
  return first ? `${command.name} ${String(first).split('/').pop()}` : command.name;
}

export type OutputChunk = { stream: 'stdout' | 'stderr' | 'system'; text: string };

/** Appends output while keeping the most recent `limit` characters. */
export function appendOutput(chunks: OutputChunk[], next: OutputChunk, limit = 1_048_576) {
  const last = chunks[chunks.length - 1];
  const merged = last && last.stream === next.stream
    ? [...chunks.slice(0, -1), { stream: last.stream, text: last.text + next.text }] : [...chunks, next];
  let size = merged.reduce((total, chunk) => total + chunk.text.length, 0);
  while (size > limit && merged.length > 0) {
    const excess = size - limit;
    if (merged[0].text.length <= excess) { size -= merged[0].text.length; merged.shift(); }
    else { merged[0] = { ...merged[0], text: merged[0].text.slice(excess) }; size = limit; }
  }
  return merged;
}
