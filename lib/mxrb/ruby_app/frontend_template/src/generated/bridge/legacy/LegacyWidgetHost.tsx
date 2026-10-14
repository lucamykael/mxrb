import { useEffect, useRef, useState } from 'react';
import { useCaptionEnvironment } from '../captions';
import { api } from '../api';
import { registerMarketplaceWidget, type MarketplaceWidgetProps } from '../marketplace';
import { memberName } from '../value';
import type { EntityRecord } from '../../types';
import { AmdLoader, type ModuleSources } from './amd';
import { dojoModules, kernel } from './dojo';
import { installMx, mxForm, mxuiModules, MxStore, type MxSave, type MxSession } from './mx';

// A property of a legacy widget, as its package declares it.
export interface LegacyPropertyDefinition {
  key: string;
  type?: string;
  list?: boolean;
  default?: string;
  properties?: LegacyPropertyDefinition[];
}

type Properties = Record<string, unknown>;
type Widget = {
  domNode?: Element;
  startup?(): void;
  update?(object: unknown, callback?: () => void): void;
  destroy?(): void;
  uninitialize?(): void;
};
type WidgetClass = new (params: Properties, node: Element) => Widget;

const object = (value: unknown): Properties =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Properties) : {};

const translated = (value: unknown, locale: string): string => {
  if (typeof value === 'string') return value;
  const texts = object(value);
  const code = locale.replace('-', '_');
  const text = texts[code] ?? texts[code.split('_')[0]] ?? texts.en_US ?? Object.values(texts)[0];
  return typeof text === 'string' ? text : '';
};

// The value the Mendix client hands a legacy widget for one property.
export function legacyValue(
  definition: LegacyPropertyDefinition,
  value: unknown,
  locale: string,
): unknown {
  const fallback = definition.default ?? '';
  switch (definition.type) {
    case 'Object': {
      const objects = Array.isArray(object(value).objects)
        ? (object(value).objects as Properties[])
        : [];
      return objects.map((item) => legacyParams(definition.properties ?? [], item, locale));
    }
    case 'TranslatableString':
      return translated(value ?? fallback, locale);
    case 'Attribute':
      return typeof value === 'string' ? memberName(value) : '';
    case 'Boolean':
      return typeof value === 'boolean' ? value : fallback === 'true';
    case 'Integer':
    case 'Decimal':
      return typeof value === 'number' ? value : Number(fallback || 0);
    case 'Entity':
    case 'EntityConstraint':
    case 'Microflow':
    case 'Nanoflow':
    case 'Form':
    case 'Image':
      return typeof value === 'string' ? value : '';
    default:
      return value ?? fallback;
  }
}

export const legacyParams = (
  definitions: LegacyPropertyDefinition[],
  values: Properties,
  locale: string,
): Properties =>
  Object.fromEntries(
    definitions.map((definition) => [
      definition.key,
      legacyValue(definition, values[definition.key], locale),
    ]),
  );

interface LegacyWidgetPackage {
  sources: ModuleSources;
  entry: string;
  definitions: LegacyPropertyDefinition[];
}

// Runs a Dojo widget of the project's widget package in place of the widget.
export function LegacyWidgetHost({
  props,
  pkg,
}: {
  props: MarketplaceWidgetProps;
  pkg: LegacyWidgetPackage;
}) {
  const container = useRef<HTMLDivElement>(null);
  const widget = useRef<Widget | null>(null);
  // The id of the context object the widget last received in update().
  const shown = useRef<string | null>(null);
  const store = useRef<MxStore | null>(null);
  const session = useLegacySession();
  const { locale } = useCaptionEnvironment(props.schema);
  const [error, setError] = useState('');
  const latest = useRef(props);
  latest.current = props;
  // Changes to the context object are saved through the page, as any other edit.
  const save = useRef<MxSave>(async (_record, member, value) => {
    const result = await latest.current.onChange(member, value);
    return result && typeof result === 'object' && 'id' in result ? (result as EntityRecord) : null;
  }).current;
  const properties = JSON.stringify(props.widget.options?.properties ?? {});

  useEffect(() => {
    const host = container.current;
    if (!host || !session) return;
    let active = true;
    const mxStore = installMx({
      schema: latest.current.schema,
      request: latest.current.request,
      session,
      locale,
    });
    store.current = mxStore;
    kernel.locale = locale;
    const loader = new AmdLoader(pkg.sources, { ...dojoModules(), ...mxuiModules(mxStore) });
    loader
      .load(pkg.entry)
      .then((module) => {
        if (!active) return;
        // A webpack-built widget returns its ES module rather than the class.
        const Widget = (typeof module === 'function' ? module : object(module).default) as
          WidgetClass | undefined;
        if (typeof Widget !== 'function') throw new Error(`${pkg.entry} defines no widget class`);
        const node = document.createElement('div');
        host.replaceChildren(node);
        const params = legacyParams(pkg.definitions, JSON.parse(properties) as Properties, locale);
        const instance = new Widget(
          {
            ...params,
            ...mxForm(host, mxStore, () => latest.current.context, save),
            class: String(latest.current.widget.options?.class || ''),
          },
          node,
        );
        if (instance.domNode && !instance.domNode.isConnected)
          host.replaceChildren(instance.domNode);
        widget.current = instance;
        instance.startup?.();
        const context = latest.current.context;
        shown.current = context?.id ?? null;
        instance.update?.(context ? mxStore.remember(context, save) : null, () => undefined);
        setError('');
      })
      .catch((failure: unknown) => {
        console.error(failure);
        if (active) setError(failure instanceof Error ? failure.message : String(failure));
      });
    return () => {
      active = false;
      const instance = widget.current;
      widget.current = null;
      try {
        if (instance?.destroy) instance.destroy();
        else instance?.uninitialize?.();
      } catch (failure) {
        console.error(failure);
      }
    };
  }, [pkg, properties, locale, session]);

  // Another context object reaches the widget through update(); a refreshed one
  // notifies its subscriptions, as in Mendix.
  const contextKey = JSON.stringify(props.context);
  useEffect(() => {
    const instance = widget.current;
    const mxStore = store.current;
    const context = latest.current.context;
    if (!instance || !mxStore) return;
    const previous = shown.current;
    shown.current = context?.id ?? null;
    if (!context) {
      if (previous !== null) instance.update?.(null, () => undefined);
      return;
    }
    const known = mxStore.record(context.id);
    const object = mxStore.remember(context, save);
    if (previous !== context.id) instance.update?.(object, () => undefined);
    else if (known && JSON.stringify(known) !== contextKey) mxStore.changed(context);
  }, [contextKey]);

  return (
    <div ref={container} className="mxrb-legacy-widget">
      {error ? <span role="alert">{error}</span> : undefined}
    </div>
  );
}

// Registers a Dojo widget of the project's own package under its widget id.
// Sources are the package files keyed by path under `root`.
export function registerLegacyWidget(
  id: string,
  files: Record<string, string>,
  root: string,
  entry: string,
  definitions: LegacyPropertyDefinition[],
): () => void {
  const sources = Object.fromEntries(
    Object.entries(files).map(([path, source]) => [path.slice(root.length), source]),
  );
  const pkg = { sources, entry, definitions };
  return registerMarketplaceWidget(id, (props) => <LegacyWidgetHost props={props} pkg={pkg} />);
}

const loadSession = async (): Promise<MxSession> => {
  try {
    const session = await api<(MxSession & { user?: string }) | undefined>('/api/session');
    return { ...session, username: session?.username ?? session?.user };
  } catch {
    return {};
  }
};
let sessionRequest: Promise<MxSession> | null = null;

// The signed-in user mx.session reports, read once per page load.
function useLegacySession(): MxSession | null {
  const [session, setSession] = useState<MxSession | null>(null);
  useEffect(() => {
    let active = true;
    void (sessionRequest ??= loadSession()).then((value) => active && setSession(value));
    return () => {
      active = false;
    };
  }, []);
  return session;
}
