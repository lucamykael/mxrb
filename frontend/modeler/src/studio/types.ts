export type StudioContext = {
  panel?: PanelKind;
  root?: string; source_model?: string; ruby_root?: string;
  project_revision?: number;
  database_port?: number;
  database_runtime_port?: number;
  theme?: Record<string, string>;
  capabilities?: { native_ruby_editor?: boolean; native_dialogs?: boolean };
};
export type PanelKind = 'explorer' | 'tasks' | 'er' | 'database' | 'parity';
export type Entry = { name: string; path: string; directory: boolean; size: number };
export type FileContent = { path: string; text: string; revision: string };
export type CommandField = { key: string; label: string; kind: string; required: boolean;
  default: string | boolean | null; choices: string[] };
export type Command = { name: string; summary: string; context: string; effect: string; fields: CommandField[] };
export type ProjectStatus = { state: string; root: string | null; source_model: string };
