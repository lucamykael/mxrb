import {
  createContext,
  useContext,
  useId,
  useEffect,
  useState,
  type CSSProperties,
  type ReactNode,
} from 'react';
import type { WidgetRuntimeProps } from '../contracts';
import { classes, inlineStyle } from '../value';
import { WidgetRenderer } from './WidgetRenderer';
import { PageLayoutContext } from './PageTitleContext';

const Sidebar = createContext<{ open: boolean; id: string; toggle: () => void } | null>(null);
export const LayoutState = createContext(new Map<string, { open: boolean; focused: boolean }>());

export function SidebarToggle({ widget }: WidgetRuntimeProps) {
  const sidebar = useContext(Sidebar);
  const options = widget.options || {};
  return (
    <button
      type="button"
      data-widget-name={widget.name}
      data-widget-type="sidebar_toggle"
      className={classes(
        'btn mx-button',
        `mx-name-${widget.name}`,
        options.class,
        `btn-${String(options.button_style || 'default')}`,
      )}
      title={typeof options.tooltip === 'string' ? options.tooltip : undefined}
      aria-expanded={sidebar?.open}
      aria-controls={sidebar?.id}
      onClick={(event) => {
        sidebar?.toggle();
        event.currentTarget.focus();
      }}
      style={inlineStyle(options.style)}
    >
      {String(options.caption || 'Menu')}
    </button>
  );
}

// The theme targets these wrappers (including the nested middle region). Keep
// the native structure so theme selectors and responsive rules apply unchanged.
export function NativeScrollContainer(props: WidgetRuntimeProps) {
  const { widget } = props;
  const options = widget.options || {};
  const regions = widget.regions || {};
  const settings = (options.region_options || {}) as Record<
    string,
    { class?: string; style?: string; size?: number; size_mode?: string; toggle_mode?: string }
  >;
  const sidebarRegion =
    ['left', 'right'].find(
      (name) => settings[name]?.toggle_mode && settings[name].toggle_mode !== 'none',
    ) || 'left';
  const mode = settings[sidebarRegion]?.toggle_mode || 'none';
  const layouts = useContext(LayoutState);
  const layoutName = useContext(PageLayoutContext);
  const stateKey = `${layoutName}/${widget.name}/${sidebarRegion}/${mode}`;
  const [open, setOpen] = useState(
    layouts.get(stateKey)?.open ?? mode === 'shrink_content_initially_open',
  );
  useEffect(() => {
    if (layouts.get(stateKey)?.focused)
      document
        .getElementById(id)
        ?.closest('.mx-scrollcontainer-vertical')
        ?.querySelector<HTMLButtonElement>('[data-widget-type="sidebar_toggle"]')
        ?.focus();
  }, []);
  const id = useId();
  const size = (name: string) =>
    settings[name]?.size_mode === 'auto'
      ? 'auto'
      : `${settings[name]?.size || 0}${settings[name]?.size_mode === 'percentage' ? '%' : 'px'}`;
  const render = (name: string): ReactNode =>
    (regions[name] || []).map((child, index) => (
      <WidgetRenderer {...props} key={`${child.name}-${index}`} widget={child} />
    ));
  const region = (name: string, content: ReactNode = render(name), nested = false) => {
    if (name !== 'center' && name !== 'middle' && !regions[name]?.length) return null;
    return (
      <div
        key={name}
        id={name === sidebarRegion ? id : undefined}
        className={classes(
          `mx-scrollcontainer-${name}`,
          settings[name]?.class,
          name === sidebarRegion && mode !== 'none' ? 'mx-scrollcontainer-toggleable' : '',
        )}
        data-widget-region={name}
        style={
          {
            '--sidebar-size': size(name),
            scrollbarWidth: options.hide_scrollbars ? 'none' : undefined,
            ...inlineStyle(settings[name]?.style),
          } as CSSProperties
        }
      >
        <div
          className={classes(
            'mx-scrollcontainer-wrapper',
            nested ? 'mx-scrollcontainer-nested' : '',
          )}
        >
          {name === 'center' ? <div className="mx-placeholder">{content}</div> : content}
        </div>
      </div>
    );
  };
  const toggleClass = mode.startsWith('shrink')
    ? 'mx-scrollcontainer-shrink'
    : mode === 'push_content_aside'
      ? 'mx-scrollcontainer-push'
      : mode === 'slide_over_content'
        ? 'mx-scrollcontainer-slide'
        : '';
  const fixed = options.scroll_behavior === 'per_region' ? 'mx-scrollcontainer-fixed' : '';
  const horizontal = (
    <div
      className={classes(
        'mx-scrollcontainer mx-scrollcontainer-horizontal',
        fixed,
        toggleClass,
        open ? 'mx-scrollcontainer-open' : '',
      )}
      style={{ '--toggleable-sidebar-width': size(sidebarRegion) } as CSSProperties}
    >
      {region('left')}
      {region('center')}
      {region('right')}
    </div>
  );
  const vertical = options.layout_mode !== 'sidebar';
  const content = vertical ? (
    <>
      {region('top')}
      {region('middle', horizontal, true)}
      {region('bottom')}
    </>
  ) : (
    <>
      {region('left')}
      {region(
        'middle',
        <div className={classes('mx-scrollcontainer mx-scrollcontainer-vertical', fixed)}>
          {region('top')}
          {region('center')}
          {region('bottom')}
        </div>,
        true,
      )}
      {region('right')}
    </>
  );
  return (
    <Sidebar.Provider
      value={{
        open,
        id,
        toggle: () => {
          layouts.set(stateKey, { open: !open, focused: true });
          setOpen(!open);
        },
      }}
    >
      <div
        data-widget-name={widget.name}
        data-widget-type="scroll_container"
        className={classes(
          'mx-scrollcontainer',
          vertical ? 'mx-scrollcontainer-vertical' : 'mx-scrollcontainer-horizontal',
          fixed,
          `mx-name-${widget.name}`,
          options.class,
          !vertical ? toggleClass : '',
          !vertical && open ? 'mx-scrollcontainer-open' : '',
        )}
        style={{
          ...(options.width_mode === 'pixels'
            ? { width: Number(options.width), flex: 'none' }
            : {}),
          ...inlineStyle(options.style),
        }}
      >
        {content}
      </div>
    </Sidebar.Provider>
  );
}
