export type StudioContext = {
  panel?: 'explorer' | 'tasks';
  root?: string; source_model?: string; ruby_root?: string;
  project_revision?: number;
  theme?: Record<string, string>;
  capabilities?: { native_ruby_editor?: boolean };
};
export type Entry = { name: string; path: string; directory: boolean; size: number };
export type FileContent = { path: string; text: string; revision: string };
export type CommandField = { key: string; label: string; kind: string; required: boolean;
  default: string | boolean | null; choices: string[] };
export type Command = { name: string; summary: string; context: string; effect: string; fields: CommandField[] };
export type ProjectStatus = { state: string; root: string | null; source_model: string };
