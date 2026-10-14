// A small AMD loader for the Dojo widgets of a project's widget packages. Their
// sources come from the package (never fetched); dojo, dijit and mxui modules
// resolve to the shims the host provides.
type Factory = (...dependencies: unknown[]) => unknown;
type Definition = { dependencies: string[]; factory: unknown };

export type ModuleSources = Record<string, string>;

const normalize = (id: string, base: string): string => {
  if (!id.startsWith('.')) return id;
  const parts = base.split('/').slice(0, -1);
  for (const part of id.split('/')) {
    if (part === '..') parts.pop();
    else if (part !== '.') parts.push(part);
  }
  return parts.join('/');
};

export class AmdLoader {
  private readonly modules = new Map<string, unknown>();
  private readonly loading = new Map<string, Promise<unknown>>();

  constructor(
    private readonly sources: ModuleSources,
    builtins: Record<string, unknown> = {},
  ) {
    Object.entries(builtins).forEach(([id, value]) => this.modules.set(id, value));
  }

  // The module of an id: a shim, a "dojo/text!" template or a package source.
  load(id: string, base = ''): Promise<unknown> {
    const plugin = id.indexOf('!');
    if (plugin >= 0) return this.text(normalize(id.slice(plugin + 1), base));
    const name = normalize(id, base);
    if (this.modules.has(name)) return Promise.resolve(this.modules.get(name));
    const pending = this.loading.get(name);
    if (pending) return pending;
    const task = this.execute(name).then((value) => {
      this.modules.set(name, value);
      return value;
    });
    this.loading.set(name, task);
    return task;
  }

  private text(path: string): Promise<unknown> {
    const source = this.sources[path] ?? this.sources[path.replace(/\.[^./]+$/, '')];
    if (source === undefined)
      return Promise.reject(new Error(`Widget template ${path} is missing`));
    return Promise.resolve(source);
  }

  private async execute(name: string): Promise<unknown> {
    const source = this.sources[name] ?? this.sources[`${name}.js`];
    if (source === undefined) throw new Error(`Widget module ${name} is missing`);
    const definitions: Definition[] = [];
    const define = (...args: unknown[]) => {
      const values = typeof args[0] === 'string' ? args.slice(1) : args;
      const dependencies = Array.isArray(values[0]) ? (values[0] as string[]) : [];
      const factory = Array.isArray(values[0]) ? values[1] : values[0];
      definitions.push({ dependencies, factory });
    };
    define.amd = { jQuery: true };
    const require = (dependencies: string[] | string, callback?: Factory) => {
      if (typeof dependencies === 'string') return this.modules.get(normalize(dependencies, name));
      // Deferred: a widget file requires its own module while it is still loading.
      void Promise.resolve()
        .then(() => Promise.all(dependencies.map((id) => this.load(id, name))))
        .then((values) => callback?.(...values));
      return undefined;
    };
    // Library sources (jQuery, bootstrap) also install globals when they see no module system.
    const module = { exports: {} as unknown };
    new Function('define', 'require', 'module', 'exports', source)(
      define,
      require,
      undefined,
      module.exports,
    );
    // A file defines its module once; a library may define further named ones.
    const definition = definitions[0];
    if (!definition) return module.exports;
    return this.instantiate(definition, name, module);
  }

  private async instantiate(
    { dependencies, factory }: Definition,
    name: string,
    module: { exports: unknown },
  ): Promise<unknown> {
    if (typeof factory !== 'function') return factory;
    const values = await Promise.all(
      dependencies.map((id) => {
        if (id === 'require')
          return (dependency: string) => this.modules.get(normalize(dependency, name));
        if (id === 'exports') return module.exports;
        if (id === 'module') return module;
        return this.load(id, name);
      }),
    );
    const result = (factory as Factory)(...values);
    return result === undefined ? module.exports : result;
  }
}
