import Big from 'big.js';
import { act, render, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, type MarketplaceWidgetProps } from '../marketplace';
import type { ApiRequest, ApplicationSchema, EntityRecord, RuntimeValue } from '../../types';
import { AmdLoader } from './amd';
import { array, declare, dojoModules, domAttr, domClass, domConstruct, lang } from './dojo';
import { legacyParams, registerLegacyWidget } from './LegacyWidgetHost';
import { createMx, mxuiModules, MxStore, type MxEnvironment } from './mx';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Any = any;

const schema = {
  modules: [
    {
      name: 'App',
      models: [
        {
          name: 'App.Order',
          attributes: [
            { name: 'Name', type: 'String' },
            { name: 'Total', type: 'Decimal' },
            { name: 'Count', type: 'Integer' },
            { name: 'Placed', type: 'DateTime' },
            { name: 'Status', type: 'Enumeration', enumeration: 'App.Status' },
            { name: 'Done', type: 'Boolean' },
          ],
        },
        { name: 'App.Tag', attributes: [{ name: 'Label', type: 'String' }] },
      ],
      associations: [
        {
          name: 'App.Order_Tag',
          from_entity: 'App.Order',
          to_entity: 'App.Tag',
          type: 'ReferenceSet',
        },
        {
          name: 'App.Order_Owner',
          from_entity: 'App.Order',
          to_entity: 'App.Tag',
          type: 'Reference',
        },
      ],
      enumerations: [
        {
          id: 'App.Status',
          name: 'App.Status',
          values: [{ name: 'Open', caption: 'Open', caption_translations: { pt_BR: 'Aberto' } }],
        },
      ],
    },
  ],
} as unknown as ApplicationSchema;

const tag = (id: string, label: string): EntityRecord => ({
  id,
  type: 'App.Tag',
  attributes: { Label: label },
});
const order = (attributes: Record<string, RuntimeValue> = {}): EntityRecord => ({
  id: 'o1',
  type: 'App.Order',
  attributes: {
    Name: 'First',
    Total: { __mxrb_decimal: '12.5' },
    Count: 3,
    Placed: '2026-10-14T12:00:00.000Z',
    Status: 'Open',
    Done: false,
    Order_Tag: [tag('t1', 'Red')],
    Order_Owner: tag('t2', 'Blue'),
    ...attributes,
  },
});

const environment = (extra: Partial<MxEnvironment> = {}): MxEnvironment => ({
  schema,
  session: { id: '7', username: 'ana', roles: ['User'] },
  locale: 'en-US',
  save: vi.fn(async (record: EntityRecord, member: string, value: RuntimeValue) => ({
    ...record,
    attributes: { ...record.attributes, [member]: value },
  })),
  ...extra,
});

describe('AMD loader', () => {
  it('loads package modules, templates, shims and relative dependencies once', async () => {
    const loader = new AmdLoader(
      {
        'pkg/widget/Main.js':
          "define(['./helper', 'dojo/text!pkg/widget/templates/Main.html', 'shim', 'require', 'exports', 'module'], " +
          'function (helper, template, shim, req, exports, module) { return { helper: helper, template: template, shim: shim, req: typeof req, module: typeof module }; });\n' +
          "require(['pkg/widget/Main'], function () {});",
        'pkg/widget/helper.js': "define('named', [], { value: 1 });",
        'pkg/widget/templates/Main.html': '<div></div>',
        'pkg/lib/plain.js': 'globalThis.__plain = 1;',
        'pkg/lib/exports.js': "define(['exports'], function (exports) { exports.answer = 42; });",
      },
      { shim: 'from shim' },
    );
    const main = (await loader.load('pkg/widget/Main')) as Any;
    expect(main).toEqual({
      helper: { value: 1 },
      template: '<div></div>',
      shim: 'from shim',
      req: 'function',
      module: 'object',
    });
    expect(await loader.load('pkg/widget/Main')).toBe(main);
    expect(await loader.load('pkg/lib/plain')).toEqual({});
    expect(await loader.load('pkg/lib/exports')).toEqual({ answer: 42 });
    await expect(loader.load('pkg/missing')).rejects.toThrow(
      'Widget module pkg/missing is missing',
    );
    await expect(loader.load('dojo/text!pkg/none.html')).rejects.toThrow(
      'Widget template pkg/none.html is missing',
    );
  });
});

describe('dojo shims', () => {
  it('declares classes with mixins, constructors and inherited calls in strict mode', () => {
    const calls: string[] = [];
    const Base = declare(null, {
      constructor() {
        calls.push('base');
      },
      greet(this: Any, name: string) {
        return `hello ${name}`;
      },
    });
    const Mixin = declare(null, {
      greet(this: Any, ...values: Any[]) {
        return `${this.inherited(values)}!`;
      },
    });
    const Child = declare('App.Child', [Base, Mixin], {
      constructor() {
        calls.push('child');
      },
      greet(this: Any, ...values: Any[]) {
        return this.inherited(values).toUpperCase();
      },
      postscript(this: Any, value: string) {
        calls.push(`postscript ${value}`);
      },
    });
    const child = new Child('x') as Any;
    expect(calls).toEqual(['base', 'child', 'postscript x']);
    expect(child.greet('ana')).toBe('HELLO ANA!');
    expect(child.declaredClass).toBe('App.Child');
    expect(child.isInstanceOf(Child)).toBe(true);
    expect(child.inherited([])).toBeUndefined();
    function Plain(this: Any) {
      this.plain = true;
    }
    Plain.prototype.base = () => 'plain';
    const FromPlain = declare(Plain as Any, {}) as Any;
    expect(new FromPlain().plain).toBe(true);
    FromPlain.extend({ added: () => 'added' });
    expect(new FromPlain().added()).toBe('added');
  });

  it('provides lang, array and DOM helpers', () => {
    const scope = {
      name: 'ana',
      say(this: Any, greeting: string) {
        return `${greeting} ${this.name}`;
      },
    };
    expect(lang.hitch(scope, 'say', 'hi')()).toBe('hi ana');
    expect(lang.hitch(scope, scope.say)('hey')).toBe('hey ana');
    expect(lang.mixin({ a: 1 }, { b: 2 })).toEqual({ a: 1, b: 2 });
    expect(lang.replace('{a} {b.c}', { a: 1, b: { c: 2 } })).toBe('1 2');
    expect(lang.getObject('x.y', true, {})).toEqual({});
    expect(lang.isArray([])).toBe(true);
    expect(array.map([1, 2], (value: number) => value * 2)).toEqual([2, 4]);
    expect(array.indexOf([1, 2], 2)).toBe(1);
    const node = domConstruct.create(
      'div',
      { class: 'a', innerHTML: '<span>x</span>', title: 'T' },
      document.body,
    );
    domClass.add(node, 'b c');
    domClass.remove(node, 'a');
    expect(node.className).toBe('b c');
    expect(domClass.contains(node, 'b')).toBe(true);
    domAttr.set(node, 'data-x', 1);
    expect(domAttr.get(node, 'data-x')).toBe('1');
    domConstruct.place('<p>first</p>', node, 'first');
    expect(node.firstChild?.textContent).toBe('first');
    domConstruct.empty(node);
    expect(node.childNodes).toHaveLength(0);
    domConstruct.destroy(node);
    expect(node.isConnected).toBe(false);
    const modules = dojoModules() as Any;
    const query = modules['dojo/query'];
    document.body.innerHTML = '<ul><li>a</li><li>b</li></ul>';
    expect(query('li').addClass('item')).toHaveLength(2);
    expect(
      modules['dojo/date/locale'].format(new Date(2026, 9, 14), {
        selector: 'date',
        datePattern: 'yyyy-MM-dd',
      }),
    ).toBe('2026-10-14');
  });
});

describe('mx and MxObject', () => {
  it('reads values as the Mendix client returns them and writes changes back', async () => {
    const env = environment();
    const store = new MxStore(env);
    const object = store.remember(order(), true);
    expect(object.getGuid()).toBe('o1');
    expect(object.getEntity()).toBe('App.Order');
    expect(object.get('Total')).toEqual(new Big('12.5'));
    expect(object.get('Count')).toEqual(new Big(3));
    expect(object.get('Placed')).toBe(Date.parse('2026-10-14T12:00:00.000Z'));
    expect(object.getAttributeType('Status')).toBe('Enum');
    expect(object.isEnum('Status') && object.isDate('Placed') && object.isNumeric('Total')).toBe(
      true,
    );
    expect(object.getEnumCaption('Status')).toBe('Open');
    expect(object.getReferences('App.Order_Tag')).toEqual(['t1']);
    expect(object.getReference('App.Order_Owner')).toBe('t2');
    expect(object.get('App.Order_Tag')).toEqual(['t1']);
    expect(object.getAttributeType('App.Order_Owner')).toBe('ObjectReference');

    const listener = vi.fn();
    store.subscribe({ guid: 'o1', attr: 'App.Order_Tag', callback: listener });
    const objectListener = vi.fn();
    store.subscribe({ guid: 'o1', callback: objectListener });
    store.remember(tag('t3', 'Green'));
    object.addReference('App.Order_Tag', 't3');
    await waitFor(() => expect(env.save).toHaveBeenCalled());
    expect(env.save).toHaveBeenCalledWith(expect.objectContaining({ id: 'o1' }), 'Order_Tag', [
      tag('t1', 'Red'),
      tag('t3', 'Green'),
    ]);
    expect(listener).toHaveBeenCalledWith('o1', 'App.Order_Tag', ['t1', 't3']);
    expect(objectListener).not.toHaveBeenCalled();
    object.removeReferences('App.Order_Tag', ['t1']);
    await waitFor(() => expect(object.getReferences('App.Order_Tag')).toEqual(['t3']));
    object.set('Total', new Big('3.25'));
    object.set('Count', new Big(4));
    object.set('Placed', 0);
    object.set('App.Order_Owner', 't3');
    object.set('Name', 'Renamed');
    await waitFor(() => expect(object.get('Name')).toBe('Renamed'));
    expect(object.get('Total')).toEqual(new Big('3.25'));
    expect(object.getReference('App.Order_Owner')).toBe('t3');
    store.changed(order());
    expect(objectListener).toHaveBeenCalledWith('o1');
  });

  it('runs microflows, retrievals and session queries through the runtime', async () => {
    const request = vi.fn<(path: string, init?: { body?: string }) => Promise<unknown>>(
      async (path) =>
        path.startsWith('/api/microflows/')
          ? { result: [tag('t1', 'Red'), tag('t2', 'Blue')] }
          : { records: [tag('t2', 'b'), tag('t1', 'a')] },
    );
    const store = new MxStore(environment({ request: request as unknown as ApiRequest }));
    store.remember(order(), true);
    const mx = createMx(store) as Any;
    const result = await new Promise<Any>((resolve) =>
      mx.ui.action('App.DS_Tags', {
        params: { applyto: 'selection', guids: ['o1'] },
        callback: resolve,
      }),
    );
    expect(result.map((item: Any) => item.get('Label'))).toEqual(['Red', 'Blue']);
    expect(JSON.parse(String(request.mock.calls[0][1]?.body)).__mxrb_context.id).toBe('o1');
    const retrieved = await new Promise<Any>((resolve) =>
      mx.data.get({
        xpath: '//App.Tag[Label != empty]',
        filter: { sort: [['Label', 'asc']] },
        callback: resolve,
      }),
    );
    expect(retrieved.map((item: Any) => item.getGuid())).toEqual(['t1', 't2']);
    expect(request).toHaveBeenLastCalledWith(
      '/api/entities/App.Tag?xpath=%5BLabel+%21%3D+empty%5D',
    );
    const byGuid = await new Promise<Any>((resolve) =>
      mx.data.get({ guid: 't1', callback: resolve }),
    );
    expect(byGuid.get('Label')).toBe('a');
    const failure = await new Promise<Any>((resolve) =>
      mx.data.get({ guid: 'missing', error: resolve }),
    );
    expect(String(failure)).toContain('missing');
    expect(mx.session.getUserName()).toBe('ana');
    expect(mx.session.getUserRoleNames()).toEqual(['User']);
    expect(mx.session.isGuest()).toBe(false);
    expect(mx.parser.formatValue(new Big('1234.5'), 'Decimal', { places: 2, groups: true })).toBe(
      '1,234.50',
    );
    expect(mx.ui.getContentForm().path).toBe(window.location.pathname);
  });
});

describe('legacy widget host', () => {
  it('maps package properties to the values the Mendix client passes', () => {
    expect(
      legacyParams(
        [
          { key: 'caption', type: 'TranslatableString' },
          { key: 'attribute', type: 'Attribute' },
          { key: 'flag', type: 'Boolean', default: 'true' },
          { key: 'size', type: 'Integer', default: '4' },
          { key: 'path', type: 'Entity' },
          { key: 'rows', type: 'Object', properties: [{ key: 'name', type: 'String' }] },
          { key: 'mode', type: 'Enumeration', default: 'a' },
        ],
        {
          caption: { en_US: 'Hello', pt_BR: 'Olá' },
          attribute: 'App.Order.Name',
          path: 'App.Order_Tag/App.Tag',
          rows: { objects: [{ name: 'one' }] },
        },
        'pt-BR',
      ),
    ).toEqual({
      caption: 'Olá',
      attribute: 'Name',
      flag: true,
      size: 4,
      path: 'App.Order_Tag/App.Tag',
      rows: [{ name: 'one' }],
      mode: 'a',
    });
  });

  it('creates, updates and destroys a Dojo widget of the project package', async () => {
    const source = `define(['dojo/_base/declare', 'mxui/widget/_WidgetBase', 'dijit/_TemplatedMixin', 'dojo/text!pkg/widget/Tags.html'],
      function (declare, _WidgetBase, _TemplatedMixin, template) {
        'use strict';
        return declare('pkg.widget.Tags', [_WidgetBase, _TemplatedMixin], {
          templateString: template,
          postCreate: function () { this.labelNode.textContent = this.caption; },
          update: function (obj, callback) {
            this._obj = obj;
            this.valueNode.textContent = obj ? obj.getReferences(this.reference.split('/')[0]).join(',') : 'none';
            callback();
          },
          _add: function () { this._obj.addReference(this.reference.split('/')[0], 't9'); },
          uninitialize: function () { window.__destroyed = true; }
        });
      });`;
    const unregister = registerLegacyWidget(
      'pkg.widget.Tags',
      {
        './vendor/pkg/widget/Tags.js': source,
        './vendor/pkg/widget/Tags.html':
          '<div><label data-dojo-attach-point="labelNode"></label><span data-dojo-attach-point="valueNode"></span>' +
          '<button data-dojo-attach-event="onclick:_add">add</button></div>',
      },
      './vendor/',
      'pkg/widget/Tags',
      [
        { key: 'caption', type: 'TranslatableString' },
        { key: 'reference', type: 'Entity' },
      ],
    );
    let current = order();
    const onChange = vi.fn(async (member: string | undefined, value: RuntimeValue) => {
      current = { ...current, attributes: { ...current.attributes, [String(member)]: value } };
      return current;
    });
    const props = (context: EntityRecord | null): MarketplaceWidgetProps => ({
      widget: {
        type: 'pluggable_widget',
        name: 'tags1',
        options: {
          widget_id: 'pkg.widget.Tags',
          properties: { caption: { en_US: 'Tags' }, reference: 'App.Order_Tag/App.Tag' },
        },
      },
      context,
      schema,
      onChange,
    });
    const view = render(<MarketplaceWidget {...props(current)} />);
    await waitFor(() => expect(view.container.querySelector('label')?.textContent).toBe('Tags'));
    expect(view.container.querySelector('span')?.textContent).toBe('t1');
    act(() => view.container.querySelector('button')!.click());
    await waitFor(() =>
      expect(onChange).toHaveBeenCalledWith('Order_Tag', [tag('t1', 'Red'), 't9']),
    );
    view.rerender(<MarketplaceWidget {...props(current)} />);
    view.rerender(
      <MarketplaceWidget {...props({ ...order(), id: 'o2', attributes: { Order_Tag: [] } })} />,
    );
    await waitFor(() => expect(view.container.querySelector('span')?.textContent).toBe(''));
    view.rerender(<MarketplaceWidget {...props(null)} />);
    await waitFor(() => expect(view.container.querySelector('span')?.textContent).toBe('none'));
    view.unmount();
    expect((window as Any).__destroyed).toBe(true);
    unregister();
  });

  it('shows why a widget package cannot run', async () => {
    const unregister = registerLegacyWidget('pkg.Broken', {}, '', 'pkg/Broken', []);
    const view = render(
      <MarketplaceWidget
        widget={{ type: 'pluggable_widget', name: 'b', options: { widget_id: 'pkg.Broken' } }}
        context={null}
        onChange={vi.fn()}
      />,
    );
    await waitFor(() =>
      expect(view.container.querySelector('[role=alert]')?.textContent).toBe(
        'Widget module pkg/Broken is missing',
      ),
    );
    unregister();
  });
});

it('exposes the mxui widget base and dom helpers', () => {
  const modules = mxuiModules(new MxStore(environment())) as Any;
  const Base = modules['mxui/widget/_WidgetBase'];
  const widget = new Base({ caption: 'x', class: 'one two', style: 'color: red' }) as Any;
  expect(widget.domNode.id).toBe(widget.id);
  expect(widget.domNode.className).toBe('one two');
  expect(widget.params).toEqual({ caption: 'x', class: 'one two', style: 'color: red' });
  expect(widget.set('readOnly', true).get('readOnly')).toBe(true);
  const target = { onChange: () => 'original' } as Any;
  const handled = vi.fn();
  const handle = widget.connect(target, 'onChange', handled);
  expect(target.onChange('v')).toBe('original');
  expect(handled).toHaveBeenCalledWith('v');
  handle.remove();
  const element = modules['mxui/dom'].create(
    'p',
    { class: 'c' },
    'text',
    modules['mxui/dom'].create('b'),
  );
  expect(element.outerHTML).toBe('<p class="c">text<b></b></p>');
  expect(modules['mxui/dom'].escapeString('<a>')).toBe('&#60;a&#62;');
  widget.destroy();
  expect(widget._destroyed).toBe(true);
});
