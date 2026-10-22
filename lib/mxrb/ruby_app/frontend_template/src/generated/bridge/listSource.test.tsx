import { render, renderHook, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import type {
  ApiRequest,
  ApplicationSchema,
  DataViewSource,
  EntityRecord,
  WidgetDefinition,
} from '../types';
import { DataGrid } from './components/DataGrid';
import { marketplaceDataSource, useMarketplaceRecords } from './components/marketplaceData';
import { WidgetRenderer } from './components/WidgetRenderer';
import { ListSourceNanoflows, loadListSource, sourceMappings, sourceStart } from './listSource';
import { PageParameters } from './PageVariables';

const item = (id: string, Name: string, type = 'App.Item'): EntityRecord => ({
  id,
  type,
  attributes: { Name },
});
const owner = item('o1', 'Owner', 'App.Owner');
const schema = {
  modules: [{ models: [{ name: 'App.Item', attributes: [{ name: 'Name', type: 'string' }] }] }],
} as unknown as ApplicationSchema;
const microflow: DataViewSource = {
  kind: 'microflow',
  name: 'App.DS_Items',
  mappings: [
    { parameter: 'App.DS_Items.Owner', variable: { kind: 'page_parameter', name: 'Owner' } },
    { parameter: 'App.DS_Items.Limit', expression: '2 + 1' },
  ],
};

describe('list data sources', () => {
  it('passes a microflow its mapped arguments and the start object', async () => {
    const request = vi.fn().mockResolvedValue({ result: [item('1', 'A'), 'noise', null] });
    const records = await loadListSource(
      microflow,
      owner,
      { Owner: owner, Limit: 3 },
      request as unknown as ApiRequest,
      null,
    );
    expect(records).toEqual([item('1', 'A')]);
    expect(request).toHaveBeenCalledWith('/api/microflows/App.DS_Items', {
      method: 'POST',
      body: JSON.stringify({ Owner: owner, Limit: 3, __mxrb_context: owner }),
    });
    const single = vi.fn().mockResolvedValue({ result: item('2', 'B') });
    expect(
      await loadListSource(microflow, null, {}, single as unknown as ApiRequest, null),
    ).toEqual([item('2', 'B')]);
    expect(JSON.parse(single.mock.calls[0][1].body)).toEqual({});
  });

  it('runs a nanoflow through the page invoker', async () => {
    const invoke = vi.fn().mockResolvedValue([item('3', 'C')]);
    const source: DataViewSource = { kind: 'nanoflow', name: 'App.NF_Items' };
    const request = vi.fn() as unknown as ApiRequest;
    expect(await loadListSource(source, owner, { Limit: 1 }, request, invoke)).toEqual([
      item('3', 'C'),
    ]);
    expect(invoke).toHaveBeenCalledWith('App.NF_Items', { Limit: 1 }, owner);
    await expect(loadListSource(source, owner, {}, request, null)).rejects.toThrow(
      /cannot run here/,
    );
  });

  it('follows every association step from the start object without duplicates', async () => {
    const request = vi.fn(async (path: string) => {
      const query = new URLSearchParams(path.split('?')[1]);
      if (query.get('association') === 'App.Owner_Group')
        return { records: [item('g1', 'G1', 'App.Group'), item('g2', 'G2', 'App.Group')] };
      return { records: [item('1', `from ${query.get('context_id')}`), item('shared', 'S')] };
    });
    const source: DataViewSource = {
      kind: 'association',
      steps: [
        { association: 'App.Owner_Group', entity: 'App.Group' },
        { association: 'App.Group_Item', entity: 'App.Item' },
      ],
    };
    const records = await loadListSource(source, owner, {}, request as unknown as ApiRequest, null);
    expect(records.map((record) => record.id)).toEqual(['1', 'shared']);
    expect(request).toHaveBeenCalledTimes(3);
    expect(await loadListSource(source, null, {}, request as unknown as ApiRequest, null)).toEqual(
      [],
    );
    await expect(
      loadListSource(
        { kind: 'association', steps: [{ association: 'App.Owner_Group' }] },
        owner,
        {},
        request as unknown as ApiRequest,
        null,
      ),
    ).rejects.toThrow(/destination at each step/);
    await expect(
      loadListSource({ kind: 'listen' }, owner, {}, request as unknown as ApiRequest, null),
    ).rejects.toThrow(/unsupported list data source listen/);
  });

  it('evaluates mappings and finds the start object of a source variable', () => {
    const scopes = {
      pageParameters: { Owner: owner },
      localVariables: { Draft: item('d', 'Draft') },
      widgetValues: { picked: item('w', 'Picked') },
      snippetParameters: { Shared: item('s', 'Shared') },
    };
    expect(sourceMappings(microflow, owner, scopes)).toEqual({ Owner: owner, Limit: 3 });
    expect(sourceMappings(undefined, owner, scopes)).toEqual({});
    const from = (kind: string, name: string) =>
      sourceStart({ kind: 'association', variable: { kind, name } }, owner, scopes)?.id;
    expect(from('page_parameter', 'Owner')).toBe('o1');
    expect(from('local_variable', 'Draft')).toBe('d');
    expect(from('widget', 'picked')).toBe('w');
    expect(from('snippet_parameter', 'Shared')).toBe('s');
    expect(from('page_parameter', 'Missing')).toBeUndefined();
    expect(sourceStart({ kind: 'association' }, owner, scopes)).toBe(owner);
  });
});

describe('widgets over a microflow, nanoflow or association source', () => {
  const runtime = {
    pageContext: owner,
    revision: 0,
    onError: vi.fn(),
    onMutation: vi.fn(),
    onRowAction: vi.fn(),
    onSelectRecord: vi.fn(),
  };

  it('fills a Data grid 2 from its microflow and filters it in the browser', async () => {
    const user = userEvent.setup();
    const request = vi.fn().mockResolvedValue({
      result: [item('1', 'Alpha'), item('2', 'Beta'), item('3', 'Alphabet')],
    });
    const grid: WidgetDefinition = {
      type: 'data_grid',
      name: 'items',
      options: {
        presentation: 'datagrid2',
        source: microflow,
        server_side: true,
        columns: [{ name: 'Name', attribute: 'App.Item.Name', filter: { type: 'text' } }],
      },
    };
    render(
      <PageParameters.Provider value={{ Owner: owner }}>
        <DataGrid
          {...runtime}
          widget={grid}
          request={request as unknown as ApiRequest}
          schema={schema}
        />
      </PageParameters.Provider>,
    );
    expect(await screen.findByText('Alphabet')).toBeInTheDocument();
    expect(request).toHaveBeenCalledTimes(1);
    expect(JSON.parse(request.mock.calls[0][1].body)).toMatchObject({ Owner: owner, Limit: 3 });
    await user.type(screen.getByRole('searchbox', { name: 'Filter Name' }), 'alpha');
    await waitFor(() => expect(screen.queryByText('Beta')).not.toBeInTheDocument());
    expect(screen.getByText('Alpha')).toBeInTheDocument();
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('reports a failing source and lists a gallery from a nanoflow', async () => {
    const onError = vi.fn();
    const failing = vi.fn().mockRejectedValue(new Error('denied'));
    render(
      <DataGrid
        {...runtime}
        onError={onError}
        widget={{ type: 'data_grid', name: 'g', options: { source: microflow, columns: [] } }}
        request={failing as unknown as ApiRequest}
      />,
    );
    await waitFor(() => expect(onError).toHaveBeenCalledWith(new Error('Error: denied')));

    const invoke = vi.fn().mockResolvedValue([item('9', 'Nine'), item('8', 'Eight')]);
    const gallery: WidgetDefinition = {
      type: 'gallery',
      name: 'Items',
      options: {
        source: { kind: 'nanoflow', name: 'App.NF_Items' },
        sort: [{ attribute: 'App.Item.Name', direction: 'Ascending' }],
      },
      children: [
        {
          type: 'text',
          name: 'label',
          options: { caption: '{1}', parameters: ['$currentObject/Name'] },
        },
      ],
    };
    const request = vi.fn();
    render(
      <ListSourceNanoflows.Provider value={invoke}>
        <WidgetRenderer
          widget={gallery}
          moduleName="App"
          invoke={vi.fn()}
          invokeNanoflow={invoke}
          navigate={vi.fn()}
          context={owner}
          pageContext={owner}
          revision={0}
          schema={schema}
          request={request as unknown as ApiRequest}
          saveRecord={vi.fn()}
          onError={vi.fn()}
          onMutation={vi.fn()}
          onSelectRecord={vi.fn()}
        />
      </ListSourceNanoflows.Provider>,
    );
    await waitFor(() => expect(document.querySelectorAll('.gallery-item')).toHaveLength(2));
    expect(invoke).toHaveBeenCalledWith('App.NF_Items', {}, owner);
    expect(request).not.toHaveBeenCalled();
    expect(document.querySelector('.gallery-item')?.textContent).toBe('Eight');
  });

  it('loads pluggable widget records from a microflow data source', async () => {
    const request = vi.fn().mockResolvedValue({ result: [item('2', 'B'), item('1', 'A')] });
    const value = {
      data_source: {
        entity: '',
        xpath: '',
        sort: [{ attribute: 'App.Item.Name', direction: 'Ascending' }],
        source: microflow,
      },
    };
    const { result } = renderHook(() =>
      useMarketplaceRecords(value, { context: owner, request: request as unknown as ApiRequest }),
    );
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.records.map((record) => record.id)).toEqual(['1', '2']);
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('reads the flat data source the page projection writes', () => {
    expect(marketplaceDataSource({ source: microflow })).toEqual({
      entity: '',
      xpath: '',
      sort: [],
      source: microflow,
    });
    expect(
      marketplaceDataSource({
        data_source: 'App.Item',
        xpath: '[Name != empty]',
        sort: [{ attribute: 'App.Item.Name', direction: 'Descending' }],
      }),
    ).toEqual({
      entity: 'App.Item',
      xpath: '[Name != empty]',
      sort: [{ attribute: 'App.Item.Name', direction: 'Descending' }],
    });
    expect(marketplaceDataSource({})).toBeUndefined();
  });
});

describe('a nanoflow list source on a page that renders again', () => {
  it('runs the nanoflow once although the page hands a new invoker on every render', async () => {
    const calls: number[] = [];
    const request = vi.fn() as unknown as ApiRequest;
    const value = {
      data_source: {
        entity: '',
        xpath: '',
        sort: [],
        source: { kind: 'nanoflow', name: 'App.NF' },
      },
    };
    function Probe() {
      const { records } = useMarketplaceRecords(value, { context: null, request, revision: 0 });
      return <span data-testid="names">{records.map((r) => r.attributes.Name).join(',')}</span>;
    }
    // A new invoker on each render, as the application runtime passes it.
    function Host({ round }: { round: number }) {
      const invoke = async () => {
        calls.push(round);
        return [item(String(round), `Round ${round}`)];
      };
      return (
        <ListSourceNanoflows.Provider value={invoke as never}>
          <Probe />
        </ListSourceNanoflows.Provider>
      );
    }
    const view = render(<Host round={1} />);
    await waitFor(() => expect(screen.getByTestId('names')).toHaveTextContent('Round 1'));
    view.rerender(<Host round={2} />);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(calls).toEqual([1]);
    expect(screen.getByTestId('names')).toHaveTextContent('Round 1');
  });
});
