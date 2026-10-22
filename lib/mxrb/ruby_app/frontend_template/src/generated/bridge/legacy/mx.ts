// The Mendix client API legacy widgets call (window.mx, MxObject and the mxui
// modules), answered by the MXRB runtime: records, schema, microflows, session.
import Big from 'big.js';
import { decimal, isDecimal } from '../decimal';
import { attributeDefinition } from '../schemaLookup';
import { memberName } from '../value';
import type {
  ApiRequest,
  ApplicationSchema,
  AssociationDefinition,
  EntityRecord,
  RuntimeValue,
} from '../../types';
import { clientServices, type ClientServices } from '../clientServices';
import { declare, domConstruct, lang } from './dojo';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Any = any;
type Callback = (...values: Any[]) => unknown;

export interface MxSession {
  id?: string;
  username?: string;
  roles?: string[];
  guest?: boolean;
}

// Writes a member of a record a page owns (a widget's context object).
export type MxSave = (
  record: EntityRecord,
  member: string,
  value: RuntimeValue,
) => Promise<EntityRecord | null>;

// The services of the running application (refresh, progress, confirmations,
// messages, sign-out) complete the environment of a widget or action.
export interface MxEnvironment extends ClientServices {
  schema?: ApplicationSchema;
  request?: ApiRequest;
  session: MxSession;
  locale: string;
}

const isRecord = (value: unknown): value is EntityRecord =>
  Boolean(value) &&
  typeof value === 'object' &&
  'id' in (value as object) &&
  'type' in (value as object);

// The Mendix attribute type names (getAttributeType) of the runtime's types.
const MENDIX_TYPES: Record<string, string> = {
  string: 'String',
  hashstring: 'HashString',
  integer: 'Integer',
  long: 'Long',
  decimal: 'Decimal',
  float: 'Float',
  currency: 'Currency',
  boolean: 'Boolean',
  datetime: 'DateTime',
  date: 'DateTime',
  enum: 'Enum',
  enumeration: 'Enum',
  autonumber: 'AutoNumber',
  binary: 'Binary',
};

export class MxStore {
  private readonly records = new Map<string, EntityRecord>();
  private readonly owners = new Map<string, MxSave>();
  private readonly listeners = new Set<{
    guid?: string;
    entity?: string;
    attr?: string;
    callback: Callback;
  }>();

  constructor(public environment: MxEnvironment) {}

  // A record and the objects embedded in it; `save` makes it one a page owns.
  remember(record: EntityRecord, save?: MxSave): MxObject {
    this.records.set(record.id, record);
    if (save) this.owners.set(record.id, save);
    Object.values(record.attributes).forEach((value) => {
      if (isRecord(value)) this.records.set(value.id, value);
      else if (Array.isArray(value))
        value.filter(isRecord).forEach((item) => this.records.set(item.id, item));
    });
    return new MxObject(record, this);
  }

  record = (guid: string) => this.records.get(String(guid));
  isOwned = (guid: string) => this.owners.has(guid);

  association(entity: string, name: string): AssociationDefinition | undefined {
    const member = memberName(name);
    return (this.environment.schema?.modules ?? [])
      .flatMap((module) => module.associations ?? [])
      .find(
        (item) =>
          (item.name === name || memberName(item.name) === member) &&
          (!item.from_entity || item.from_entity === entity || item.to_entity === entity),
      );
  }

  subscribe(options: {
    guid?: string;
    entity?: string;
    attr?: string;
    callback: Callback;
    val?: boolean;
  }) {
    if (options.val) return { remove: () => undefined };
    const listener = {
      guid: options.guid,
      entity: options.entity,
      attr: options.attr,
      callback: options.callback,
    };
    this.listeners.add(listener);
    return listener;
  }

  unsubscribe(handle: unknown) {
    this.listeners.delete(handle as never);
    (handle as { remove?: () => void } | undefined)?.remove?.();
  }

  // Notifies the widgets subscribed to a changed member, or, when the object
  // itself was refreshed, those subscribed to the object or its entity.
  changed(record: EntityRecord, member?: string) {
    for (const listener of [...this.listeners]) {
      if (listener.entity && listener.entity !== record.type) continue;
      if (listener.guid && listener.guid !== record.id) continue;
      if (Boolean(listener.attr) !== Boolean(member)) continue;
      if (listener.attr && memberName(listener.attr) !== member) continue;
      if (listener.attr)
        listener.callback(record.id, listener.attr, new MxObject(record, this).get(listener.attr));
      else if (listener.entity) listener.callback(record.type);
      else listener.callback(record.id);
    }
  }

  async write(record: EntityRecord, member: string, value: RuntimeValue) {
    const next: EntityRecord = { ...record, attributes: { ...record.attributes, [member]: value } };
    this.records.set(record.id, next);
    const save = this.owners.get(record.id);
    if (save) {
      const saved = await save(record, member, value);
      if (saved) this.remember(saved, save);
    }
    this.changed(this.records.get(record.id) ?? next, member);
  }
}

// mendix/lib/MxObject over a runtime record. Numbers are Big, dates epoch
// milliseconds, references guids, as the Mendix client returns them.
export class MxObject {
  constructor(
    private readonly snapshot: EntityRecord,
    private readonly store: MxStore,
  ) {}

  private get current(): EntityRecord {
    return this.store.record(this.snapshot.id) ?? this.snapshot;
  }

  private definition(attribute: string) {
    return attributeDefinition(
      this.store.environment.schema,
      this.current.type,
      memberName(attribute),
    );
  }

  // The runtime record behind the object, with the changes made through it.
  toRecord = (): EntityRecord => this.current;
  getGuid = () => this.current.id;
  getGUID = () => this.current.id;
  getEntity = () => this.current.type;
  getAttributes = () => Object.keys(this.current.attributes);
  getAttributeType = (attribute: string): string => {
    if (this.isReference(attribute))
      return this.isReferenceSet(attribute) ? 'ObjectReferenceSet' : 'ObjectReference';
    const type = this.definition(attribute)?.type ?? '';
    return MENDIX_TYPES[type.toLowerCase()] ?? type;
  };
  has = (attribute: string) =>
    memberName(attribute) in this.current.attributes || Boolean(this.definition(attribute));
  inheritsFrom = (entity: string) => this.current.type === entity;
  isA = (entity: string) => this.inheritsFrom(entity);
  isEnum = (attribute: string) => this.getAttributeType(attribute) === 'Enum';
  isDate = (attribute: string) => this.getAttributeType(attribute) === 'DateTime';
  isBoolean = (attribute: string) => this.getAttributeType(attribute) === 'Boolean';
  isNumeric = (attribute: string) =>
    ['Integer', 'Long', 'Decimal', 'Float', 'AutoNumber'].includes(
      this.getAttributeType(attribute),
    );
  isCurrency = () => false;
  isPassword = (attribute: string) => this.getAttributeType(attribute) === 'HashString';
  isReadonlyAttr = () => !this.store.isOwned(this.current.id);
  isReference = (attribute: string) =>
    Boolean(this.store.association(this.current.type, attribute));
  isObjectReference = (attribute: string) =>
    this.isReference(attribute) && !this.isReferenceSet(attribute);
  isReferenceSet = (attribute: string) =>
    this.store.association(this.current.type, attribute)?.type === 'ReferenceSet';
  isObjectReferenceSet = (attribute: string) => this.isReferenceSet(attribute);
  getReferenceAttributes = () => this.getAttributes().filter((name) => this.isReference(name));

  get(attribute: string): unknown {
    return this.read(this.current, attribute);
  }

  // The value the object had when the page handed it over, before set() changed it.
  getOriginalValue(attribute: string): unknown {
    return this.read(this.snapshot, attribute);
  }

  private read(record: EntityRecord, attribute: string): unknown {
    const value = record.attributes[memberName(attribute)];
    if (this.isReference(attribute)) {
      if (this.isReferenceSet(attribute)) return referenceGuids(value);
      return referenceGuid(value);
    }
    if (value === null || value === undefined)
      return this.isNumeric(attribute) || this.isDate(attribute) ? '' : (value ?? '');
    if (isDecimal(value)) return new Big(value.__mxrb_decimal);
    if (typeof value === 'number') return this.isNumeric(attribute) ? new Big(value) : value;
    if (this.isDate(attribute) && typeof value === 'string') return new Date(value).getTime();
    return value;
  }

  getReference(attribute: string): string {
    return referenceGuid(this.current.attributes[memberName(attribute)]);
  }

  getReferences(attribute: string): string[] {
    return referenceGuids(this.current.attributes[memberName(attribute)]);
  }

  // mxobj.fetch: an attribute, or a path over the loaded references
  // (Module.Association/Module.Entity/Attribute) that ends on an attribute
  // value or, without one, on the referenced object(s).
  fetch(path: string, callback: Callback) {
    const [head, ...rest] = String(path).split('/').filter(Boolean);
    if (!head) return callback(this);
    if (!this.isReference(head)) return callback(this.get(head));
    const set = this.isReferenceSet(head);
    const objects = (set ? this.getReferences(head) : [this.getReference(head)])
      .map((guid) => this.store.record(guid))
      .filter(isRecord)
      .map((record) => new MxObject(record, this.store));
    const tail = rest[0]?.includes('.') && !objects[0]?.has(rest[0]) ? rest.slice(1) : rest;
    const results: unknown[] = [];
    objects.forEach((object) =>
      tail.length
        ? object.fetch(tail.join('/'), (value) => results.push(value))
        : results.push(object),
    );
    return callback(set ? results : (results[0] ?? null));
  }

  getEnumCaption(attribute: string, value = this.get(attribute)): string {
    const enumeration = this.enumeration(attribute);
    const item = enumeration?.values.find((candidate) => candidate.name === value);
    return (
      item?.caption_translations?.[this.store.environment.locale.replace('-', '_')] ??
      item?.caption ??
      String(value ?? '')
    );
  }

  getEnumMap(attribute: string) {
    return (this.enumeration(attribute)?.values ?? []).map((item) => ({
      key: item.name,
      caption: item.caption,
    }));
  }

  private enumeration(attribute: string) {
    const name = this.definition(attribute)?.enumeration;
    return (this.store.environment.schema?.modules ?? [])
      .flatMap((module) => module.enumerations ?? [])
      .find((item) => item.id === name || item.name === name);
  }

  set(attribute: string, value: unknown) {
    const member = memberName(attribute);
    let runtime: RuntimeValue;
    if (value instanceof Big)
      runtime =
        this.getAttributeType(attribute) === 'Decimal'
          ? decimal(value.toString())
          : Number(value.toString());
    else if (this.isDate(attribute) && (typeof value === 'number' || value instanceof Date))
      runtime = new Date(value).toISOString();
    else if (this.isReference(attribute)) {
      if (this.isReferenceSet(attribute))
        return this.setReferences(attribute, (value as string[]) ?? []);
      runtime = value ? (this.store.record(String(value)) ?? String(value)) : null;
    } else runtime = value === '' && this.isNumeric(attribute) ? null : (value as RuntimeValue);
    void this.store.write(this.current, member, runtime);
  }

  private setReferences(attribute: string, guids: string[]) {
    const unique = [...new Set(guids.map(String))];
    const records = unique.map((guid) => this.store.record(guid) ?? guid) as RuntimeValue;
    void this.store.write(this.current, memberName(attribute), records);
  }

  addReference = (attribute: string, guid: string) => this.addReferences(attribute, [guid]);
  addReferences = (attribute: string, guids: string[]) =>
    this.setReferences(attribute, [...this.getReferences(attribute), ...guids]);
  removeReferences = (attribute: string, guids: string[]) => {
    const removed = new Set(guids.map(String));
    this.setReferences(
      attribute,
      this.getReferences(attribute).filter((guid) => !removed.has(guid)),
    );
  };
  hasChanges = () => false;
  isNew = () => Boolean(this.current.new_record);
  getOptions = () => ({});
  get metaData() {
    return {
      getEntity: () => this.current.type,
      getAttributes: () => this.getAttributes(),
      getAttributeType: (attribute: string) => this.getAttributeType(attribute),
      isEnum: (attribute: string) => this.isEnum(attribute),
    };
  }
  get jsonData() {
    return {
      guid: this.current.id,
      objectType: this.current.type,
      attributes: this.current.attributes,
    };
  }
}

const referenceGuid = (value: unknown): string => {
  if (isRecord(value)) return value.id;
  return typeof value === 'string' ? value : '';
};

const referenceGuids = (value: unknown): string[] =>
  Array.isArray(value) ? value.map((item) => (isRecord(item) ? item.id : String(item))) : [];

const entityRecords = (value: unknown): EntityRecord[] =>
  (Array.isArray(value) ? value : value ? [value] : []).filter(isRecord);

const escapeString = (value: unknown) =>
  String(value ?? '').replace(/[&<>"']/g, (character) => `&#${character.charCodeAt(0)};`);

// Formats a value the way mx.parser does for the user's locale.
function formatValue(value: unknown, type = '', options: Record<string, unknown> = {}): string {
  if (value === null || value === undefined || value === '') return '';
  const kind = type.toLowerCase();
  if (['integer', 'long', 'decimal', 'float', 'currency', 'autonumber'].includes(kind)) {
    const number = Number(value instanceof Big ? value.toString() : value);
    const places = typeof options.places === 'number' ? options.places : undefined;
    const locale =
      typeof options.locale === 'string' && options.locale ? options.locale : undefined;
    return new Intl.NumberFormat(locale, {
      useGrouping: kind !== 'autonumber' && options.groups !== false,
      ...(places !== undefined
        ? { minimumFractionDigits: places, maximumFractionDigits: places }
        : {}),
    }).format(number);
  }
  if (kind === 'datetime') return new Date(Number(value)).toLocaleString();
  return String(value);
}

export function createMx(store: MxStore) {
  const env = (): MxEnvironment => ({ ...clientServices(), ...store.environment });
  let progress = 0;
  const shown = new Set<number>();
  const call = async (name: string, guids: string[] = []): Promise<unknown> => {
    const { request } = env();
    if (!request) throw new Error(`Microflow ${name} cannot run here`);
    const start = guids.map((guid) => store.record(guid)).find(Boolean);
    const payload = await request<{ result?: unknown }>(
      `/api/microflows/${encodeURIComponent(name)}`,
      {
        method: 'POST',
        body: JSON.stringify(start ? { __mxrb_context: start } : {}),
      },
    );
    const records = entityRecords(payload?.result);
    if (records.length || Array.isArray(payload?.result)) {
      const objects = records.map((record) => store.remember(record));
      return Array.isArray(payload?.result) ? objects : objects[0];
    }
    return payload?.result;
  };
  const action = (options: Record<string, Any>, scope?: unknown) => {
    const params = options.params ?? {};
    call(String(params.actionname || ''), params.guids)
      .then((result) => options.callback?.call(scope ?? options.scope, result))
      .catch((error: unknown) => options.error?.call(scope ?? options.scope, error));
  };
  const get = async (options: Record<string, Any>): Promise<unknown> => {
    if (options.guid) {
      const record = store.record(options.guid);
      if (!record) throw new Error(`Object ${options.guid} is not loaded`);
      return new MxObject(record, store);
    }
    if (options.guids)
      return (options.guids as string[])
        .map((guid) => store.record(guid))
        .filter(isRecord)
        .map((record) => new MxObject(record, store));
    const match = /^\/\/([\w.]+)(.*)$/.exec(String(options.xpath || ''));
    const { request } = env();
    if (!match || !request) throw new Error(`Unsupported retrieval ${String(options.xpath)}`);
    const sort = (options.filter?.sort ?? []) as Array<[string, string]>;
    const query = new URLSearchParams();
    if (match[2]) query.set('xpath', match[2]);
    const response = await request<{ records?: EntityRecord[] }>(
      `/api/entities/${encodeURIComponent(match[1])}${query.size ? `?${query}` : ''}`,
    );
    const records = [...(response?.records ?? [])].sort((left, right) => {
      for (const [attribute, direction] of sort) {
        const a = String(left.attributes[memberName(attribute)] ?? '');
        const b = String(right.attributes[memberName(attribute)] ?? '');
        const order = a.localeCompare(b, undefined, { numeric: true });
        if (order) return direction === 'desc' ? -order : order;
      }
      return 0;
    });
    return records.map((record) => store.remember(record));
  };
  const message = (kind: 'info' | 'warning' | 'error') => (text: string) =>
    env().notify?.(kind, String(text));
  return {
    data: {
      get: (options: Record<string, Any>) => {
        get(options)
          .then((result) =>
            options.callback?.call(
              options.scope,
              result,
              options.count ? (result as unknown[]).length : undefined,
            ),
          )
          .catch((error: unknown) => options.error?.call(options.scope, error));
      },
      action,
      subscribe: (options: Record<string, Any>) => store.subscribe(options as never),
      unsubscribe: (handle: unknown) => store.unsubscribe(handle),
      create: (options: Record<string, Any>) =>
        options.callback?.call(
          options.scope,
          store.remember({
            id: `new-${crypto.randomUUID()}`,
            type: String(options.entity),
            attributes: {},
            new_record: true,
            transient: true,
          }),
        ),
      commit: (options: Record<string, Any>) => options.callback?.call(options.scope),
      rollback: (options: Record<string, Any>) => options.callback?.call(options.scope),
      remove: (options: Record<string, Any>) =>
        options.error?.call(
          options.scope,
          new Error('Deleting objects from a legacy widget is not supported'),
        ),
      // Refreshes the object or entity in the page, as after a change on the server.
      update: (options: Record<string, Any>) => {
        const record = options.guid && store.record(options.guid);
        if (record) store.changed(record);
        env().refresh?.({ guid: options.guid, entity: options.entity });
        options.callback?.call(options.scope);
      },
    },
    ui: {
      action: (name: string, options: Record<string, Any> = {}, scope?: unknown) =>
        action({ ...options, params: { ...(options.params ?? {}), actionname: name } }, scope),
      info: message('info'),
      warning: message('warning'),
      error: message('error'),
      confirmation: (options: Record<string, Any>) => {
        const answer =
          env().confirm?.({
            question: String(options.content ?? ''),
            proceed: options.proceed,
            cancel: options.cancel,
          }) ?? Promise.resolve(true);
        void answer.then((confirmed) =>
          (confirmed ? options.handler : options.onCancel)?.call(options.scope),
        );
      },
      showProgress: () => {
        progress += 1;
        shown.add(progress);
        env().progress?.(true);
        return progress;
      },
      hideProgress: (id: number) => {
        shown.delete(Number(id));
        if (shown.size === 0) env().progress?.(false);
      },
      reload: () => window.location.reload(),
      getContentForm: () => ({ path: window.location.pathname, title: document.title }),
      openForm: () => undefined,
    },
    session: {
      getUserId: () => env().session.id ?? '',
      getUserName: () => env().session.username ?? '',
      getUserRoles: () =>
        (env().session.roles ?? []).map((name) => ({ getGuid: () => name, get: () => name })),
      getUserRoleNames: () => env().session.roles ?? [],
      isGuest: () => Boolean(env().session.guest || !env().session.username),
      sessionData: { user: { attributes: {} } },
    },
    parser: {
      formatValue,
      formatAttribute: (object: MxObject, attribute: string, options?: Record<string, unknown>) =>
        object.isEnum(attribute)
          ? object.getEnumCaption(attribute)
          : formatValue(object.get(attribute), object.getAttributeType(attribute), options),
      parseValue: (value: string, type: string) =>
        ['Integer', 'Long', 'Decimal'].includes(type) ? new Big(value || 0) : value,
    },
    meta: {
      getEntity: (name: string) => ({
        getEntity: () => name,
        isEnum: () => false,
        getAttributes: () => [],
      }),
    },
    logger: console,
    logout: () => env().logout?.(),
    appUrl: `${window.location.origin}/`,
    baseUrl: `${window.location.origin}/xas/`,
    remoteUrl: `${window.location.origin}/`,
    version: '9.24.0',
    isOffline: () => false,
  };
}

let installed: MxStore | null = null;

// The one window.mx of the page, answered from the latest environment; a host
// or action passes its own and the services of the running application stay.
export function installMx(environment: MxEnvironment): MxStore {
  const global = globalThis as Record<string, unknown>;
  if (!installed) {
    installed = new MxStore(environment);
    global.mx = createMx(installed);
    global.logger = Object.assign(Object.create(console), { debug: () => undefined });
  } else installed.environment = { ...installed.environment, ...environment };
  return installed;
}

// The form (page) a widget is placed on, as mxform; its context as mxcontext.
export function mxForm(
  node: Element,
  store: MxStore,
  context: () => EntityRecord | null,
  save: MxSave,
) {
  const listeners: Array<{ remove(): void }> = [];
  return {
    mxform: {
      path: window.location.pathname,
      title: document.title,
      domNode: node,
      id: 'mxrb_form',
      listen: (_event: string, callback: Callback) => {
        const handle = { remove: () => void callback };
        listeners.push(handle);
        return handle;
      },
      close: () => undefined,
      validate: (callback?: Callback) => callback?.(),
    },
    mxcontext: {
      getTrackObject: () => {
        const record = context();
        return record ? store.remember(record, save) : null;
      },
      getTrackId: () => context()?.id ?? '',
      getTrackEntity: () => context()?.type ?? '',
      getContext: () => null,
      hasTrackEntity: () => Boolean(context()),
    },
  };
}

// mxui/widget/_WidgetBase: the lifecycle the Mendix client drives (create,
// startup, update with the context object, uninitialize) and its helpers.
export function mxuiModules(store: MxStore): Record<string, unknown> {
  let next = 0;
  const WidgetBase = declare(null, {
    constructor(this: Any) {
      this._subscriptions = [];
    },
    postscript(this: Any, params?: Record<string, unknown>, srcNodeRef?: Element) {
      this.create(params, srcNodeRef);
    },
    create(this: Any, params?: Record<string, unknown>, srcNodeRef?: Element) {
      this.srcNodeRef = srcNodeRef;
      this.params = params ?? {};
      if (params) lang.mixin(this, params);
      this.id ||= `mxui_widget_${(this.declaredClass || 'Widget').replace(/\W/g, '_')}_${next++}`;
      this.postMixInProperties();
      this.buildRendering();
      if (this.domNode) {
        if (!this.domNode.id) this.domNode.id = this.id;
        if (this.class)
          this.domNode.classList.add(...String(this.class).split(/\s+/).filter(Boolean));
        if (this.style && typeof this.style === 'string') this.domNode.style.cssText += this.style;
      }
      this.postCreate();
    },
    postMixInProperties: () => undefined,
    buildRendering(this: Any) {
      this.domNode = this.srcNodeRef ?? document.createElement('div');
    },
    postCreate: () => undefined,
    startup(this: Any) {
      this._started = true;
    },
    update(_object: unknown, callback?: () => void) {
      callback?.();
    },
    applyContext(this: Any, context: Any, callback?: () => void) {
      this.update(context?.getTrackObject?.() ?? null, callback);
    },
    resize: () => undefined,
    uninitialize: () => undefined,
    destroy(this: Any) {
      this.uninitialize();
      this.unsubscribeAll();
      this._attachEvents?.forEach((handle: Any) => handle.remove());
      this._connections?.forEach((handle: Any) => handle.remove());
      this.domNode?.remove();
      this._destroyed = true;
    },
    destroyRecursive(this: Any) {
      this.destroy();
    },
    subscribe(this: Any, options: Record<string, Any>) {
      const handle = store.subscribe({
        ...options,
        callback: lang.hitch(this, options.callback),
      } as never);
      this._subscriptions.push(handle);
      return handle;
    },
    unsubscribe(this: Any, handle: unknown) {
      store.unsubscribe(handle);
      this._subscriptions = this._subscriptions.filter((item: unknown) => item !== handle);
    },
    unsubscribeAll(this: Any) {
      this._subscriptions.forEach((handle: unknown) => store.unsubscribe(handle));
      this._subscriptions = [];
    },
    connect(this: Any, target: Any, event: string, method: Any) {
      const listener = lang.hitch(this, method);
      const name = event.replace(/^on/, '');
      let handle: { remove(): void };
      if (target?.addEventListener) {
        target.addEventListener(name, listener);
        handle = { remove: () => target.removeEventListener(name, listener) };
      } else {
        const original = target[event];
        target[event] = function (this: Any, ...values: Any[]) {
          const result = original?.apply(this, values);
          listener(...values);
          return result;
        };
        handle = { remove: () => (target[event] = original) };
      }
      (this._connections ??= []).push(handle);
      return handle;
    },
    disconnect: (handle: Any) => handle?.remove(),
    get(this: Any, name: string) {
      return this[name];
    },
    set(this: Any, name: string, value: unknown) {
      this[name] = value;
      return this;
    },
    collect(this: Any, ...callbacks: Array<(callback: () => void) => void>) {
      callbacks.forEach((callback) => callback(() => undefined));
    },
    readOnly: false,
    disabled: false,
  });
  const create = (tag: string, props?: Any, ...children: Any[]) => {
    const element =
      props && (props.nodeType || typeof props === 'string')
        ? domConstruct.create(tag)
        : domConstruct.create(tag, props ?? undefined);
    const content =
      props && (props.nodeType || typeof props === 'string') ? [props, ...children] : children;
    content
      .flat()
      .forEach((child) =>
        element.appendChild(typeof child === 'string' ? document.createTextNode(child) : child),
      );
    return element;
  };
  return {
    'mxui/widget/_WidgetBase': WidgetBase,
    'mxui/widget/_Widget': WidgetBase,
    'mxui/dom': {
      create,
      escapeString,
      addCss: () => undefined,
      getCss: (name: string) => name,
    },
    'mendix/lib/MxObject': MxObject,
    'mendix/lang': lang,
  };
}
