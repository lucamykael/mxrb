import type { StudioRpc } from './rpc';
import type { ProjectStatus, StudioContext } from './types';

/** Resolve at execution time: another dock may have converted or attached the project. */
export async function taskWorkspace(rpc: Pick<StudioRpc, 'call'>, context: StudioContext, signal: AbortSignal, requiresRuby = false) {
  signal.throwIfAborted();
  let rubyRoot = context.ruby_root;
  if (!rubyRoot && context.source_model) {
    const project = await rpc.call<ProjectStatus>('project/status', { source_model: context.source_model }, { signal });
    signal.throwIfAborted();
    if (project.state === 'ready') rubyRoot = project.root ?? undefined;
  }
  if (requiresRuby && !rubyRoot) throw new Error('Convert or link this project in Ruby App Explorer before running Ruby tasks.');
  const directory = rubyRoot ?? context.root;
  if (!directory) throw new Error('Open a project to run tasks.');
  const substitutions: Record<string, string> = { '{root}': directory };
  if (context.source_model) substitutions['{mpr}'] = context.source_model;
  if (rubyRoot) substitutions['{ruby}'] = rubyRoot;
  return { directory, substitutions };
}
