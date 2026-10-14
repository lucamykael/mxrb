import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MarketplaceWidget, type MarketplaceWidgetProps } from '../marketplace';
import type { ApiRequest, ApplicationSchema, EntityRecord, RuntimeValue } from '../../types';

const record = (id: string, attributes: Record<string, RuntimeValue>): EntityRecord => ({
  id,
  type: 'App.Tag',
  attributes,
});
const action = (handler: string) => ({ action: { kind: 'microflow', handler, arguments: {} } });

const setup = (
  widgetId: string,
  properties: Record<string, unknown>,
  collections: Record<string, EntityRecord[]>,
  attributes: Record<string, RuntimeValue> = {},
): MarketplaceWidgetProps => {
  const context: EntityRecord = { id: 'ctx', type: 'App.Item', attributes };
  const request = vi.fn(async (path: string) => ({
    records: collections[decodeURIComponent(path.split('/').pop()!.split('?')[0])] || [],
  }));
  return {
    widget: {
      type: 'pluggable_widget',
      name: 'Selection',
      options: { widget_id: widgetId, properties },
    },
    context,
    schema: { modules: [] } as unknown as ApplicationSchema,
    request: request as unknown as ApiRequest,
    onChange: vi.fn(async (attribute: string | undefined, value: RuntimeValue) => {
      context.attributes[String(attribute).split('.').pop() || ''] = value;
    }),
    onAction: vi.fn().mockResolvedValue(undefined),
  };
};

describe('tag selector', () => {
  const properties = {
    tagLabel: 'App.Item.NewTag',
    selectTag: action('App.Select'),
    createTag: action('App.Create'),
    removeTag: action('App.Remove'),
    removeAllTags: action('App.RemoveAll'),
    currentTags: { data_source: { entity: 'App.Current', xpath: '', sort: [] } },
    currentTagLabel: 'App.Current.Name',
    tagSuggestions: { data_source: { entity: 'App.Suggestion', xpath: '', sort: [] } },
    tagSuggestionsLabel: 'App.Suggestion.Name',
    enableCreate: true,
    enableComma: true,
  };
  const collections = {
    'App.Current': [record('1', { Name: 'red' })],
    'App.Suggestion': [record('2', { Name: 'red' }), record('3', { Name: 'blue' })],
  };

  it('selects a suggestion, creates new tags, removes and clears through the label attribute', async () => {
    const props = setup('mendix.tagselector.TagSelector', properties, collections);
    render(<MarketplaceWidget {...props} />);
    await screen.findByText('red');
    expect(
      [...document.querySelectorAll('datalist option')].map((option) =>
        option.getAttribute('value'),
      ),
    ).toEqual(['blue']);
    const input = screen.getByLabelText('Selection');
    fireEvent.change(input, { target: { value: 'blue' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() =>
      expect(props.onAction).toHaveBeenCalledWith(
        expect.objectContaining({ handler: 'App.Select' }),
        props.context,
      ),
    );
    expect(props.onChange).toHaveBeenCalledWith('App.Item.NewTag', 'blue');

    fireEvent.change(input, { target: { value: 'green' } });
    fireEvent.keyDown(input, { key: ',' });
    await waitFor(() =>
      expect(props.onAction).toHaveBeenCalledWith(
        expect.objectContaining({ handler: 'App.Create' }),
        props.context,
      ),
    );
    expect(props.onChange).toHaveBeenLastCalledWith('App.Item.NewTag', 'green');

    fireEvent.click(screen.getByLabelText('Remove red'));
    await waitFor(() =>
      expect(props.onAction).toHaveBeenCalledWith(
        expect.objectContaining({ handler: 'App.Remove' }),
        props.context,
      ),
    );
    fireEvent.click(screen.getByText('Clear'));
    await waitFor(() =>
      expect(props.onAction).toHaveBeenCalledWith(
        expect.objectContaining({ handler: 'App.RemoveAll' }),
        props.context,
      ),
    );
  });

  it('removes the last tag with backspace on an empty input', async () => {
    const props = setup('mendix.tagselector.TagSelector', properties, collections);
    render(<MarketplaceWidget {...props} />);
    await screen.findByText('red');
    fireEvent.keyDown(screen.getByLabelText('Selection'), { key: 'Backspace' });
    await waitFor(() => expect(props.onChange).toHaveBeenCalledWith('App.Item.NewTag', 'red'));
  });
});

describe('autocomplete multiselect', () => {
  const properties = {
    dataSourceOptions: { data_source: { entity: 'App.Option', xpath: '', sort: [] } },
    titleAttr: 'App.Option.Title',
    keyAttr: 'App.Option.Code',
    defaultSelectedAttr: 'App.Option.Preselected',
    responseAttribute: 'App.Item.Response',
    multiple: true,
    onChangeAction: action('App.Changed'),
  };
  const collections = {
    'App.Option': [
      record('1', { Title: 'Alpha', Code: 'A', Preselected: true }),
      record('2', { Title: 'Beta', Code: 'B', Preselected: false }),
    ],
  };

  it('starts from preselected options, stores JSON and filters by text', async () => {
    const props = setup(
      'itvisors.autocompletemultiselect.AutocompleteMultiselect',
      properties,
      collections,
    );
    render(<MarketplaceWidget {...props} />);
    expect(await screen.findByLabelText('Remove Alpha')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('option', { name: 'Beta' }));
    await waitFor(() => expect(props.onAction).toHaveBeenCalled());
    expect(props.onChange).toHaveBeenCalledWith(
      'App.Item.Response',
      JSON.stringify([
        { title: 'Alpha', key: 'A' },
        { title: 'Beta', key: 'B' },
      ]),
    );
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'alp' } });
    expect(screen.getAllByRole('option').map((option) => option.textContent)).toEqual(['Alpha']);
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'zzz' } });
    expect(screen.getByText('No options')).toBeInTheDocument();
  });

  it('keeps a single selection from the stored response', async () => {
    const props = setup(
      'itvisors.autocompletemultiselect.AutocompleteMultiselect',
      { ...properties, multiple: false },
      collections,
      { Response: JSON.stringify({ title: 'Beta', key: 'B' }) },
    );
    render(<MarketplaceWidget {...props} />);
    expect(await screen.findByLabelText('Remove Beta')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('option', { name: 'Alpha' }));
    await waitFor(() =>
      expect(props.onChange).toHaveBeenCalledWith(
        'App.Item.Response',
        JSON.stringify({ title: 'Alpha', key: 'A' }),
      ),
    );
  });
});
