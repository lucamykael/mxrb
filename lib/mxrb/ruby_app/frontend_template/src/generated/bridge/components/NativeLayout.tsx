import { useContext } from 'react';
import type { WidgetRuntimeProps } from '../contracts';
import type {
  AnyWidgetDefinition,
  ApplicationSchema,
  NativeBottomBarItem,
  NavigationProfile,
  WidgetDefinition,
} from '../../types';
import { classes, inlineStyle } from '../value';
import { WidgetRenderer } from './WidgetRenderer';
import { PageNameContext, PageTitleContext } from './PageTitleContext';

// The navigation profile of the native app, whose bottom bar the phone shell shows.
export const nativeProfile = (schema: ApplicationSchema): NavigationProfile | undefined =>
  schema.navigation?.profiles?.find((profile) => profile.kind === 'Native');

const itemCaption = (item: NativeBottomBarItem, schema: ApplicationSchema): string => {
  const captions = item.caption || {};
  const locale = String(
    schema.languages?.default || document.documentElement.lang || 'en_US',
  ).replace('-', '_');
  return captions[locale] || Object.values(captions)[0] || item.page || '';
};

interface BottomBarProps {
  items: NativeBottomBarItem[];
  current: string;
  schema: ApplicationSchema;
  navigate: WidgetRuntimeProps['navigate'];
}

// The bottom bar of the native profile: one tab per item, the open page marked.
export function NativeBottomBar({ items, current, schema, navigate }: BottomBarProps) {
  return (
    <nav className="mxrb-native-bottom-bar" aria-label="Bottom bar">
      {items.map((item, index) => {
        const active = Boolean(item.page) && item.page === current;
        return (
          <button
            key={`${item.page || index}`}
            type="button"
            className={classes('mxrb-native-bottom-bar__item', active && 'is-active')}
            aria-current={active ? 'page' : undefined}
            disabled={!item.page}
            onClick={() => (item.page ? navigate(item.page) : undefined)}
          >
            {typeof item.icon === 'number' ? (
              <span aria-hidden="true" className="glyphicon mxrb-native-bottom-bar__icon">
                {String.fromCodePoint(item.icon)}
              </span>
            ) : null}
            <span className="mxrb-native-bottom-bar__caption">{itemCaption(item, schema)}</span>
          </button>
        );
      })}
    </nav>
  );
}

// A native layout as the phone shows it: a header with the page title and the
// layout's header widgets, the content, an optional sidebar and the bottom
// bar of the native profile when the layout shows it.
export function NativeLayout(props: WidgetRuntimeProps) {
  const { widget, schema, navigate } = props;
  const options = widget.options || {};
  const regions = widget.regions || {};
  const title = useContext(PageTitleContext);
  const pageName = useContext(PageNameContext);
  const profile = nativeProfile(schema);
  const items = options.show_bottom_bar ? profile?.bottom_bar || [] : [];
  const render = (widgets: WidgetDefinition[] | undefined, region: string) =>
    (widgets || []).map((child, index) => (
      <WidgetRenderer key={`${region}-${child.name}-${index}`} {...props} widget={child} />
    ));
  return (
    <div
      data-widget-name={widget.name}
      data-widget-type="native_layout"
      data-layout-type={String(options.layout_type || 'default')}
      className={classes(
        'mxrb-native-layout',
        `mxrb-native-layout--${String(options.layout_type || 'default')}`,
        options.class,
        options.design_class as string | undefined,
      )}
      style={inlineStyle(options.style)}
    >
      <header className="mxrb-native-header">
        <h1 className="mxrb-native-header__title">{title}</h1>
        <div className="mxrb-native-header__actions">{render(regions.header, 'header')}</div>
      </header>
      {options.sidebar ? (
        <aside className="mxrb-native-sidebar">{render(regions.sidebar, 'sidebar')}</aside>
      ) : null}
      <div className="mxrb-native-content">{render(regions.content, 'content')}</div>
      {items.length ? (
        <NativeBottomBar items={items} current={pageName} schema={schema} navigate={navigate} />
      ) : null}
    </div>
  );
}

// Whether a page renders inside a native layout, and so in the phone shell.
export const nativePage = (widgets: AnyWidgetDefinition[] | undefined): boolean =>
  (widgets || []).some(
    (widget) =>
      widget.type === 'native_layout' ||
      nativePage(widget.children) ||
      Object.values(widget.regions || {}).some((region) => nativePage(region)),
  );
