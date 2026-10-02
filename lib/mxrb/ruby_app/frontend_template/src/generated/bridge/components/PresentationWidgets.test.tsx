import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import type { WidgetRuntimeProps } from '../contracts';
import type { EntityRecord, WidgetDefinition } from '../../types';
import { WidgetRenderer } from './WidgetRenderer';
import { ReadOnlyContext } from './FieldPolicy';

const record: EntityRecord = { id: '1', type: 'Files.Document', attributes: { Tags: [] } };
const props = (widget: WidgetDefinition): WidgetRuntimeProps => ({
  widget,
  moduleName: 'Files',
  context: record,
  pageContext: record,
  revision: 0,
  schema: {
    project: { name: 'Presentation', mendix_version: '11.12.1' },
    modules: [],
    presentation: {
      'Files.Logo': { kind: 'image', path: '/assets/logo.png' },
      'Files.Menu': {
        kind: 'menu',
        items: [
          { caption: 'Home', page: 'Files.Home' },
          { caption: 'More', items: [{ caption: 'Run', microflow: 'Files.Run' }] },
        ],
      },
      'Files.Snippet': {
        kind: 'snippet',
        widgets: [
          {
            type: 'text_box',
            name: 'Name',
            options: { attribute: 'Name', caption: 'Snippet name' },
          },
        ],
      },
      'Files.Cycle': {
        kind: 'snippet',
        widgets: [{ type: 'snippet', name: 'cycle', options: { snippet: 'Files.Cycle' } }],
      },
    },
  },
  invoke: vi.fn(async () => undefined),
  invokeNanoflow: vi.fn(async () => undefined),
  navigate: vi.fn(async () => undefined),
  request: vi.fn(async () => ({ records: [] })) as WidgetRuntimeProps['request'],
  saveRecord: vi.fn(async (current, changes) => ({
    ...current!,
    attributes: { ...current?.attributes, ...changes },
  })),
  onError: vi.fn(),
  onMutation: vi.fn(),
  onSelectRecord: vi.fn(),
});

describe('Standalone presentation widgets', () => {
  it('localizes menu captions and passes named parameters to nanoflow actions', async () => {
    const input = props({
      type: 'menu_bar',
      name: 'Localized',
      options: { menu: 'Files.Menu', locale: 'pt-BR' },
    });
    input.schema.presentation!['Files.Menu'] = {
      kind: 'menu',
      items: [
        {
          caption: 'Run',
          caption_translations: { pt_BR: 'Executar' },
          icon: 'play',
          action: {
            event: 'on_click',
            kind: 'nanoflow',
            handler: 'Other.Run',
            arguments: {
              Document: { kind: 'page_parameter', name: 'Document' },
            },
          },
        },
      ],
    };
    render(<WidgetRenderer {...input} />);
    await userEvent.setup().click(screen.getByRole('button', { name: 'Executar' }));
    expect(input.invokeNanoflow).toHaveBeenCalledWith('Other.Run', { Document: record }, record);
  });

  it('reports missing snippet parameters instead of binding another object implicitly', () => {
    const input = props({
      type: 'snippet',
      name: 'Missing',
      options: { snippet: 'Files.Snippet' },
    });
    input.schema.presentation!['Files.Snippet'].parameters = ['Required'];
    render(<WidgetRenderer {...input} />);
    expect(screen.getByRole('alert')).toHaveTextContent('Missing snippet parameter: Required');
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
  });

  it('binds multiple snippet objects and scalar parameters without changing the page context', async () => {
    const other: EntityRecord = { id: '2', type: record.type, attributes: { Name: 'Other' } };
    const input = props({
      type: 'snippet',
      name: 'mapped',
      options: {
        snippet: 'Files.Mapped',
        arguments: {
          Document: { kind: 'page_parameter', name: 'Document' },
          Other: '$currentObject/Other',
          Label: "'Mapped caption'",
        },
      },
    });
    input.context = { ...record, attributes: { Other: other } };
    input.schema.presentation!['Files.Mapped'] = {
      kind: 'snippet',
      parameters: ['Document', 'Other', 'Label'],
      widgets: [
        { type: 'text', name: 'Label', options: { caption: '{1}', parameters: ['$Label'] } },
        {
          type: 'data_view',
          name: 'other',
          options: {
            source: {
              kind: 'context',
              entity: record.type,
              variable: { kind: 'snippet_parameter', name: 'Files.Mapped.Other' },
            },
          },
          body: [
            {
              type: 'text_box',
              name: 'OtherName',
              options: { caption: 'Other name', attribute: 'Name' },
            },
            {
              type: 'button',
              name: 'Send',
              options: { caption: 'Send' },
              events: [
                {
                  event: 'on_click',
                  kind: 'microflow',
                  handler: 'Files.Send',
                  arguments: {
                    Document: { kind: 'snippet_parameter', name: 'Document' },
                    Label: '$Label',
                  },
                },
              ],
            },
          ],
        },
      ],
    };
    render(<WidgetRenderer {...input} />);
    expect(screen.getByText('Mapped caption')).toBeInTheDocument();
    const field = screen.getByRole('textbox', { name: 'Other name' });
    fireEvent.change(field, { target: { value: 'Edited other' } });
    fireEvent.blur(field);
    await waitFor(() =>
      expect(input.saveRecord).toHaveBeenCalledWith(other, { Name: 'Edited other' }),
    );
    await userEvent.setup().click(screen.getByRole('button', { name: 'Send' }));
    expect(input.invoke).toHaveBeenCalledWith(
      'Files.Send',
      { Document: record, Label: 'Mapped caption' },
      other,
    );
  });

  it('resolves a multi-hop selector owner and retains selections excluded by XPath', async () => {
    const hidden: EntityRecord = {
      id: 'hidden',
      type: 'Files.Tag',
      attributes: { Name: 'Hidden' },
    };
    const visible: EntityRecord = {
      id: 'visible',
      type: 'Files.Tag',
      attributes: { Name: 'Visible' },
    };
    const owner = { ...record, id: 'owner', attributes: { Tags: [hidden] } };
    const input = props({
      type: 'reference_set_selector',
      name: 'Tags',
      options: {
        association: 'Files.Tags',
        target_entity: 'Files.Tag',
        association_steps: 2,
        association_path: [
          { association: 'Files.Owner', entity: record.type },
          { association: 'Files.Tags', entity: 'Files.Tag' },
        ],
        selectable_xpath: "[Name = 'Visible']",
      },
    });
    input.request = vi
      .fn()
      .mockResolvedValueOnce({ records: [owner] })
      .mockResolvedValueOnce({ records: [visible] });
    render(<WidgetRenderer {...input} />);
    await userEvent.setup().click(await screen.findByRole('checkbox', { name: 'Visible' }));
    expect(screen.queryByRole('checkbox', { name: 'Hidden' })).not.toBeInTheDocument();
    expect(input.request).toHaveBeenNthCalledWith(2,
      '/api/entities/Files.Tag?xpath=%5BName+%3D+%27Visible%27%5D&xpath_context_type=Files.Document&xpath_context_id=1');
    await waitFor(() =>
      expect(input.saveRecord).toHaveBeenCalledWith(owner, { Tags: [hidden, visible] }),
    );
    expect(input.request).toHaveBeenNthCalledWith(
      1,
      expect.stringContaining('association=Files.Owner&context_type=Files.Document&context_id=1'),
    );
  });

  it.each(['microflow', 'nanoflow', 'association'])(
    'loads image content from a %s source',
    async (kind) => {
      const imageRecord = { ...record, id: 'image' };
      const input = props({
        type: 'image_viewer',
        name: 'Photo',
        options: {
          source: {
            kind,
            name: 'Files.Image',
            steps: [{ association: 'Files.Photo', entity: record.type }],
          },
          width: 50,
          width_unit: 'percentage',
          height_unit: 'auto',
          show_as_thumbnail: true,
          on_click_enlarge: true,
        },
      });
      input.request = vi
        .fn()
        .mockResolvedValue(
          kind === 'association' ? { records: [imageRecord] } : { result: imageRecord },
        );
      input.invokeNanoflow = vi.fn().mockResolvedValue(imageRecord);
      render(<WidgetRenderer {...input} />);
      const image = await screen.findByRole('img', { name: 'Photo' });
      expect(image).toHaveAttribute('src', expect.stringContaining('/Files.Document/image?'));
      expect(image).toHaveStyle({ width: '50%', objectFit: 'contain' });
      expect(screen.getByRole('link', { name: 'Open image' })).toHaveAttribute(
        'href',
        '/api/files/Files.Document/image',
      );
    },
  );

  it.each([
    'shrink_content_initially_open',
    'shrink_content_initially_closed',
    'push_content_aside',
    'slide_over_content',
  ])('honors sidebar dimensions and %s', async (toggle_mode) => {
    const input = props({
      type: 'scroll_container',
      name: 'Shell',
      options: {
        layout_mode: 'sidebar',
        width_mode: 'percentage',
        width: 80,
        region_options: { left: { size: 240, size_mode: 'pixels', toggle_mode } },
      },
      regions: { left: [{ type: 'text', name: 'Side content' }], center: [] },
    });
    const { container } = render(<WidgetRenderer {...input} />);
    const button = screen.getByRole('button', { name: 'Toggle left' });
    const initiallyOpen = toggle_mode === 'shrink_content_initially_open';
    expect(button).toHaveAttribute('aria-expanded', String(initiallyOpen));
    expect(container.querySelector('[data-widget-name="Shell"]')).toHaveStyle({ width: '80%' });
    await userEvent.setup().click(button);
    expect(button).toHaveAttribute('aria-expanded', String(!initiallyOpen));
    if (!initiallyOpen) expect(screen.getByText('Side content')).toBeVisible();
  });

  it('activates navigation list items with the keyboard', async () => {
    const input = props({
      type: 'navigation_list',
      name: 'Links',
      children: [
        {
          type: 'container',
          name: 'Open',
          children: [{ type: 'text', name: 'Open page' }],
          events: [{ event: 'on_click', kind: 'page', handler: 'Home' }],
        },
      ],
    });
    render(<WidgetRenderer {...input} />);
    const user = userEvent.setup();
    await user.tab();
    expect(screen.getByRole('button')).toHaveFocus();
    await user.keyboard('{Enter}');
    expect(input.navigate).toHaveBeenCalledWith('Files.Home', record);
  });
  it.each(['menu_bar', 'navigation_tree'])(
    'runs nested %s navigation and flow actions',
    async (type) => {
      const input = props({ type, name: 'Navigation', options: { menu: 'Files.Menu' } });
      render(<WidgetRenderer {...input} />);
      const user = userEvent.setup();
      await user.click(screen.getByRole('button', { name: 'Home' }));
      expect(input.navigate).toHaveBeenCalledWith('Files.Home', record);
      await user.click(screen.getByText('More'));
      await user.click(screen.getByRole('button', { name: 'Run' }));
      expect(input.invoke).toHaveBeenCalledWith('Files.Run', {}, record);
    },
  );

  it('renders a reusable snippet with editable fields and rejects recursive references', async () => {
    const input = props({
      type: 'snippet',
      name: 'snippet',
      options: { snippet: 'Files.Snippet' },
    });
    const view = render(<WidgetRenderer {...input} />);
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Snippet name' }), 'Ruby');
    fireEvent.blur(screen.getByRole('textbox'));
    await waitFor(() => expect(input.saveRecord).toHaveBeenCalledWith(record, { Name: 'Ruby' }));
    view.rerender(
      <WidgetRenderer
        {...input}
        widget={{ type: 'snippet', name: 'recursive', options: { snippet: 'Files.Cycle' } }}
      />,
    );
    expect(screen.getByRole('alert')).toHaveTextContent('recursive snippet');
  });

  it('renders static images, named scroll regions and navigation list actions', async () => {
    const input = props({
      type: 'scroll_container',
      name: 'Scroll',
      regions: {
        top: [
          {
            type: 'static_image',
            name: 'Logo',
            options: {
              image: 'Files.Logo',
              alternative_text: 'Logo',
              class: 'custom-logo',
              style: 'opacity: 0.5',
            },
          },
        ],
        center: [
          {
            type: 'navigation_list',
            name: 'Links',
            children: [
              {
                type: 'button',
                name: 'Go',
                options: { caption: 'Go' },
                events: [{ event: 'on_click', kind: 'page', handler: 'Home' }],
              },
            ],
          },
        ],
      },
    });
    render(<WidgetRenderer {...input} />);
    expect(screen.getByRole('img', { name: 'Logo' })).toHaveAttribute('src', '/assets/logo.png');
    expect(screen.getByRole('img', { name: 'Logo' })).toHaveClass('custom-logo');
    expect(screen.getByRole('img', { name: 'Logo' })).toHaveStyle({ opacity: '0.5' });
    expect(screen.getByRole('img').closest('[data-widget-region]')).toHaveAttribute(
      'data-widget-region',
      'top',
    );
    await userEvent.setup().click(screen.getByRole('button', { name: 'Go' }));
    expect(input.navigate).toHaveBeenCalledWith('Files.Home', record);
  });

  it('persists a reference set and propagates inherited read-only restrictions', async () => {
    const target: EntityRecord = { id: '2', type: 'Files.Tag', attributes: { Name: 'Ruby' } };
    const input = props({
      type: 'reference_set_selector',
      name: 'Tags',
      options: {
        association: 'Files.Tags',
        target_entity: 'Files.Tag',
        display_attribute: 'Name',
      },
    });
    vi.mocked(input.request).mockResolvedValue({ records: [target] });
    const view = render(<WidgetRenderer {...input} />);
    await userEvent.setup().click(await screen.findByRole('checkbox', { name: 'Ruby' }));
    await waitFor(() => expect(input.saveRecord).toHaveBeenCalledWith(record, { Tags: [target] }));
    expect(screen.getByRole('checkbox')).toBeChecked();
    view.rerender(
      <ReadOnlyContext.Provider value={true}>
        <WidgetRenderer {...input} />
      </ReadOnlyContext.Provider>,
    );
    expect(await screen.findByRole('checkbox')).toBeDisabled();
  });

  it.each(['file_manager', 'image_uploader'])(
    'uploads %s content through the authenticated JSON client',
    async (type) => {
      const input = props({
        type,
        name: 'Upload',
        options: { allowed_extensions: 'png', max_file_size: 1 },
      });
      const view = render(<WidgetRenderer {...input} />);
      await userEvent
        .setup()
        .upload(
          screen.getByLabelText('Upload', { selector: 'input' }),
          new File(['abc'], 'logo.png', { type: 'image/png' }),
        );
      await waitFor(() =>
        expect(input.request).toHaveBeenCalledWith('/api/files/Files.Document/1', {
          method: 'PUT',
          body: JSON.stringify({ name: 'logo.png', content: 'YWJj' }),
        }),
      );
      expect(input.onMutation).toHaveBeenCalled();
      view.rerender(
        <ReadOnlyContext.Provider value={true}>
          <WidgetRenderer {...input} />
        </ReadOnlyContext.Provider>,
      );
      expect(screen.getByLabelText('Upload', { selector: 'input' })).toBeDisabled();
    },
  );

  it('shows an image fallback and rejects oversize uploads without a request', async () => {
    const input = props({
      type: 'image_viewer',
      name: 'Preview',
      options: { default_image: 'Files.Logo' },
    });
    const view = render(<WidgetRenderer {...input} />);
    fireEvent.error(screen.getByRole('img'));
    expect(screen.getByRole('img')).toHaveAttribute('src', '/assets/logo.png');
    view.rerender(
      <WidgetRenderer
        {...input}
        widget={{ type: 'file_manager', name: 'Large', options: { max_file_size: 0.000001 } }}
      />,
    );
    await userEvent
      .setup()
      .upload(
        screen.getByLabelText('Large'),
        new File(['too large'], 'large.txt', { type: 'text/plain' }),
      );
    expect(input.onError).toHaveBeenCalled();
    expect(input.request).not.toHaveBeenCalled();
  });
});
