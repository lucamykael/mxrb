// The Dojo and dijit modules legacy Mendix widgets import, implemented over the
// DOM. Only the behaviour those widgets rely on is provided.
import { captionDate } from '../captions';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Any = any;
type Props = Record<string, Any>;
type Constructor = { new (...args: Any[]): Any; prototype: Any; _meta?: Meta };
type Layer = { props: Props; ctor?: Any };
type Meta = { layers: Layer[] };

const own = Object.prototype.hasOwnProperty;

// Every layer of a class, base first, without repeating a shared mixin.
function layersOf(bases: Constructor[]): Layer[] {
  const result: Layer[] = [];
  const seen = new Set<Props>();
  for (const base of bases) {
    const layers = base._meta?.layers ?? [{ props: base.prototype, ctor: base }];
    for (const layer of layers)
      if (!seen.has(layer.props)) {
        seen.add(layer.props);
        result.push(layer);
      }
  }
  return result;
}

// dojo/_base/declare: classes from a base and mixins. this.inherited(arguments)
// calls the next implementation up, which strict mode code also reaches because
// the running method is tracked instead of read from arguments.callee.
export function declare(...args: Any[]): Constructor {
  const className = typeof args[0] === 'string' ? (args.shift() as string) : '';
  const [superclass, props = {}] = args as [Constructor | Constructor[] | null, Props];
  const bases = superclass ? (Array.isArray(superclass) ? superclass : [superclass]) : [];
  const layers = [...layersOf(bases), { props }];
  const Declared = function (this: Any, ...values: Any[]) {
    for (const layer of layers) {
      // A plain function base runs as is; a declared layer runs its own constructor.
      if (layer.ctor) layer.ctor.apply(this, values);
      else if (own.call(layer.props, 'constructor') && layer.props.constructor !== Object)
        layer.props.constructor.apply(this, values);
    }
    if (typeof this.postscript === 'function') this.postscript(...values);
  } as unknown as Constructor;
  const prototype: Props = {};
  const names = new Set(layers.flatMap((layer) => Object.keys(layer.props)));
  for (const name of names) {
    if (name === 'constructor') continue;
    const chain = layers
      .filter((layer) => own.call(layer.props, name))
      .map((layer) => layer.props[name]);
    const top = chain[chain.length - 1];
    if (typeof top !== 'function') {
      prototype[name] = top;
      continue;
    }
    prototype[name] = function (this: Any, ...values: Any[]) {
      return invoke(this, name, chain, chain.length - 1, values);
    };
  }
  prototype.inherited = function (this: Any, ...values: Any[]) {
    const frame = (this.__calls as Frame[] | undefined)?.at(-1);
    const named = typeof values[0] === 'string';
    const parameters = (named ? values[1] : values[0]) as ArrayLike<Any> | undefined;
    const replacement = named ? values[2] : values[1];
    if (!frame) return undefined;
    const next = frame.index - 1;
    if (next < 0) return undefined;
    return invoke(this, frame.name, frame.chain, next, Array.from(replacement ?? parameters ?? []));
  };
  prototype.getInherited = function (this: Any) {
    const frame = (this.__calls as Frame[] | undefined)?.at(-1);
    return frame && frame.index > 0 ? frame.chain[frame.index - 1] : undefined;
  };
  prototype.isInstanceOf = function (this: Any, type: Constructor) {
    return (
      this instanceof type || layersOf([this.constructor]).some((layer) => layer.ctor === type)
    );
  };
  prototype.declaredClass = className;
  prototype.constructor = Declared;
  Declared.prototype = prototype;
  Declared._meta = { layers };
  (Declared as Any).extend = (extra: Props) => {
    Object.assign(props, extra);
    Object.assign(prototype, extra);
    return Declared;
  };
  return Declared;
}

type Frame = { name: string; chain: Any[]; index: number };

function invoke(target: Any, name: string, chain: Any[], index: number, values: Any[]): Any {
  const calls: Frame[] = target.__calls ?? (target.__calls = []);
  calls.push({ name, chain, index });
  try {
    return chain[index].apply(target, values);
  } finally {
    calls.pop();
  }
}
declare.safeMixin = (target: Props, source: Props) => Object.assign(target, source);

const isString = (value: Any): value is string => typeof value === 'string';
const isFunction = (value: Any): value is (...args: Any[]) => Any => typeof value === 'function';

export const lang = {
  hitch(scope: Any, method: Any, ...bound: Any[]) {
    const target = isString(method) ? scope[method] : method;
    if (!method && method !== 0) return scope;
    return (...values: Any[]) =>
      (isString(method) ? scope[method] : target).apply(scope, [...bound, ...values]);
  },
  partial:
    (method: Any, ...bound: Any[]) =>
    (...values: Any[]) =>
      method(...bound, ...values),
  mixin: (target: Any, ...sources: Any[]) => Object.assign(target ?? {}, ...sources),
  delegate: (prototype: Any, props?: Any) => Object.assign(Object.create(prototype), props),
  clone: (value: Any) => (value === undefined ? value : structuredClone(value)),
  isString,
  isFunction,
  isArray: Array.isArray,
  isObject: (value: Any) =>
    value !== undefined && (value === null || typeof value === 'object' || isFunction(value)),
  isArrayLike: (value: Any) =>
    value != null && typeof value !== 'string' && typeof value.length === 'number',
  trim: (value: string) => String(value).trim(),
  replace: (template: string, map: Any) =>
    template.replace(/\{([^}]+)\}/g, (_, key) =>
      String(isFunction(map) ? map(_, key) : lang.getObject(key, false, map)),
    ),
  getObject(path: string, create = false, context: Any = globalThis) {
    let target = context;
    for (const part of path.split('.')) {
      if (target == null) return undefined;
      if (!(part in target) && create) target[part] = {};
      target = target[part];
    }
    return target;
  },
  setObject(path: string, value: Any, context: Any = globalThis) {
    const parts = path.split('.');
    const last = parts.pop()!;
    const target = parts.length ? lang.getObject(parts.join('.'), true, context) : context;
    target[last] = value;
    return value;
  },
  exists: (path: string, context?: Any) => lang.getObject(path, false, context) !== undefined,
};

const list = (value: Any): Any[] => (value ? Array.from(value as ArrayLike<Any>) : []);
const bind = (callback: Any, scope: Any) =>
  (isString(callback) ? new Function('item', 'index', 'array', callback) : callback).bind(scope);
export const array = {
  forEach: (items: Any, callback: Any, scope?: Any) => list(items).forEach(bind(callback, scope)),
  map: (items: Any, callback: Any, scope?: Any) => list(items).map(bind(callback, scope)),
  filter: (items: Any, callback: Any, scope?: Any) => list(items).filter(bind(callback, scope)),
  some: (items: Any, callback: Any, scope?: Any) => list(items).some(bind(callback, scope)),
  every: (items: Any, callback: Any, scope?: Any) => list(items).every(bind(callback, scope)),
  indexOf: (items: Any, value: Any, from = 0) => list(items).indexOf(value, from),
  lastIndexOf: (items: Any, value: Any) => list(items).lastIndexOf(value),
};

const byId = (node: Any): Any => (isString(node) ? document.getElementById(node) : node);
export const dom = {
  byId,
  isDescendant: (node: Any, ancestor: Any) => byId(ancestor)?.contains(byId(node)),
};

export const domClass = {
  contains: (node: Any, name: string) => Boolean(byId(node)?.classList.contains(name)),
  add: (node: Any, names: string | string[]) =>
    byId(node)?.classList.add(
      ...(Array.isArray(names) ? names : String(names).split(/\s+/)).filter(Boolean),
    ),
  remove: (node: Any, names?: string | string[]) => {
    const element = byId(node);
    if (!element) return;
    if (names === undefined) element.className = '';
    else
      element.classList.remove(
        ...(Array.isArray(names) ? names : String(names).split(/\s+/)).filter(Boolean),
      );
  },
  toggle: (node: Any, name: string, condition?: boolean) =>
    byId(node)?.classList.toggle(name, condition),
  replace: (node: Any, add: string, remove: string) => {
    domClass.remove(node, remove);
    domClass.add(node, add);
  },
};

const cssName = (name: string) => name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
export const domStyle = {
  get: (node: Any, name?: string) => {
    const style = getComputedStyle(byId(node));
    return name ? style.getPropertyValue(cssName(name)) : style;
  },
  set: (node: Any, name: Any, value?: Any) => {
    const element = byId(node);
    const values: Props = isString(name) ? { [name]: value } : name;
    Object.entries(values).forEach(([key, item]) =>
      element.style.setProperty(
        cssName(key),
        typeof item === 'number' && !/opacity|z-?index/i.test(key) ? `${item}px` : String(item),
      ),
    );
  },
};

const setAttributes = (element: Any, attributes: Props) => {
  Object.entries(attributes).forEach(([key, value]) => {
    if (key === 'innerHTML' || key === 'className' || key === 'textContent' || key === 'value')
      element[key] = value;
    else if (key === 'class') element.className = value;
    else if (key === 'style' && !isString(value)) domStyle.set(element, value);
    else if (key.startsWith('on') && isFunction(value))
      element.addEventListener(key.slice(2), value);
    else if (value === false || value == null) element.removeAttribute(key);
    else element.setAttribute(key, value === true ? '' : String(value));
  });
};

export const domAttr = {
  get: (node: Any, name: string) => byId(node)?.getAttribute(name),
  set: (node: Any, name: Any, value?: Any) =>
    setAttributes(byId(node), isString(name) ? { [name]: value } : name),
  has: (node: Any, name: string) => Boolean(byId(node)?.hasAttribute(name)),
  remove: (node: Any, name: string) => byId(node)?.removeAttribute(name),
};
export const domProp = {
  get: (node: Any, name: string) => byId(node)?.[name],
  set: (node: Any, name: Any, value?: Any) => {
    const element = byId(node);
    Object.assign(element, isString(name) ? { [name]: value } : name);
    return element;
  },
};

function place(node: Any, reference: Any, position: Any = 'last'): Any {
  const element = isString(node) && node.trim().startsWith('<') ? toDom(node) : byId(node);
  const target = byId(reference);
  if (!target) return element;
  if (typeof position === 'number') {
    const children = target.children;
    if (position >= children.length) target.appendChild(element);
    else target.insertBefore(element, children[Math.max(position, 0)]);
  } else if (position === 'first') target.insertBefore(element, target.firstChild);
  else if (position === 'before') target.parentNode?.insertBefore(element, target);
  else if (position === 'after') target.parentNode?.insertBefore(element, target.nextSibling);
  else if (position === 'replace') target.parentNode?.replaceChild(element, target);
  else if (position === 'only') {
    target.replaceChildren(element);
  } else target.appendChild(element);
  return element;
}

function toDom(html: string): Any {
  const template = document.createElement('template');
  template.innerHTML = html.trim();
  return template.content.childNodes.length === 1 ? template.content.firstChild : template.content;
}

export const domConstruct = {
  create(tag: Any, attributes?: Props, reference?: Any, position?: Any) {
    const element = isString(tag) ? document.createElement(tag) : tag;
    if (attributes) setAttributes(element, attributes);
    if (reference) place(element, reference, position);
    return element;
  },
  place,
  toDom,
  destroy: (node: Any) => byId(node)?.remove(),
  empty: (node: Any) => byId(node)?.replaceChildren(),
};

export const domGeometry = {
  position: (node: Any) => {
    const box = byId(node).getBoundingClientRect();
    return { x: box.left, y: box.top, w: box.width, h: box.height };
  },
  getMarginBox: (node: Any) => {
    const element = byId(node);
    return {
      l: element.offsetLeft,
      t: element.offsetTop,
      w: element.offsetWidth,
      h: element.offsetHeight,
    };
  },
  getContentBox: (node: Any) => {
    const element = byId(node);
    return { l: 0, t: 0, w: element.clientWidth, h: element.clientHeight };
  },
  setMarginBox: (node: Any, box: Props) => domStyle.set(node, { width: box.w, height: box.h }),
};

function on(node: Any, type: string, listener: Any) {
  const types = type.split(/\s*,\s*/);
  const element = byId(node);
  types.forEach((name) => element.addEventListener(name, listener));
  return { remove: () => types.forEach((name) => element.removeEventListener(name, listener)) };
}
on.once = (node: Any, type: string, listener: Any) => {
  const handle = on(node, type, (event: Any) => {
    handle.remove();
    listener(event);
  });
  return handle;
};
on.emit = (node: Any, type: string, init: Any) =>
  byId(node).dispatchEvent(new CustomEvent(type, { bubbles: true, ...init }));

function query(selector: string, root?: Any) {
  const items = Array.from((byId(root) ?? document).querySelectorAll(selector)) as Any[];
  return Object.assign(items, {
    on: (type: string, listener: Any) => items.map((item) => on(item, type, listener)),
    addClass: (name: string) => (items.forEach((item) => domClass.add(item, name)), items),
    removeClass: (name: string) => (items.forEach((item) => domClass.remove(item, name)), items),
    style: (name: Any, value?: Any) => (
      items.forEach((item) => domStyle.set(item, name, value)),
      items
    ),
    attr: (name: Any, value?: Any) => (
      items.forEach((item) => domAttr.set(item, name, value)),
      items
    ),
    empty: () => (items.forEach((item) => domConstruct.empty(item)), items),
    orphan: () => (items.forEach((item) => item.remove()), items),
  });
}

const topics = new Map<string, Set<Any>>();
export const topic = {
  publish: (name: string, ...values: Any[]) =>
    topics.get(name)?.forEach((listener) => listener(...values)),
  subscribe(name: string, listener: Any) {
    const listeners = topics.get(name) ?? new Set();
    topics.set(name, listeners.add(listener));
    return { remove: () => listeners.delete(listener) };
  },
};

const aspectAdvice =
  (where: 'before' | 'after' | 'around') => (target: Any, name: string, advice: Any) => {
    const original = target[name];
    target[name] = function (this: Any, ...values: Any[]) {
      if (where === 'around') return advice(original).apply(this, values);
      if (where === 'before') {
        const changed = advice.apply(this, values);
        return original?.apply(this, changed ?? values);
      }
      const result = original?.apply(this, values);
      advice.apply(this, values);
      return result;
    };
    return { remove: () => (target[name] = original) };
  };

// dojo/date/locale.format with the selectors and Java-style patterns widgets pass.
function formatDate(date: Date, options: Props = {}): string {
  const selector = String(options.selector || 'datetime');
  const pattern = (value: Any) => (isString(value) && value ? value : undefined);
  const part = (kind: 'Date' | 'Time', custom?: string) =>
    custom
      ? captionDate(
          date.toISOString(),
          { date_format: 'Custom', custom_date_format: custom },
          kernel.locale,
        )
      : captionDate(date.toISOString(), { date_format: kind }, kernel.locale);
  if (selector === 'date') return part('Date', pattern(options.datePattern));
  if (selector === 'time') return part('Time', pattern(options.timePattern));
  return `${part('Date', pattern(options.datePattern))} ${part('Time', pattern(options.timePattern))}`;
}

export const kernel = {
  locale: typeof navigator === 'undefined' ? 'en-US' : navigator.language || 'en-US',
  version: { major: 1, minor: 16 },
};

// The template of a templated widget: ${property} substitutions, attach points
// and attach events (both data-dojo-* and the older dojoAttach* attributes).
function attach(widget: Any, root: Element) {
  const nodes = [root, ...Array.from(root.querySelectorAll('*'))];
  for (const node of nodes) {
    const points =
      node.getAttribute('data-dojo-attach-point') ?? node.getAttribute('dojoAttachPoint');
    points
      ?.split(/\s*,\s*/)
      .filter(Boolean)
      .forEach((point) => (widget[point] = node));
    const events =
      node.getAttribute('data-dojo-attach-event') ?? node.getAttribute('dojoAttachEvent');
    events
      ?.split(/\s*,\s*/)
      .filter(Boolean)
      .forEach((binding) => {
        const [event, method] = binding.split(/\s*:\s*/);
        const handle = on(node, event.replace(/^on/, ''), (value: Any) =>
          widget[method || event]?.(value),
        );
        (widget._attachEvents ??= []).push(handle);
      });
  }
}

export const TemplatedMixin = declare(null, {
  templateString: '',
  buildRendering(this: Any) {
    const html = String(this.templateString).replace(/\$\{([^}]+)\}/g, (_: string, key: string) => {
      const value = lang.getObject(key, false, this);
      return value == null ? '' : String(value);
    });
    const node = toDom(html) as Element;
    attach(this, node);
    if (this.srcNodeRef?.parentNode) this.srcNodeRef.parentNode.replaceChild(node, this.srcNodeRef);
    this.domNode = node;
  },
});

export const AttachMixin = declare(null, {
  buildRendering(this: Any, ...values: Any[]) {
    this.inherited(values);
    if (this.domNode) attach(this, this.domNode);
  },
});

export const dojoModules = (): Record<string, unknown> => ({
  'dojo/_base/declare': declare,
  'dojo/_base/lang': lang,
  'dojo/_base/array': array,
  'dojo/_base/event': { stop: (event: Event) => (event.preventDefault(), event.stopPropagation()) },
  'dojo/_base/kernel': kernel,
  'dojo/_base/window': { doc: document, body: () => document.body, global: globalThis },
  'dojo/_base/connect': {
    connect: (node: Any, event: string, scope: Any, method?: Any) =>
      on(node, event.replace(/^on/, ''), lang.hitch(method ? scope : null, method ?? scope)),
    disconnect: (handle: Any) => handle?.remove(),
    publish: topic.publish,
    subscribe: topic.subscribe,
  },
  'dojo/dom': dom,
  'dojo/dom-class': domClass,
  'dojo/dom-style': domStyle,
  'dojo/dom-attr': domAttr,
  'dojo/dom-prop': domProp,
  'dojo/dom-construct': domConstruct,
  'dojo/dom-geometry': domGeometry,
  'dojo/query': query,
  'dojo/on': on,
  'dojo/html': {
    set: (node: Any, content: Any) =>
      isString(content) ? (byId(node).innerHTML = content) : byId(node).replaceChildren(content),
  },
  'dojo/topic': topic,
  'dojo/aspect': {
    before: aspectAdvice('before'),
    after: aspectAdvice('after'),
    around: aspectAdvice('around'),
  },
  'dojo/date/locale': { format: formatDate },
  'dojo/text': {},
  'dojo/ready': (callback: Any) =>
    queueMicrotask(isFunction(callback) ? callback : () => undefined),
  'dojo/domReady': {},
  dojo: kernel,
  'dijit/_TemplatedMixin': TemplatedMixin,
  'dijit/_AttachMixin': AttachMixin,
  'dijit/_WidgetsInTemplateMixin': declare(null, {}),
});
