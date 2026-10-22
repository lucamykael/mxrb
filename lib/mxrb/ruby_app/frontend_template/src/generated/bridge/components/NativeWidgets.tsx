// Web adapters for the pluggable widgets of Native Mobile Resources, driven by
// the properties their native packages declare. Data-bound ones live in
// NativeDataWidgets, the signature pad in NativeSignature.
import { useContext, useEffect, useRef, useState, type ComponentType, type ReactNode } from 'react';
import type { ApplicationSchema, EntityRecord, RuntimeValue } from '../../types';
import { chartCaption, useCaptionEnvironment, type CaptionEnvironment } from '../captions';
import type { MarketplaceWidgetProps, MarketplaceWidgetRegion } from '../marketplace';
import { subscribeNotifications, type NativeNotification } from '../nativeMobileActions';
import { qrModules, qrPath } from '../qrCode';
import { enumerationDefinition, attributeDefinition } from '../schemaLookup';
import { classes, conditionValue, expressionValue, memberName } from '../value';
import { ReadOnlyContext, editable } from './FieldPolicy';
import { marketplaceAction, useMarketplaceRecords } from './marketplaceData';
import {
  NativeCarousel,
  NativeGallery,
  NativeGalleryTextFilter,
  NativeRepeater,
} from './NativeDataWidgets';
import { NativeSignature } from './NativeSignature';
import { CollectionIcon } from './PresentationWidgets';
import { WidgetObjectScope } from './VariableScope';

export type Properties = Record<string, unknown>;

export const object = (value: unknown): Properties =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Properties) : {};
export const objects = (value: unknown): Properties[] => {
  const list = object(value).objects;
  return Array.isArray(list) ? list.map(object) : [];
};
export const propertiesOf = (props: MarketplaceWidgetProps): Properties =>
  (props.widget.options?.properties || {}) as Properties;

export const regionAt = (regions: MarketplaceWidgetRegion[], path: Array<string | number>) =>
  regions.filter((region) =>
    path.every((part, index) => String(region.path[index]) === String(part)),
  );

// The widgets of a region, rendered for the context object or for one object
// of the widget's data source.
export const regionContent = (
  regions: MarketplaceWidgetRegion[],
  path: Array<string | number>,
  record?: EntityRecord,
): ReactNode =>
  regionAt(regions, path).map((region) =>
    record && region.render ? region.render(record) : region.content,
  );

export const run = (
  props: MarketplaceWidgetProps,
  value: unknown,
  record: EntityRecord | null = props.context,
) => {
  const action = marketplaceAction(value);
  return action ? props.onAction?.(action, record) : undefined;
};

export const text = (
  value: unknown,
  props: MarketplaceWidgetProps,
  environment: CaptionEnvironment,
) => chartCaption(value, props.context, environment);

const numberOf = (value: unknown, fallback = 0): number => {
  const raw =
    value && typeof value === 'object' && '__mxrb_decimal' in value
      ? (value as { __mxrb_decimal: string }).__mxrb_decimal
      : value;
  const number = Number(raw);
  return Number.isFinite(number) && raw !== '' && raw !== null && raw !== undefined
    ? number
    : fallback;
};

const read = (props: MarketplaceWidgetProps, attribute: unknown): RuntimeValue | undefined =>
  props.context?.attributes[memberName(String(attribute || ''))];

// Whether the widget may change the context object's attributes.
function useWritable(props: MarketplaceWidgetProps): boolean {
  const inheritedReadOnly = useContext(ReadOnlyContext);
  const widgetObjects = useContext(WidgetObjectScope);
  const properties = propertiesOf(props);
  return Boolean(
    !inheritedReadOnly &&
    props.context &&
    properties.editable !== 'never' &&
    editable(props.widget.options || {}, props.context, props.schema?.module_roles, widgetObjects),
  );
}

// An icon property: a glyph code, an icon collection reference or an image name.
export function NativeIcon({ icon, schema }: { icon: unknown; schema?: ApplicationSchema }) {
  if (icon === null || icon === undefined || icon === '') return null;
  const value = object(icon);
  const glyph =
    typeof icon === 'number' ? icon : typeof value.glyph === 'number' ? value.glyph : undefined;
  if (glyph !== undefined)
    return (
      <span aria-hidden="true" className="glyphicon mxrb-native-icon">
        {String.fromCodePoint(glyph)}
      </span>
    );
  const name =
    typeof value.collection === 'string' ? value.collection : typeof icon === 'string' ? icon : '';
  if (!name || !schema) return null;
  const resource = schema.presentation?.[name];
  if (resource?.kind === 'image' && resource.path)
    return <img className="mxrb-native-icon" src={resource.path} alt="" />;
  return <CollectionIcon name={name} schema={schema} />;
}

export function NativeActivityIndicator(props: MarketplaceWidgetProps) {
  return (
    <div role="status" aria-label={props.widget.name} className="mxrb-native-activity-indicator">
      <span className="mxrb-native-spinner" />
    </div>
  );
}

export function NativeBadge(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const caption = text(properties.caption, props, environment);
  const action = marketplaceAction(properties.onClick);
  return action ? (
    <button
      type="button"
      className="mxrb-marketplace-badge badge mxrb-native-badge"
      disabled={props.actionRunning}
      onClick={() => props.onAction?.(action, props.context)}
    >
      {caption}
    </button>
  ) : (
    <output className="mxrb-marketplace-badge badge mxrb-native-badge">{caption}</output>
  );
}

// The CSS keyframes family of a react-native-animatable animation name.
const KEYFRAMES = [
  'fadeIn',
  'fadeOut',
  'zoomIn',
  'zoomOut',
  'slideInUp',
  'slideInDown',
  'slideInLeft',
  'slideInRight',
  'slideOutUp',
  'slideOutDown',
  'slideOutLeft',
  'slideOutRight',
  'bounce',
  'flash',
  'pulse',
  'rotate',
  'rubberBand',
  'shake',
  'swing',
  'tada',
  'wobble',
];
export const keyframeName = (name: string): string => {
  const base = name.replace(/Big$/, '');
  if (KEYFRAMES.includes(base)) return base;
  const movement = base.match(/^(?:bounce|fade|zoom)(In|Out)(Up|Down|Left|Right)$/);
  if (movement) return `slide${movement[1]}${movement[2]}`;
  if (/^(?:bounce|zoom)In/.test(base)) return 'zoomIn';
  if (/^(?:bounce|zoom)Out/.test(base)) return 'zoomOut';
  return base.endsWith('Out') ? 'fadeOut' : 'fadeIn';
};
const EASINGS: Record<string, string> = {
  linear: 'linear',
  ease: 'ease',
  ease_in: 'ease-in',
  ease_out: 'ease-out',
  ease_in_out: 'ease-in-out',
};

export function NativeAnimation(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const type = String(properties.animationType || 'in');
  const name = String(
    type === 'attention'
      ? properties.animationAttention
      : type === 'out'
        ? properties.animationOut
        : properties.animationIn,
  );
  const condition = typeof properties.condition === 'string' ? properties.condition : '';
  const active = !condition || conditionValue(condition, props.context);
  const animation = active && name && name !== 'none' ? keyframeName(name) : '';
  const easing = String(properties.easing || 'ease');
  const duration = numberOf(properties.duration, 200);
  const delay = numberOf(properties.delay, 0);
  const count = numberOf(properties.count, 1);
  const latest = useRef(props);
  latest.current = props;
  // The after-animation action follows the animation's timing, so it runs
  // whether or not the browser plays CSS animations.
  useEffect(() => {
    if (!animation || !count) return;
    const timer = window.setTimeout(
      () => void run(latest.current, propertiesOf(latest.current).afterAnimationAction),
      delay + duration * count,
    );
    return () => window.clearTimeout(timer);
  }, [animation, delay, duration, count]);
  return (
    <div
      className={classes(
        'mxrb-native-animation',
        animation && `mxrb-native-animation--${animation}`,
      )}
      data-animation={animation || undefined}
      style={
        animation
          ? {
              animationDuration: `${duration}ms`,
              animationDelay: `${delay}ms`,
              animationIterationCount: count || 'infinite',
              animationDirection: properties.direction === 'alternate' ? 'alternate' : 'normal',
              animationTimingFunction: EASINGS[easing] ?? 'ease',
              animationFillMode: type === 'out' ? 'forwards' : 'none',
            }
          : undefined
      }
    >
      {regionContent(regions, ['content'])}
    </div>
  );
}

// Events of the application: load and unload of the page, the window coming
// back, the connection changing, and a timer, as the native widget fires them.
export function NativeAppEvents(props: MarketplaceWidgetProps) {
  const latest = useRef(props);
  latest.current = props;
  const properties = propertiesOf(props);
  const settings = JSON.stringify({
    resume: properties.onResumeTimeout,
    online: properties.onOnlineTimeout,
    offline: properties.onOfflineTimeout,
    timer: properties.timerType,
    delay: properties.delayTime,
  });
  useEffect(() => {
    const current = () => propertiesOf(latest.current);
    const fire = (key: string) => void run(latest.current, current()[key]);
    fire('onLoadAction');
    const seconds = (key: string, fallback: number) => numberOf(current()[key], fallback) * 1000;
    let hiddenAt = 0;
    const visibility = () => {
      if (document.visibilityState === 'hidden') hiddenAt = Date.now();
      else if (hiddenAt && Date.now() - hiddenAt >= seconds('onResumeTimeout', 0)) {
        hiddenAt = 0;
        fire('onResumeAction');
      }
    };
    const timers = new Set<number>();
    const connection = (online: boolean) => () => {
      const timer = window.setTimeout(
        () => {
          timers.delete(timer);
          if (navigator.onLine === online) fire(online ? 'onOnlineAction' : 'onOfflineAction');
        },
        seconds(online ? 'onOnlineTimeout' : 'onOfflineTimeout', 5),
      );
      timers.add(timer);
    };
    const online = connection(true);
    const offline = connection(false);
    document.addEventListener('visibilitychange', visibility);
    window.addEventListener('online', online);
    window.addEventListener('offline', offline);
    const delay = seconds('delayTime', 30);
    const timeout = () => fire('onTimeoutAction');
    const timer =
      current().timerType === 'interval'
        ? window.setInterval(timeout, delay)
        : window.setTimeout(timeout, delay);
    return () => {
      document.removeEventListener('visibilitychange', visibility);
      window.removeEventListener('online', online);
      window.removeEventListener('offline', offline);
      timers.forEach((pending) => window.clearTimeout(pending));
      window.clearInterval(timer);
      window.clearTimeout(timer);
      fire('onUnloadAction');
    };
  }, [settings]);
  return <span hidden data-widget-role="app-events" />;
}

export function NativeBackgroundGradient(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const stops = objects(properties.colorList)
    .filter((stop) => typeof stop.color === 'string' && stop.color)
    .map((stop) => `${String(stop.color)} ${numberOf(stop.offset, 0) * 100}%`);
  const action = marketplaceAction(properties.onClick);
  const content = regionContent(regions, ['content']);
  const style = stops.length
    ? { backgroundImage: `linear-gradient(180deg, ${stops.join(', ')})` }
    : undefined;
  return action ? (
    <button
      type="button"
      className="mxrb-native-background-gradient"
      style={style}
      onClick={() => props.onAction?.(action, props.context)}
    >
      {content}
    </button>
  ) : (
    <div className="mxrb-native-background-gradient" style={style}>
      {content}
    </div>
  );
}

// The URL of an image property: a static image of the project, or the file of
// the context object when the property names its entity.
export const imageUrl = (value: unknown, props: MarketplaceWidgetProps): string => {
  const name = String(value || '');
  if (!name) return '';
  const resource = props.schema?.presentation?.[name];
  if (resource?.path) return resource.path;
  return props.context
    ? `/api/files/${encodeURIComponent(props.context.type)}/${encodeURIComponent(props.context.id)}`
    : '';
};

const RESIZE_MODES: Record<string, string> = {
  cover: 'cover',
  contain: 'contain',
  stretch: '100% 100%',
  center: 'auto',
};

export function NativeBackgroundImage(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const url = imageUrl(properties.image, props);
  return (
    <div
      className="mxrb-native-background-image"
      data-image={url || undefined}
      style={{
        backgroundImage: url ? `url(${JSON.stringify(url)})` : undefined,
        backgroundSize: RESIZE_MODES[String(properties.resizeMode || 'cover')],
        backgroundPosition: 'center',
        backgroundRepeat: 'no-repeat',
        opacity: numberOf(properties.opacity, 1),
      }}
    >
      {regionContent(regions, ['content'])}
    </div>
  );
}

// A text template, or an expression as the web image widget declares its URL.
const dynamicText = (
  value: unknown,
  props: MarketplaceWidgetProps,
  environment: CaptionEnvironment,
): string =>
  typeof value === 'string' && (value.startsWith('$') || value.startsWith("'"))
    ? String(expressionValue(value, props.context) ?? '')
    : text(value, props, environment);

export function NativeImage(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const source = String(
    properties.datasource ||
      (properties.imageUrl && !properties.imageObject ? 'imageUrl' : 'image'),
  );
  const alt =
    text(properties.screenReaderCaption, props, environment) ||
    String(properties.alternativeText || props.widget.options?.caption || props.widget.name);
  // Native sizes are points; the web image widget's pixels or percentages apply too.
  const size = (unit: unknown, points: unknown, value: unknown) =>
    unit === 'points'
      ? `${numberOf(points, 100)}px`
      : unit === 'percentage'
        ? `${numberOf(value, 100)}%`
        : unit === 'pixels'
          ? `${numberOf(value, 100)}px`
          : undefined;
  const style = {
    width: size(properties.widthUnit, properties.customWidth, properties.width),
    height: size(properties.heightUnit, properties.customHeight, properties.height),
    opacity: numberOf(properties.opacity, 100) / 100,
    objectFit: ({ cover: 'cover', contain: 'contain', stretch: 'fill', center: 'none' } as const)[
      String(properties.resizeMode || 'contain')
    ],
  };
  const url =
    source === 'imageUrl'
      ? dynamicText(properties.imageUrl, props, environment)
      : source === 'icon'
        ? ''
        : imageUrl(properties.imageObject, props) ||
          imageUrl(properties.defaultImageDynamic, props);
  const safe = /^(?:https?:\/\/|\/[^/]|blob:|data:image\/)/i.test(url);
  const image =
    source === 'icon' ? (
      <span className="mxrb-native-image" style={{ fontSize: numberOf(properties.iconSize, 16) }}>
        <NativeIcon icon={properties.imageIcon} schema={props.schema} />
      </span>
    ) : !safe ? (
      <span role="status">{url ? 'Invalid image URL' : `Missing image: ${alt}`}</span>
    ) : properties.isBackgroundImage === true ? (
      <div
        className="mxrb-native-image mxrb-native-image--background"
        style={{
          ...style,
          backgroundImage: `url(${JSON.stringify(url)})`,
          backgroundSize: 'cover',
        }}
      >
        {regionContent(regions, ['children'])}
      </div>
    ) : (
      <img className="mxrb-native-image" src={url} alt={alt} style={style} />
    );
  if (properties.onClickType === 'enlarge' && safe)
    return (
      <a href={url} target="_blank" rel="noreferrer">
        {image}
      </a>
    );
  const action = marketplaceAction(properties.onClick);
  const click = action ? () => props.onAction?.(action, props.context) : props.onClick;
  return click ? (
    <button type="button" className="mxrb-native-image-button" onClick={() => void click()}>
      {image}
    </button>
  ) : (
    image
  );
}

export function NativeVideoPlayer(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const raw = properties.videoUrl;
  const url = String(
    (typeof raw === 'string' && (raw.startsWith('$') || raw.startsWith("'"))
      ? expressionValue(raw, props.context)
      : raw) || '',
  );
  return (
    <video
      className="mxrb-native-video"
      src={url || undefined}
      controls={properties.showControls !== false}
      autoPlay={properties.autoStart === true}
      muted={properties.muted === true}
      loop={properties.loop === true}
    >
      {props.widget.name}
    </video>
  );
}

// A bottom sheet: a modal with basic items or custom content when the trigger
// attribute of the context object is true, or an expanding panel.
export function NativeBottomSheet(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const attribute = String(properties.triggerAttribute || '');
  const triggered = attribute ? Boolean(read(props, attribute)) : false;
  const [expanded, setExpanded] = useState<'small' | 'large' | 'fullscreen'>('small');
  const wasOpen = useRef(false);
  const latest = useRef(props);
  latest.current = props;
  useEffect(() => {
    if (triggered === wasOpen.current) return;
    wasOpen.current = triggered;
    void run(latest.current, propertiesOf(latest.current)[triggered ? 'onOpen' : 'onClose']);
  }, [triggered]);
  const close = () => {
    if (attribute) void props.onChange(attribute, false);
  };
  if (properties.type === 'expanding') {
    const sizes: Array<'small' | 'large' | 'fullscreen'> = ['small', 'large'];
    if (properties.showFullscreenContent !== false) sizes.push('fullscreen');
    const next = sizes[Math.min(sizes.indexOf(expanded) + 1, sizes.length - 1)];
    const previous = sizes[Math.max(sizes.indexOf(expanded) - 1, 0)];
    return (
      <section
        className={`mxrb-native-bottom-sheet mxrb-native-bottom-sheet--${expanded}`}
        aria-label={props.widget.name}
      >
        <div className="mxrb-native-bottom-sheet__handle">
          <button
            type="button"
            aria-label="Collapse"
            disabled={previous === expanded}
            onClick={() => setExpanded(previous)}
          >
            ▾
          </button>
          <button
            type="button"
            aria-label="Expand"
            disabled={next === expanded}
            onClick={() => setExpanded(next)}
          >
            ▴
          </button>
        </div>
        {regionContent(regions, [`${expanded}Content`])}
      </section>
    );
  }
  if (!triggered) return <span hidden data-widget-role="bottom-sheet" />;
  const basic = properties.modalRendering !== 'custom';
  return (
    <div className="mxrb-native-bottom-sheet-backdrop">
      <button
        type="button"
        className="mxrb-native-bottom-sheet-backdrop__close"
        aria-label="Close"
        onClick={close}
      />
      <div
        role="dialog"
        aria-modal="true"
        aria-label={props.widget.name}
        className="mxrb-native-bottom-sheet mxrb-native-bottom-sheet--modal"
      >
        {basic
          ? objects(properties.itemsBasic).map((item, index) => (
              <button
                key={index}
                type="button"
                className={`mxrb-native-bottom-sheet__item mxrb-native-bottom-sheet__item--${String(item.styleClass || 'defaultStyle').replace(/Style$/, '')}`}
                onClick={() => {
                  close();
                  void run(props, item.action);
                }}
              >
                {String(item.caption ?? '')}
              </button>
            ))
          : regionContent(regions, ['smallContent'])}
      </div>
    </div>
  );
}

export function NativeFloatingActionButton(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const secondary = objects(properties.secondaryButtons);
  const [open, setOpen] = useState(false);
  const main = marketplaceAction(properties.onClick);
  return (
    <div
      className={classes(
        'mxrb-native-fab',
        `mxrb-native-fab--${String(properties.horizontalPosition || 'right')}`,
        `mxrb-native-fab--${String(properties.verticalPosition || 'bottom')}`,
        open && 'is-open',
      )}
    >
      {open &&
        secondary.map((button, index) => (
          <button
            key={index}
            type="button"
            className="mxrb-native-fab__secondary"
            onClick={() => {
              setOpen(false);
              void run(props, button.onClick);
            }}
          >
            <NativeIcon icon={button.icon} schema={props.schema} />
            <span>{text(button.caption, props, environment)}</span>
          </button>
        ))}
      <button
        type="button"
        className="mxrb-native-fab__main"
        aria-label={props.widget.name}
        aria-expanded={secondary.length ? open : undefined}
        disabled={props.actionRunning}
        onClick={() => {
          if (secondary.length) setOpen((value) => !value);
          if (main) void props.onAction?.(main, props.context);
        }}
      >
        <NativeIcon
          icon={open ? (properties.iconActive ?? properties.icon) : properties.icon}
          schema={props.schema}
        />
        {properties.icon === undefined || properties.icon === null ? (open ? '×' : '+') : null}
      </button>
    </div>
  );
}

export function NativeIntroScreen(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const slides = objects(properties.slides);
  const attribute = String(properties.activeSlideAttribute || '');
  const stored = attribute ? numberOf(read(props, attribute), 0) : 0;
  const [index, setIndex] = useState(Math.min(Math.max(stored, 0), Math.max(slides.length - 1, 0)));
  const [done, setDone] = useState(false);
  const pattern = String(properties.buttonPattern || 'all');
  const indicators = String(properties.slideIndicators || 'between');
  const last = index >= slides.length - 1;
  const go = (target: number) => {
    setIndex(target);
    if (attribute) void props.onChange(attribute, target);
    void run(props, properties.onSlideChange);
  };
  const finish = (key: 'onDone' | 'onSkip') => {
    setDone(true);
    void run(props, properties[key]);
  };
  if (done || !slides.length) return <span hidden data-widget-role="intro-screen" />;
  const dots = indicators !== 'never' && !(last && properties.hideIndicatorLastSlide === true) && (
    <ol className="mxrb-native-intro__indicators" aria-label="Slides">
      {slides.map((slide, position) => (
        <li
          key={position}
          aria-current={position === index ? 'step' : undefined}
          className={classes(position === index && 'is-active')}
        >
          {String(slide.name ?? position + 1)}
        </li>
      ))}
    </ol>
  );
  const button = (key: string, fallback: string, onClick: () => void, icon?: unknown) => (
    <button type="button" className="mxrb-native-intro__button" onClick={onClick}>
      <NativeIcon icon={icon} schema={props.schema} />
      {text(properties[key], props, environment) || fallback}
    </button>
  );
  return (
    <section
      className={`mxrb-native-intro mxrb-native-intro--${String(properties.showMode || 'fullscreen')}`}
      aria-label={props.widget.name}
    >
      {indicators === 'above' && dots}
      <div className="mxrb-native-intro__slide" data-slide={String(slides[index].name ?? index)}>
        {regionContent(regions, ['slides', 'objects', index, 'content'])}
      </div>
      {pattern !== 'none' && (
        <div className="mxrb-native-intro__buttons">
          {pattern === 'all' &&
            !last &&
            button('skipCaption', 'Skip', () => finish('onSkip'), properties.skipIcon)}
          {pattern === 'all' &&
            index > 0 &&
            button('previousCaption', 'Previous', () => go(index - 1), properties.previousIcon)}
          {indicators === 'between' && dots}
          {!last && button('nextCaption', 'Next', () => go(index + 1), properties.nextIcon)}
          {last && button('doneCaption', 'Done', () => finish('onDone'), properties.doneIcon)}
        </div>
      )}
    </section>
  );
}

// A list item that reveals buttons or runs an action when swiped: a horizontal
// pointer drag or the arrow keys stand in for the gesture.
export function NativeListViewSwipe(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const [revealed, setRevealed] = useState<'left' | 'right' | null>(null);
  const start = useRef<number | null>(null);
  const swipe = (direction: 'left' | 'right') => {
    const side = direction === 'left' ? 'right' : 'left';
    const mode = String(properties[`${side}RenderMode`] || 'disabled');
    if (mode === 'disabled') return;
    if (mode === 'buttons' || mode === 'toggle') setRevealed(revealed === side ? null : side);
    if (mode !== 'buttons')
      void run(props, properties[direction === 'left' ? 'onSwipeLeft' : 'onSwipeRight']);
  };
  const panel = (side: 'left' | 'right') =>
    revealed === side && (
      <div className={`mxrb-native-swipe__panel mxrb-native-swipe__panel--${side}`}>
        {regionContent(regions, [side])}
      </div>
    );
  return (
    <div
      className={classes('mxrb-native-swipe', revealed && `is-revealed-${revealed}`)}
      role="group"
      aria-label={props.widget.name}
      tabIndex={0}
      onKeyDown={(event) => {
        if (event.key === 'ArrowLeft') swipe('left');
        if (event.key === 'ArrowRight') swipe('right');
      }}
      onPointerDown={(event) => {
        start.current = event.clientX;
      }}
      onPointerUp={(event) => {
        if (start.current === null) return;
        const delta = event.clientX - start.current;
        start.current = null;
        if (Math.abs(delta) >= 40) swipe(delta < 0 ? 'left' : 'right');
      }}
    >
      {panel('left')}
      <div className="mxrb-native-swipe__content">{regionContent(regions, ['content'])}</div>
      {panel('right')}
    </div>
  );
}

// Static and data-driven markers listed with their location, as the browser
// has no map tiles; each marker opens its place on OpenStreetMap or runs its action.
function MarkerList({
  markers,
  props,
}: {
  markers: Array<{
    title: string;
    description: string;
    place: string;
    href: string;
    action?: unknown;
    record?: EntityRecord;
  }>;
  props: MarketplaceWidgetProps;
}) {
  return (
    <ol className="mxrb-native-maps__markers">
      {markers.map((marker, index) => (
        <li key={index} className="mxrb-native-maps__marker">
          {marker.action ? (
            <button
              type="button"
              onClick={() => run(props, marker.action, marker.record ?? props.context)}
            >
              {marker.title || marker.place}
            </button>
          ) : (
            <a href={marker.href} target="_blank" rel="noreferrer">
              {marker.title || marker.place}
            </a>
          )}
          {marker.title && <span className="mxrb-native-maps__place">{marker.place}</span>}
          {marker.description && <p>{marker.description}</p>}
        </li>
      ))}
    </ol>
  );
}

const osm = (place: string, latitude?: number, longitude?: number) =>
  latitude !== undefined && longitude !== undefined
    ? `https://www.openstreetmap.org/?mlat=${latitude}&mlon=${longitude}#map=15/${latitude}/${longitude}`
    : `https://www.openstreetmap.org/search?query=${encodeURIComponent(place)}`;

export function NativeMaps(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const markers = objects(properties.markers).map((marker) => {
    const coordinates = marker.locationType === 'latlng';
    const latitude = coordinates
      ? numberOf(expressionValue(String(marker.latitude || ''), props.context))
      : undefined;
    const longitude = coordinates
      ? numberOf(expressionValue(String(marker.longitude || ''), props.context))
      : undefined;
    const place = coordinates
      ? `${latitude}, ${longitude}`
      : text(marker.address, props, environment);
    return {
      title: text(marker.title, props, environment),
      description: text(marker.description, props, environment),
      place,
      href: osm(place, latitude, longitude),
      action: marker.onClick,
    };
  });
  return (
    <div
      className="mxrb-native-maps"
      role="region"
      aria-label={props.widget.name}
      data-map-type={String(properties.mapType || 'standard')}
    >
      <MarkerList markers={markers} props={props} />
      {objects(properties.dynamicMarkers).map((group, index) => (
        <NativeDynamicMarkers key={index} group={group} props={props} />
      ))}
    </div>
  );
}

function NativeDynamicMarkers({
  group,
  props,
}: {
  group: Properties;
  props: MarketplaceWidgetProps;
}) {
  const { records, error } = useMarketplaceRecords(group.markersDS, props);
  if (error) return <p role="alert">{error}</p>;
  const coordinates = group.locationDynamicType === 'latlng';
  const value = (record: EntityRecord, attribute: unknown) =>
    String(record.attributes[memberName(String(attribute || ''))] ?? '');
  const markers = records.map((record) => {
    const latitude = coordinates
      ? numberOf(record.attributes[memberName(String(group.latitude || ''))])
      : undefined;
    const longitude = coordinates
      ? numberOf(record.attributes[memberName(String(group.longitude || ''))])
      : undefined;
    const place = coordinates ? `${latitude}, ${longitude}` : value(record, group.address);
    return {
      title: value(record, group.title),
      description: value(record, group.description),
      place,
      href: osm(place, latitude, longitude),
      action: group.onClick,
      record,
    };
  });
  return <MarkerList markers={markers} props={props} />;
}

// Receives the notifications the application displays or schedules and runs
// the actions registered under their action name.
export function NativeNotifications(props: MarketplaceWidgetProps) {
  const latest = useRef(props);
  latest.current = props;
  useEffect(
    () =>
      subscribeNotifications((event, notification: NativeNotification) => {
        const current = latest.current;
        const properties = propertiesOf(current);
        const action = objects(properties.actions).find(
          (entry) => entry.name === notification.actionName,
        );
        if (!action) return;
        const writes: Array<[unknown, RuntimeValue]> = [
          [properties.guid, notification.actionGuid ?? ''],
          [properties.title, notification.title ?? ''],
          [properties.subtitle, notification.subtitle ?? ''],
          [properties.body, notification.body],
          [properties.action, notification.actionName ?? ''],
        ];
        void Promise.all(
          writes.map(([attribute, value]) =>
            attribute ? current.onChange(String(attribute), value) : undefined,
          ),
        ).then(() => run(current, action[event === 'open' ? 'onOpen' : 'onReceive']));
      }),
    [],
  );
  return <span hidden data-widget-role="notifications" />;
}

export function NativeQRCode(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const value = text(propertiesOf(props).value, props, environment);
  const modules = value ? qrModules(value) : undefined;
  if (!modules)
    return (
      <figure
        className="mxrb-native-qr mxrb-native-qr--text"
        role="img"
        aria-label={value || 'Empty QR code'}
      >
        <figcaption>{value || 'Empty QR code'}</figcaption>
      </figure>
    );
  const size = modules.length;
  return (
    <figure className="mxrb-native-qr" role="img" aria-label={value}>
      <svg
        viewBox={`-4 -4 ${size + 8} ${size + 8}`}
        shapeRendering="crispEdges"
        data-modules={size}
      >
        <rect x={-4} y={-4} width={size + 8} height={size + 8} fill="#fff" />
        <path d={qrPath(modules)} fill="#000" />
      </svg>
    </figure>
  );
}

export function NativeRadioButtons(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const writable = useWritable(props);
  const attribute = String(properties.enum || '');
  const definition = props.context
    ? attributeDefinition(props.schema, props.context.type, attribute)
    : undefined;
  const values = enumerationDefinition(props.schema, definition?.enumeration || '')?.values || [];
  const current = read(props, attribute);
  const label = text(properties.label, props, environment);
  return (
    <fieldset
      className={`mxrb-native-radio-buttons mxrb-native-radio-buttons--${String(properties.orientation || 'vertical')}`}
      disabled={!writable}
      aria-label={properties.showLabel === true ? undefined : label || props.widget.name}
    >
      {properties.showLabel === true && label && <legend>{label}</legend>}
      {values.map((value) => (
        <label key={value.name}>
          <input
            type="radio"
            name={`${props.widget.name}-${props.context?.id ?? ''}`}
            value={value.name}
            checked={current === value.name}
            onChange={() => {
              void Promise.resolve(props.onChange(attribute, value.name)).then(() =>
                run(props, properties.onChange),
              );
            }}
          />
          {value.caption}
        </label>
      ))}
    </fieldset>
  );
}

export function NativeAccordion(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const groups = objects(properties.groups);
  const single = properties.collapseBehavior !== 'multipleExpanded';
  const collapsible = properties.collapsible !== false;
  const initial = (group: Properties) => {
    const mode = String(group.groupCollapsed || 'groupStartExpanded');
    if (mode === 'groupStartCollapsed') return false;
    if (mode === 'groupStartDynamic')
      return group.groupCollapsedAttribute
        ? !read(props, group.groupCollapsedAttribute)
        : !conditionValue(String(group.groupCollapsedDynamic || 'false'), props.context);
    return true;
  };
  const [open, setOpen] = useState<boolean[]>(() => {
    const states = groups.map(initial);
    if (single && collapsible) {
      const first = states.indexOf(true);
      return states.map((_state, index) => index === first);
    }
    return states;
  });
  const toggle = (index: number) => {
    if (!collapsible) return;
    setOpen((states) =>
      states.map((state, position) => (position === index ? !state : single ? false : state)),
    );
    void run(props, groups[index].groupOnChange);
  };
  return (
    <div className="mxrb-native-accordion mxrb-marketplace-accordion">
      {groups.map((group, index) => {
        const visible =
          group.visible === undefined ||
          group.visible === true ||
          conditionValue(String(group.visible), props.context);
        if (!visible) return null;
        const custom = group.headerRenderMode === 'custom';
        const level =
          Number(String(group.headerTextRenderMode || 'heading5').replace('heading', '')) || 5;
        const Heading = `h${Math.min(6, Math.max(1, level))}` as 'h1';
        return (
          <section
            key={index}
            className={classes('mxrb-native-accordion__group', open[index] && 'is-open')}
          >
            <Heading className="mxrb-native-accordion__header">
              <button
                type="button"
                aria-expanded={open[index] ?? false}
                onClick={() => toggle(index)}
              >
                {custom
                  ? regionContent(regions, ['groups', 'objects', index, 'headerContent'])
                  : text(group.headerText, props, environment)}
              </button>
            </Heading>
            <div className="mxrb-native-accordion__content" hidden={!open[index]}>
              {regionContent(regions, ['groups', 'objects', index, 'content'])}
            </div>
          </section>
        );
      })}
    </div>
  );
}

export function NativeWebView(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const url = text(properties.url, props, environment);
  const content = text(properties.content, props, environment);
  const latest = useRef(props);
  latest.current = props;
  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (typeof event.data !== 'string') return;
      const current = latest.current;
      const input = propertiesOf(current).onMessageInput;
      void Promise.resolve(input ? current.onChange(String(input), event.data) : undefined).then(
        () => run(current, propertiesOf(current).onMessage),
      );
    };
    window.addEventListener('message', receive);
    return () => window.removeEventListener('message', receive);
  }, []);
  if (!url && !content)
    return (
      <p role="status" className="mxrb-native-webview">
        No content
      </p>
    );
  return (
    <iframe
      className="mxrb-native-webview"
      title={props.widget.name}
      src={url || undefined}
      srcDoc={url ? undefined : content}
      sandbox={`allow-scripts allow-forms${url ? ' allow-same-origin' : ''}${properties.openLinksExternally === true ? ' allow-popups' : ''}`}
      onLoad={() => run(props, properties.onLoad)}
      onError={() => run(props, properties.onError)}
    />
  );
}

// The feedback form of the native widget, kept in the browser: the labels and
// messages of the widget drive a dialog that confirms the sent feedback.
export function NativeFeedback(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const [state, setState] = useState<'closed' | 'open' | 'sent'>('closed');
  const [message, setMessage] = useState('');
  const label = (key: string, fallback: string) =>
    text(properties[key], props, environment) || fallback;
  if (state === 'closed')
    return (
      <button
        type="button"
        className="mxrb-native-feedback__button"
        aria-label={label('accessibilityLabelFeedbackButton', 'Open feedback form')}
        onClick={() => setState('open')}
      >
        {label('titleSendFeedback', 'Send feedback')}
      </button>
    );
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={label(state === 'sent' ? 'titleResult' : 'titleSendFeedback', 'Feedback')}
      className="mxrb-native-feedback"
    >
      {state === 'sent' ? (
        <>
          <p>{label('messageSuccess', 'Feedback successfully sent')}</p>
          <button type="button" onClick={() => setState('closed')}>
            {label('buttonOk', 'OK')}
          </button>
        </>
      ) : (
        <form
          onSubmit={(event) => {
            event.preventDefault();
            setMessage('');
            setState('sent');
          }}
        >
          <label>
            {label('labelFeedbackInput', 'Type your feedback here')}
            <textarea
              value={message}
              required
              onChange={(event) => setMessage(event.target.value)}
            />
          </label>
          {properties.allowScreenshot !== false && (
            <label>
              <input type="checkbox" /> {label('labelIncludeScreenshot', 'Include screenshot')}
            </label>
          )}
          <button type="button" onClick={() => setState('closed')}>
            {label('buttonCancel', 'Cancel')}
          </button>
          <button type="submit">{label('buttonSend', 'Send')}</button>
        </form>
      )}
    </div>
  );
}

// The adapter of a Native Mobile Resources widget by the lowercased id.
const adapters: Record<string, ComponentType<MarketplaceWidgetProps>> = {
  accordion: NativeAccordion,
  activityindicator: NativeActivityIndicator,
  animation: NativeAnimation,
  appevents: NativeAppEvents,
  backgroundgradient: NativeBackgroundGradient,
  backgroundimage: NativeBackgroundImage,
  badge: NativeBadge,
  bottomsheet: NativeBottomSheet,
  carousel: NativeCarousel,
  feedback: NativeFeedback,
  floatingactionbutton: NativeFloatingActionButton,
  gallery: NativeGallery,
  gallerytextfilter: NativeGalleryTextFilter,
  image: NativeImage,
  introscreen: NativeIntroScreen,
  listviewswipe: NativeListViewSwipe,
  maps: NativeMaps,
  notifications: NativeNotifications,
  qrcode: NativeQRCode,
  radiobuttons: NativeRadioButtons,
  repeater: NativeRepeater,
  signature: NativeSignature,
  videoplayer: NativeVideoPlayer,
  webview: NativeWebView,
};

export const nativeWidgetAdapter = (
  id: string,
): ComponentType<MarketplaceWidgetProps> | undefined => {
  const match = id.toLowerCase().match(/^com\.mendix\.widget\.native\.([a-z0-9]+)\./);
  return match ? adapters[match[1]] : undefined;
};
