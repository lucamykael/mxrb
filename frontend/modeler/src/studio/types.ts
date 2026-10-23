export type StudioContext = {
  root?: string; source_model?: string; ruby_root?: string;
  theme?: Record<string, string>;
};
export type Entry = { name: string; path: string; directory: boolean; size: number };
export type FileContent = { path: string; text: string; revision: string };
export type CommandField = { key: string; label: string; kind: string; required: boolean;
  default: string | boolean | null; choices: string[] };
export type Command = { name: string; summary: string; context: string; effect: string; fields: CommandField[] };
export type ProjectStatus = { state: string; root: string | null; source_model: string };
