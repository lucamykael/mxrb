import { act, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  MarketplaceWidget,
  type MarketplaceWidgetProps,
  type MarketplaceWidgetRegion,
} from '../marketplace';
import { nativeMobileActions } from '../nativeMobileActions';
import { keyframeName, nativeWidgetAdapter } from './NativeWidgets';
import type { ApiRequest, ApplicationSchema } from '../../types';

const action = (handler: string) => ({ action: { kind: 'nanoflow', handler, arguments: {} } });
const region = (path: Array<string | number>, label: string): MarketplaceWidgetRegion => ({
  path,
  role: String(path[path.length - 1]),
  content: <span>{label}</span>,
  render: (record) => (
    <span key={record.id}>{`${label} of ${String(record.attributes.Name)}`}</span>
  ),
});
const schema = {
  modules: [
    {
      name: 'App',
      models: [
        {
          name: 'App.Car',
          attributes: [
            { name: 'Make', type: 'enum', enumeration: 'App.Make' },
            { name: 'Open', type: 'boolean' },
          ],
        },
      ],
      enumerations: [
        {
          id: 'App.Make',
          name: 'App.Make',
          values: [
            { name: 'Audi', caption: 'Audi' },
            { name: 'BMW', caption: 'BMW' },
          ],
        },
      ],
      pages: [],
    },
  ],
  presentation: {
    'App.Images.Logo': { kind: 'image', path: '/assets/logo.png' },
  },
} as unknown as ApplicationSchema;

const widget = (
  kind: string,
  properties: Record<string, unknown> = {},
  extra: Partial<MarketplaceWidgetProps> = {},
): MarketplaceWidgetProps => ({
  widget: {
    type: 'pluggable_widget',
    name: kind,
    options: { widget_id: `com.mendix.widget.native.${kind.toLowerCase()}.${kind}`, properties },
  },
  context: {
    id: '1',
    type: 'App.Car',
    attributes: { Name: 'Car', Make: 'Audi', Open: false, Animate: true },
  },
  schema,
  onChange: vi.fn(async () => null),
  onAction: vi.fn(async () => undefined),
  ...extra,
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('Native Mobile Resources widget adapters', () => {
  it('selects adapters only for the native package ids', () => {
    expect(nativeWidgetAdapter('com.mendix.widget.native.bottomsheet.BottomSheet')).toBeDefined();
    expect(nativeWidgetAdapter('com.mendix.widget.web.badge.Badge')).toBeUndefined();
    expect(nativeWidgetAdapter('com.mendix.widget.native.unknown.Unknown')).toBeUndefined();
  });

  it('renders a badge, an activity indicator and a video from their properties', () => {
    const badge = widget('Badge', {
      caption: { text: '{1}', parameters: ['$currentObject/Name'] },
      onClick: action('App.Open'),
    });
    render(<MarketplaceWidget {...badge} />);
    fireEvent.click(screen.getByRole('button', { name: 'Car' }));
    expect(badge.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Open' }),
      badge.context,
    );
    render(<MarketplaceWidget {...widget('Badge', { caption: 'New' })} />);
    expect(screen.getByText('New').tagName).toBe('OUTPUT');
    render(<MarketplaceWidget {...widget('ActivityIndicator')} />);
    expect(screen.getByRole('status', { name: 'ActivityIndicator' })).toBeInTheDocument();
    const { container } = render(
      <MarketplaceWidget
        {...widget('VideoPlayer', {
          videoUrl: "'https://example.test/clip.mp4'",
          showControls: false,
          loop: true,
        })}
      />,
    );
    const video = container.querySelector('video')!;
    expect(video).toHaveAttribute('src', 'https://example.test/clip.mp4');
    expect(video).not.toHaveAttribute('controls');
    expect(video).toHaveAttribute('loop');
  });

  it('animates while its condition holds and runs the action when the animation ends', () => {
    vi.useFakeTimers();
    const input = widget(
      'Animation',
      {
        animationType: 'in',
        animationIn: 'bounceInDown',
        duration: 1000,
        delay: 10,
        condition: '$currentObject/Animate',
        easing: 'ease_in_out',
        count: 2,
        direction: 'alternate',
        afterAnimationAction: action('App.Done'),
      },
      { regions: [region(['content'], 'Animated')] },
    );
    const { container, rerender } = render(<MarketplaceWidget {...input} />);
    const element = container.querySelector('[data-animation]')!;
    expect(element).toHaveClass('mxrb-native-animation--slideInDown');
    expect(element).toHaveStyle({
      animationDuration: '1000ms',
      animationTimingFunction: 'ease-in-out',
      animationDirection: 'alternate',
    });
    expect(screen.getByText('Animated')).toBeInTheDocument();
    expect(input.onAction).not.toHaveBeenCalled();
    act(() => vi.advanceTimersByTime(2010));
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Done' }),
      input.context,
    );
    input.context!.attributes.Animate = false;
    rerender(<MarketplaceWidget {...input} />);
    expect(container.querySelector('[data-animation]')).toBeNull();
    expect(
      [
        'fadeInUpBig',
        'fadeOutDownBig',
        'bounceIn',
        'zoomOutRight',
        'bounceOutLeft',
        'pulse',
        'mystery',
        'mysteryOut',
      ].map(keyframeName),
    ).toEqual([
      'slideInUp',
      'slideOutDown',
      'zoomIn',
      'slideOutRight',
      'slideOutLeft',
      'pulse',
      'fadeIn',
      'fadeOut',
    ]);
  });

  it('paints gradients and background images behind their content', () => {
    const gradient = widget(
      'BackgroundGradient',
      {
        colorList: {
          objects: [
            { color: 'rgb(255, 0, 0)', offset: 0 },
            { color: 'rgb(0, 0, 255)', offset: 1 },
          ],
        },
        onClick: action('App.Tap'),
      },
      { regions: [region(['content'], 'Inside')] },
    );
    render(<MarketplaceWidget {...gradient} />);
    const button = screen.getByRole('button', { name: 'Inside' });
    expect(button).toHaveStyle({
      backgroundImage: 'linear-gradient(180deg, rgb(255, 0, 0) 0%, rgb(0, 0, 255) 100%)',
    });
    fireEvent.click(button);
    expect(gradient.onAction).toHaveBeenCalled();
    const { container } = render(
      <MarketplaceWidget
        {...widget(
          'BackgroundImage',
          { image: 'App.Images.Logo', resizeMode: 'contain', opacity: 0.5 },
          { regions: [region(['content'], 'Over')] },
        )}
      />,
    );
    const image = container.querySelector('.mxrb-native-background-image')!;
    expect(image).toHaveAttribute('data-image', '/assets/logo.png');
    expect(image).toHaveStyle({ backgroundSize: 'contain', opacity: '0.5' });
    expect(screen.getByText('Over')).toBeInTheDocument();
    const dynamic = render(
      <MarketplaceWidget {...widget('BackgroundImage', { image: 'App.Car' })} />,
    );
    expect(dynamic.container.querySelector('.mxrb-native-background-image')).toHaveAttribute(
      'data-image',
      '/api/files/App.Car/1',
    );
  });

  it('shows images from static resources, URLs, the context file or an icon', () => {
    render(
      <MarketplaceWidget
        {...widget('Image', {
          datasource: 'image',
          imageObject: 'App.Images.Logo',
          screenReaderCaption: 'Logo',
          widthUnit: 'points',
          customWidth: 40,
        })}
      />,
    );
    expect(screen.getByRole('img', { name: 'Logo' })).toHaveStyle({ width: '40px' });
    render(
      <MarketplaceWidget
        {...widget('Image', {
          datasource: 'image',
          imageObject: 'App.Car',
          onClickType: 'enlarge',
        })}
      />,
    );
    expect(screen.getByRole('link')).toHaveAttribute('href', '/api/files/App.Car/1');
    render(
      <MarketplaceWidget
        {...widget(
          'Image',
          {
            datasource: 'imageUrl',
            imageUrl: { text: 'https://example.test/{1}.png', parameters: ['$currentObject/Name'] },
            isBackgroundImage: true,
          },
          { regions: [region(['children'], 'Child')] },
        )}
      />,
    );
    expect(screen.getByText('Child').closest('.mxrb-native-image--background')).toHaveStyle({
      backgroundImage: 'url("https://example.test/Car.png")',
    });
    const { container } = render(
      <MarketplaceWidget
        {...widget('Image', { datasource: 'icon', imageIcon: 57344, iconSize: 20 })}
      />,
    );
    expect(container.querySelector('.glyphicon')).toHaveTextContent(String.fromCodePoint(57344));
    render(
      <MarketplaceWidget
        {...widget(
          'Image',
          { datasource: 'image', imageObject: 'App.Images.Missing' },
          { context: null },
        )}
      />,
    );
    expect(screen.getByRole('status')).toHaveTextContent('Missing image: Image');
  });

  it('opens a basic bottom sheet from its trigger attribute and closes it with an item', async () => {
    const input = widget('BottomSheet', {
      type: 'modal',
      triggerAttribute: 'App.Car.Open',
      modalRendering: 'basic',
      itemsBasic: {
        objects: [{ caption: 'Delete', action: action('App.Delete'), styleClass: 'dangerStyle' }],
      },
      onOpen: action('App.Opened'),
      onClose: action('App.Closed'),
    });
    const { rerender } = render(<MarketplaceWidget {...input} />);
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    input.context = { ...input.context!, attributes: { ...input.context!.attributes, Open: true } };
    rerender(<MarketplaceWidget {...input} />);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Opened' }),
      input.context,
    );
    const item = within(screen.getByRole('dialog')).getByRole('button', { name: 'Delete' });
    expect(item).toHaveClass('mxrb-native-bottom-sheet__item--danger');
    fireEvent.click(item);
    expect(input.onChange).toHaveBeenCalledWith('App.Car.Open', false);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Delete' }),
      input.context,
    );
    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    expect(input.onChange).toHaveBeenCalledTimes(2);
    input.context = { ...input.context, attributes: { ...input.context.attributes, Open: false } };
    rerender(<MarketplaceWidget {...input} />);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Closed' }),
      input.context,
    );
  });

  it('renders custom bottom sheet content and expands the expanding sheet through its sizes', () => {
    const custom = widget(
      'BottomSheet',
      { type: 'modal', triggerAttribute: 'App.Car.Open', modalRendering: 'custom' },
      {
        regions: [region(['smallContent'], 'Custom body')],
      },
    );
    custom.context!.attributes.Open = true;
    render(<MarketplaceWidget {...custom} />);
    expect(within(screen.getByRole('dialog')).getByText('Custom body')).toBeInTheDocument();
    render(
      <MarketplaceWidget
        {...widget(
          'BottomSheet',
          { type: 'expanding', showFullscreenContent: true },
          {
            regions: [
              region(['smallContent'], 'Small'),
              region(['largeContent'], 'Large'),
              region(['fullscreenContent'], 'Full'),
            ],
          },
        )}
      />,
    );
    expect(screen.getByText('Small')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Expand' }));
    expect(screen.getByText('Large')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Expand' }));
    expect(screen.getByText('Full')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Expand' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Collapse' }));
    expect(screen.getByText('Large')).toBeInTheDocument();
  });

  it('runs the floating action button and unfolds its secondary buttons', () => {
    const simple = widget('FloatingActionButton', {
      onClick: action('App.Add'),
      horizontalPosition: 'left',
      verticalPosition: 'top',
    });
    const { container, unmount } = render(<MarketplaceWidget {...simple} />);
    expect(container.querySelector('.mxrb-native-fab')).toHaveClass(
      'mxrb-native-fab--left',
      'mxrb-native-fab--top',
    );
    fireEvent.click(screen.getByRole('button', { name: 'FloatingActionButton' }));
    expect(simple.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Add' }),
      simple.context,
    );
    unmount();
    const menu = widget('FloatingActionButton', {
      icon: { collection: 'App.Images.Logo' },
      secondaryButtons: { objects: [{ caption: 'Email', onClick: action('App.Email') }] },
    });
    render(<MarketplaceWidget {...menu} />);
    const main = screen.getByRole('button', { name: 'FloatingActionButton' });
    expect(main).toHaveAttribute('aria-expanded', 'false');
    expect(main.querySelector('img')).toHaveAttribute('src', '/assets/logo.png');
    fireEvent.click(main);
    fireEvent.click(screen.getByRole('button', { name: 'Email' }));
    expect(menu.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Email' }),
      menu.context,
    );
    expect(screen.queryByRole('button', { name: 'Email' })).not.toBeInTheDocument();
  });

  it('walks the intro screen slides and reports the active slide and the end', () => {
    const input = widget(
      'IntroScreen',
      {
        slides: { objects: [{ name: 'First' }, { name: 'Second' }] },
        buttonPattern: 'all',
        slideIndicators: 'between',
        hideIndicatorLastSlide: true,
        skipCaption: 'Skip',
        previousCaption: 'Back',
        nextCaption: 'Next',
        doneCaption: 'Finish',
        activeSlideAttribute: 'App.Car.Slide',
        onSlideChange: action('App.Changed'),
        onDone: action('App.Done'),
        onSkip: action('App.Skipped'),
      },
      {
        regions: [
          region(['slides', 'objects', 0, 'content'], 'Slide one'),
          region(['slides', 'objects', 1, 'content'], 'Slide two'),
        ],
      },
    );
    const { container } = render(<MarketplaceWidget {...input} />);
    expect(screen.getByText('Slide one')).toBeInTheDocument();
    expect(screen.getByRole('list', { name: 'Slides' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(screen.getByText('Slide two')).toBeInTheDocument();
    expect(input.onChange).toHaveBeenCalledWith('App.Car.Slide', 1);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Changed' }),
      input.context,
    );
    expect(screen.queryByRole('list', { name: 'Slides' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Back' }));
    expect(screen.getByText('Slide one')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Skip' }));
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Skipped' }),
      input.context,
    );
    expect(container.querySelector('[data-widget-role="intro-screen"]')).toBeInTheDocument();
    const done = widget('IntroScreen', {
      slides: { objects: [{ name: 'Only' }] },
      buttonPattern: 'nextDone',
      onDone: action('App.Done'),
    });
    render(<MarketplaceWidget {...done} />);
    fireEvent.click(screen.getByRole('button', { name: 'Done' }));
    expect(done.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Done' }),
      done.context,
    );
  });

  it('reveals swipe buttons or runs the swipe action of a list item', () => {
    const input = widget(
      'ListViewSwipe',
      {
        leftRenderMode: 'buttons',
        rightRenderMode: 'archive',
        onSwipeLeft: action('App.Archive'),
        onSwipeRight: action('App.Favorite'),
      },
      {
        regions: [
          region(['content'], 'Row'),
          region(['left'], 'Left buttons'),
          region(['right'], 'Right panel'),
        ],
      },
    );
    render(<MarketplaceWidget {...input} />);
    const item = screen.getByRole('group', { name: 'ListViewSwipe' });
    fireEvent.keyDown(item, { key: 'ArrowRight' });
    expect(screen.getByText('Left buttons')).toBeInTheDocument();
    expect(input.onAction).not.toHaveBeenCalled();
    fireEvent.pointerDown(item, { clientX: 200 });
    fireEvent.pointerUp(item, { clientX: 100 });
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Archive' }),
      input.context,
    );
    expect(screen.queryByText('Right panel')).not.toBeInTheDocument();
    fireEvent.pointerDown(item, { clientX: 100 });
    fireEvent.pointerUp(item, { clientX: 110 });
    expect(input.onAction).toHaveBeenCalledTimes(1);
  });

  it('lists map markers with their place, action or OpenStreetMap link', async () => {
    const request = vi.fn(async () => ({
      records: [
        { id: 'p1', type: 'App.Place', attributes: { Name: 'Office', Address: 'Main street 1' } },
      ],
    })) as unknown as ApiRequest;
    const input = widget(
      'Maps',
      {
        markers: {
          objects: [
            {
              locationType: 'address',
              address: 'Melbourne',
              title: 'Branch',
              description: 'South',
            },
            {
              locationType: 'latlng',
              latitude: '-35.2',
              longitude: '149.1',
              onClick: action('App.Pin'),
            },
          ],
        },
        dynamicMarkers: {
          objects: [
            {
              markersDS: { data_source: { entity: 'App.Place', xpath: '', sort: [] } },
              locationDynamicType: 'address',
              address: 'App.Place.Address',
              title: 'App.Place.Name',
              onClick: action('App.Visit'),
            },
          ],
        },
      },
      { request },
    );
    render(<MarketplaceWidget {...input} />);
    expect(screen.getByRole('link', { name: 'Branch' })).toHaveAttribute(
      'href',
      'https://www.openstreetmap.org/search?query=Melbourne',
    );
    expect(screen.getByText('South')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '-35.2, 149.1' }));
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Pin' }),
      input.context,
    );
    const office = await screen.findByRole('button', { name: 'Office' });
    fireEvent.click(office);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Visit' }),
      expect.objectContaining({ id: 'p1' }),
    );
    expect(screen.getByText('Main street 1')).toBeInTheDocument();
  });

  it('draws the QR code of its value', () => {
    const { container } = render(
      <MarketplaceWidget
        {...widget('QRCode', { value: { text: '{1}', parameters: ['$currentObject/Name'] } })}
      />,
    );
    expect(screen.getByRole('img', { name: 'Car' })).toBeInTheDocument();
    expect(container.querySelector('svg')).toHaveAttribute('data-modules', '21');
    render(<MarketplaceWidget {...widget('QRCode', { value: '' })} />);
    expect(screen.getByRole('img', { name: 'Empty QR code' })).toBeInTheDocument();
  });

  it('offers the enumeration values as radio buttons and saves the choice', async () => {
    const input = widget('RadioButtons', {
      enum: 'App.Car.Make',
      orientation: 'horizontal',
      showLabel: true,
      label: 'Make',
      onChange: action('App.Changed'),
    });
    render(<MarketplaceWidget {...input} />);
    const group = screen.getByRole('group', { name: 'Make' });
    expect(group).toHaveClass('mxrb-native-radio-buttons--horizontal');
    expect(screen.getByRole('radio', { name: 'Audi' })).toBeChecked();
    fireEvent.click(screen.getByRole('radio', { name: 'BMW' }));
    expect(input.onChange).toHaveBeenCalledWith('App.Car.Make', 'BMW');
    await act(async () => undefined);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Changed' }),
      input.context,
    );
    render(
      <MarketplaceWidget
        {...widget('RadioButtons', { enum: 'App.Car.Make', editable: 'never', label: 'Locked' })}
      />,
    );
    expect(screen.getByRole('group', { name: 'Locked' })).toBeDisabled();
  });

  it('expands one accordion group at a time with text or custom headers', () => {
    const input = widget(
      'Accordion',
      {
        collapsible: true,
        collapseBehavior: 'singleExpanded',
        groups: {
          objects: [
            {
              headerRenderMode: 'text',
              headerText: 'Details',
              headerTextRenderMode: 'heading2',
              groupCollapsed: 'groupStartExpanded',
              groupOnChange: action('App.Toggled'),
            },
            {
              headerRenderMode: 'custom',
              groupCollapsed: 'groupStartDynamic',
              groupCollapsedAttribute: 'App.Car.Open',
            },
            { headerRenderMode: 'text', headerText: 'Hidden', visible: 'false' },
          ],
        },
      },
      {
        regions: [
          region(['groups', 'objects', 0, 'content'], 'First body'),
          region(['groups', 'objects', 1, 'headerContent'], 'Custom header'),
          region(['groups', 'objects', 1, 'content'], 'Second body'),
        ],
      },
    );
    render(<MarketplaceWidget {...input} />);
    expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Details');
    expect(screen.queryByText('Hidden')).not.toBeInTheDocument();
    expect(screen.getByText('First body')).toBeVisible();
    expect(screen.getByText('Second body')).not.toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Custom header' }));
    expect(screen.getByText('Second body')).toBeVisible();
    expect(screen.getByText('First body')).not.toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Toggled' }),
      input.context,
    );
  });

  it('embeds a web view and passes its messages to the page', async () => {
    const input = widget('WebView', {
      url: 'https://example.test/page',
      onLoad: action('App.Loaded'),
      onMessage: action('App.Message'),
      onMessageInput: 'App.Car.Name',
      openLinksExternally: true,
    });
    render(<MarketplaceWidget {...input} />);
    const frame = screen.getByTitle('WebView');
    expect(frame).toHaveAttribute('src', 'https://example.test/page');
    expect(frame).toHaveAttribute(
      'sandbox',
      'allow-scripts allow-forms allow-same-origin allow-popups',
    );
    fireEvent.load(frame);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Loaded' }),
      input.context,
    );
    await act(async () => {
      window.dispatchEvent(new MessageEvent('message', { data: 'ping' }));
    });
    expect(input.onChange).toHaveBeenCalledWith('App.Car.Name', 'ping');
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Message' }),
      input.context,
    );
    render(<MarketplaceWidget {...widget('WebView', { content: '<p>Inline</p>' })} />);
    expect(screen.getAllByTitle('WebView')[1]).toHaveAttribute('srcdoc', '<p>Inline</p>');
    render(<MarketplaceWidget {...widget('WebView', {})} />);
    expect(screen.getByRole('status')).toHaveTextContent('No content');
  });

  it('collects feedback in a browser dialog with the widget texts', () => {
    render(
      <MarketplaceWidget
        {...widget('Feedback', {
          titleSendFeedback: 'Tell us',
          buttonSend: 'Go',
          messageSuccess: 'Thanks',
          buttonOk: 'Fine',
          accessibilityLabelFeedbackButton: 'Open feedback',
        })}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: 'Open feedback' }));
    const dialog = screen.getByRole('dialog', { name: 'Tell us' });
    fireEvent.change(within(dialog).getByRole('textbox'), { target: { value: 'Great app' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Go' }));
    expect(screen.getByText('Thanks')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Fine' }));
    expect(screen.getByRole('button', { name: 'Open feedback' })).toBeInTheDocument();
  });

  it('fires the app events for load, unload, timer, resume and connection changes', () => {
    vi.useFakeTimers();
    const input = widget('AppEvents', {
      onLoadAction: action('App.Load'),
      onUnloadAction: action('App.Unload'),
      onResumeAction: action('App.Resume'),
      onResumeTimeout: 0,
      onOnlineAction: action('App.Online'),
      onOnlineTimeout: 1,
      onOfflineAction: action('App.Offline'),
      onOfflineTimeout: 1,
      timerType: 'interval',
      delayTime: 2,
      onTimeoutAction: action('App.Tick'),
    });
    const handlers = () =>
      (input.onAction as ReturnType<typeof vi.fn>).mock.calls.map(
        ([event]) => (event as { handler: string }).handler,
      );
    const { unmount } = render(<MarketplaceWidget {...input} />);
    expect(handlers()).toEqual(['App.Load']);
    vi.advanceTimersByTime(4000);
    expect(handlers().filter((name) => name === 'App.Tick')).toHaveLength(2);
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
    expect(handlers()).toContain('App.Resume');
    Object.defineProperty(navigator, 'onLine', { value: false, configurable: true });
    window.dispatchEvent(new Event('offline'));
    vi.advanceTimersByTime(1000);
    expect(handlers()).toContain('App.Offline');
    Object.defineProperty(navigator, 'onLine', { value: true, configurable: true });
    window.dispatchEvent(new Event('online'));
    vi.advanceTimersByTime(1000);
    expect(handlers()).toContain('App.Online');
    unmount();
    expect(handlers().at(-1)).toBe('App.Unload');
  });

  it('receives the notifications the application displays and runs the matching action', async () => {
    const input = widget('Notifications', {
      actions: {
        objects: [
          { name: 'ShowAlert', onReceive: action('App.Received'), onOpen: action('App.Opened') },
        ],
      },
      guid: 'App.Car.Guid',
      title: 'App.Car.Title',
      body: 'App.Car.Body',
    });
    render(<MarketplaceWidget {...input} />);
    const display = nativeMobileActions(['DisplayNotification'])[
      'NativeMobileResources.DisplayNotification'
    ];
    await act(async () => {
      await display({
        body: 'Service due',
        title: 'Garage',
        actionName: 'ShowAlert',
        actionGuid: '42',
      });
      await display({ body: 'Other', actionName: 'Unknown' });
    });
    expect(input.onChange).toHaveBeenCalledWith('App.Car.Guid', '42');
    expect(input.onChange).toHaveBeenCalledWith('App.Car.Title', 'Garage');
    expect(input.onChange).toHaveBeenCalledWith('App.Car.Body', 'Service due');
    expect(input.onAction).toHaveBeenCalledTimes(1);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Received' }),
      input.context,
    );
  });

  it('draws a signature and saves it into the image object', async () => {
    const strokes: string[] = [];
    const surface = {
      clearRect: vi.fn(),
      beginPath: vi.fn(),
      moveTo: vi.fn((x: number, y: number) => strokes.push(`M${x},${y}`)),
      lineTo: vi.fn((x: number, y: number) => strokes.push(`L${x},${y}`)),
      stroke: vi.fn(),
    };
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(
      surface as unknown as CanvasRenderingContext2D,
    );
    vi.spyOn(HTMLCanvasElement.prototype, 'toDataURL').mockReturnValue(
      'data:image/png;base64,QUJD',
    );
    const request = vi.fn(async () => ({})) as unknown as ApiRequest;
    const input = widget(
      'Signature',
      {
        imageSource: 'App.Car',
        buttonCaptionClear: 'Wipe',
        buttonCaptionSave: 'Keep',
        onClear: action('App.Cleared'),
        onSignEndAction: action('App.Signed'),
        onEmpty: action('App.Empty'),
      },
      { request },
    );
    render(<MarketplaceWidget {...input} />);
    fireEvent.click(screen.getByRole('button', { name: 'Keep' }));
    await act(async () => undefined);
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Empty' }),
      input.context,
    );
    const pad = screen.getByRole('img', { name: 'Signature' });
    fireEvent.pointerDown(pad, { clientX: 10, clientY: 10, pointerId: 1 });
    fireEvent.pointerMove(pad, { clientX: 20, clientY: 15, pointerId: 1 });
    fireEvent.pointerUp(pad, { pointerId: 1 });
    expect(strokes.length).toBe(2);
    fireEvent.click(screen.getByRole('button', { name: 'Keep' }));
    await act(async () => undefined);
    expect(request).toHaveBeenCalledWith('/api/files/App.Car/1', {
      method: 'PUT',
      body: JSON.stringify({ name: 'signature.png', content: 'QUJD' }),
    });
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Signed' }),
      input.context,
    );
    fireEvent.click(screen.getByRole('button', { name: 'Wipe' }));
    expect(surface.clearRect).toHaveBeenCalled();
    expect(input.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Cleared' }),
      input.context,
    );
  });

  it('renders the native popup menu and pie chart through the shared adapters', async () => {
    const menu = widget(
      'PopupMenu',
      {
        popupRenderMode: 'basic',
        basicItems: {
          objects: [
            {
              itemType: 'item',
              caption: 'Open',
              action: action('App.Open'),
              styleClass: 'primaryStyle',
            },
            { itemType: 'divider' },
          ],
        },
      },
      { regions: [region(['menuTriggerer'], 'More')] },
    );
    render(<MarketplaceWidget {...menu} />);
    fireEvent.click(screen.getByRole('button', { name: 'More' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Open' }));
    expect(menu.onAction).toHaveBeenCalledWith(
      expect.objectContaining({ handler: 'App.Open' }),
      menu.context,
    );
    const request = vi.fn(async () => ({
      records: [
        { id: 'a', type: 'App.Slice', attributes: { Label: 'Audi', Value: 3 } },
        { id: 'b', type: 'App.Slice', attributes: { Label: 'BMW', Value: 1 } },
      ],
    })) as unknown as ApiRequest;
    const chart = widget(
      'PieDoughnutChart',
      {
        presentation: 'doughnut',
        series: {
          objects: [
            {
              dataSource: { data_source: { entity: 'App.Slice', xpath: '', sort: [] } },
              XAttribute: 'App.Slice.Label',
              YAttribute: 'App.Slice.Value',
            },
          ],
        },
      },
      { request },
    );
    const { container } = render(<MarketplaceWidget {...chart} />);
    await screen.findByRole('img', { name: 'PieDoughnutChart' });
    await act(async () => undefined);
    expect(container.querySelectorAll('path').length).toBeGreaterThanOrEqual(2);
  });
});
