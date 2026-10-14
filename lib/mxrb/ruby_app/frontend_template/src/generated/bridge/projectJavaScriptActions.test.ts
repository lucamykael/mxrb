import Big from 'big.js';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { clientServices, provideClientServices } from './clientServices';
import { installMx, MxObject } from './legacy/mx';
import { projectJavaScriptActions } from './projectJavaScriptActions';
import type { EntityRecord } from '../types';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Any = any;

const record = (id: string, attributes: Record<string, unknown> = {}): EntityRecord =>
  ({ id, type: 'App.Item', attributes }) as EntityRecord;

const mx = () => (globalThis as Any).mx;

afterEach(() => vi.useRealTimers());

describe('project JavaScript actions', () => {
  it('passes objects, Big numbers and dates, and returns changes and results to the nanoflow', async () => {
    const seen: unknown[] = [];
    const module = {
      Update: async (item: Any, items: Any[], amount: Big, when: Date, label: string) => {
        seen.push(
          item instanceof MxObject,
          items.length,
          amount.toString(),
          when.toISOString(),
          label,
        );
        item.set('Name', 'changed');
        return items[1];
      },
      Count: async () => new Big(3),
      Ratio: async () => new Big('2.5'),
      When: async () => new Date('2026-10-14T00:00:00.000Z'),
      List: async (items: Any[]) => items,
      Plain: async () => 'plain',
      Nothing: async (item: Any, amount: Any) => [item, amount],
    };
    const actions = projectJavaScriptActions(
      { './vendor/app/actions/All.js': async () => module },
      './vendor/',
      Object.fromEntries(
        [
          [
            'Update',
            ['item:MxObject', 'items:MxObject[]', 'amount:Big', 'when:Date', 'label:string'],
          ],
          ['Count', []],
          ['Ratio', []],
          ['When', []],
          ['List', ['items:MxObject[]']],
          ['Plain', []],
          ['Nothing', ['item:MxObject[]', 'amount:Big']],
        ].map(([name, parameters]) => [
          `App.${name}`,
          {
            path: 'app/actions/All.js',
            function: name as string,
            parameters: (parameters as string[]).map((entry) => {
              const [key, type] = entry.split(':');
              return { name: key, type };
            }),
          },
        ]),
      ),
    );
    const item = record('1', { Name: 'before' });
    const second = record('2');
    const result = await actions['App.Update'](
      {
        item,
        items: [item, second],
        amount: { __mxrb_decimal: '1.5' },
        when: '2026-10-14T12:00:00.000Z',
        label: 'x',
      },
      {},
      { userRoles: ['User'] },
    );
    expect(mx().session.getUserRoleNames()).toEqual(['User']);
    expect(seen).toEqual([true, 2, '1.5', '2026-10-14T12:00:00.000Z', 'x']);
    expect(item.attributes.Name).toBe('changed');
    expect(result).toEqual(second);
    expect(await actions['App.Count']({})).toBe(3);
    expect(await actions['App.Ratio']({})).toEqual({ __mxrb_decimal: '2.5' });
    expect(await actions['App.When']({})).toBe('2026-10-14T00:00:00.000Z');
    expect(await actions['App.List']({ items: [second] })).toEqual([second]);
    expect(await actions['App.Plain']({})).toBe('plain');
    expect(await actions['App.Nothing']({ item: null, amount: 4 })).toEqual([[], 4]);
  });

  it('reports a missing source or function', async () => {
    const actions = projectJavaScriptActions(
      { './vendor/app/actions/A.js': async () => ({}) },
      './vendor/',
      {
        'App.A': { path: 'app/actions/A.js', function: 'A', parameters: [] },
        'App.B': { path: 'app/actions/B.js', function: 'B', parameters: [] },
      },
    );
    await expect(actions['App.A']({})).rejects.toThrow('app/actions/A.js exports no A');
    await expect(actions['App.B']({})).rejects.toThrow('JavaScript action source not found: App.B');
  });
});

describe('client services', () => {
  it('answer mx.ui and mx.data.update with the running application', async () => {
    const services = {
      refresh: vi.fn(),
      confirm: vi.fn(async ({ question }: { question: string }) => question === 'Yes?'),
      progress: vi.fn(),
      notify: vi.fn(),
      logout: vi.fn(),
    };
    const restore = provideClientServices(services);
    expect(clientServices()).toBe(services);
    installMx({ session: {}, locale: 'en-US' });
    const handler = vi.fn();
    const onCancel = vi.fn();
    mx().ui.confirmation({ content: 'Yes?', proceed: 'Go', cancel: 'Stop', handler, onCancel });
    mx().ui.confirmation({ content: 'No?', handler, onCancel });
    await vi.waitFor(() => expect(onCancel).toHaveBeenCalled());
    expect(handler).toHaveBeenCalledTimes(1);
    expect(services.confirm).toHaveBeenCalledWith({
      question: 'Yes?',
      proceed: 'Go',
      cancel: 'Stop',
    });
    const first = mx().ui.showProgress('a', true);
    const second = mx().ui.showProgress();
    mx().ui.hideProgress(first);
    expect(services.progress).toHaveBeenLastCalledWith(true);
    mx().ui.hideProgress(second);
    expect(services.progress).toHaveBeenLastCalledWith(false);
    const callback = vi.fn();
    mx().data.update({ entity: 'App.Item', callback });
    expect(services.refresh).toHaveBeenCalledWith({ guid: undefined, entity: 'App.Item' });
    expect(callback).toHaveBeenCalled();
    mx().ui.info('Saved');
    expect(services.notify).toHaveBeenCalledWith('info', 'Saved');
    mx().logout();
    expect(services.logout).toHaveBeenCalled();
    restore();
    expect(clientServices()).toEqual({});
    const later = provideClientServices({});
    restore();
    expect(clientServices()).not.toBe(services);
    later();
    mx().ui.confirmation({ content: 'Without services', handler });
    await vi.waitFor(() => expect(handler).toHaveBeenCalledTimes(2));
  });

  it('installs window.mx when an action imports mx-global', async () => {
    await import('./legacy/mxGlobal');
    expect(typeof mx().data.get).toBe('function');
  });
});
