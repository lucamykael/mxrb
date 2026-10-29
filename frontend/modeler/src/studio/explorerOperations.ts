import type { Entry } from './types';

/** Pure path bookkeeping for Ruby App Explorer operations; the backend owns the filesystem. */
export function parentOf(path: string) {
  const index = path.lastIndexOf('/');
  return index < 0 ? '.' : path.slice(0, index);
}

export function childPath(folder: string, name: string) {
  return folder === '.' ? name : `${folder}/${name}`;
}

/** The folder a new item goes into: the selected folder, or the selected file's folder. */
export function targetFolder(selected: Entry | undefined) {
  if (!selected) return '.';
  return selected.directory ? selected.path : parentOf(selected.path);
}

export function validateName(name: string) {
  const trimmed = name.trim();
  if (!trimmed) return 'Enter a name.';
  if (trimmed === '.' || trimmed === '..') return 'This name is reserved.';
  if (/[/\0]/.test(trimmed)) return 'A name cannot contain "/".';
  if (trimmed === '.git') return 'Git metadata cannot be created here.';
  if (new TextEncoder().encode(trimmed).length > 255) return 'The name is too long.';
  return '';
}

const within = (path: string, folder: string) => path === folder || path.startsWith(`${folder}/`);

/** Drops cached listings and expansion of a deleted or moved path and everything below it. */
export function forget(entries: Record<string, Entry[]>, expanded: Set<string>, path: string) {
  const nextEntries = Object.fromEntries(Object.entries(entries).filter(([key]) => !within(key, path)));
  const nextExpanded = new Set([...expanded].filter(key => !within(key, path)));
  return { entries: nextEntries, expanded: nextExpanded };
}

/** Keeps a renamed folder expanded (and its expanded descendants) under the new path. */
export function moveExpansion(expanded: Set<string>, from: string, to: string) {
  return new Set([...expanded].map(key => within(key, from) ? to + key.slice(from.length) : key));
}

/** A sibling worktree directory for a branch: `<root>-<branch>` with path separators flattened. */
export function worktreePath(root: string, branch: string) {
  const suffix = branch.trim().replace(/[^\w.-]+/g, '-').replace(/^-+|-+$/g, '') || 'worktree';
  return `${root.replace(/\/+$/, '')}-${suffix}`;
}
