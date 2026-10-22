import { useState } from 'react';
import { chartCaption, useCaptionEnvironment } from '../captions';
import type { MarketplaceWidgetProps, MarketplaceWidgetRegion } from '../marketplace';
import { conditionValue } from '../value';
import { marketplaceAction } from './marketplaceData';

type Properties = Record<string, unknown>;

const object = (value: unknown): Properties =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Properties) : {};
const objects = (value: unknown): Properties[] => {
  const list = object(value).objects;
  return Array.isArray(list) ? list.map(object) : [];
};
const regionAt = (regions: MarketplaceWidgetRegion[], path: Array<string | number>) =>
  regions.filter((region) =>
    path.every((part, index) => String(region.path[index]) === String(part)),
  );
const visible = (item: Properties, props: MarketplaceWidgetProps) =>
  item.visible === undefined || item.visible === true || item.visible === 'true'
    ? true
    : conditionValue(String(item.visible), props.context);

// Badge button: caption and value text templates, and its on-click action.
export function MarketplaceBadgeButton(props: MarketplaceWidgetProps) {
  const properties = (props.widget.options?.properties || {}) as Properties;
  const environment = useCaptionEnvironment(props.schema);
  const action = marketplaceAction(properties.onClickEvent);
  return (
    <button
      type="button"
      className="btn widget-badge-button"
      disabled={props.actionRunning}
      onClick={action ? () => props.onAction?.(action, props.context) : undefined}
    >
      <span className="widget-badge-button-text">
        {chartCaption(properties.label, props.context, environment)}
      </span>
      <span className="badge">{chartCaption(properties.value, props.context, environment)}</span>
    </button>
  );
}

// Popup menu: the trigger area opens basic items (caption, divider, action) or,
// in advanced mode, custom item content.
export function MarketplacePopupMenu(props: MarketplaceWidgetProps) {
  const properties = (props.widget.options?.properties || {}) as Properties;
  const environment = useCaptionEnvironment(props.schema);
  const regions = props.regions || [];
  const [open, setOpen] = useState(false);
  // The native popup menu calls advanced mode custom rendering.
  const advanced = properties.advancedMode === true || properties.popupRenderMode === 'custom';
  const items = (advanced ? objects(properties.customItems) : objects(properties.basicItems))
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => visible(item, props));
  const activate = (item: Properties) => {
    setOpen(false);
    const action = marketplaceAction(item.action);
    if (action) return props.onAction?.(action, props.context);
  };
  return (
    <div
      className="popupmenu"
      onMouseLeave={properties.trigger === 'onhover' ? () => setOpen(false) : undefined}
    >
      <div
        className="popupmenu-trigger"
        role="button"
        tabIndex={0}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
        onMouseEnter={properties.trigger === 'onhover' ? () => setOpen(true) : undefined}
        onKeyDown={(event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            setOpen((value) => !value);
          }
        }}
      >
        {[...regionAt(regions, ['menuTrigger']), ...regionAt(regions, ['menuTriggerer'])].map(
          (region) => region.content,
        )}
      </div>
      {open && (
        <ul
          role="menu"
          className={`popupmenu-menu popupmenu-position-${String(properties.position || 'bottom')}`}
        >
          {items.map(({ item, index }) =>
            !advanced && item.itemType === 'divider' ? (
              <li key={index} role="separator" className="popupmenu-basic-divider" />
            ) : (
              <li
                key={index}
                role="menuitem"
                tabIndex={0}
                className={`popupmenu-basic-item popupmenu-basic-item-${String(item.styleClass || 'defaultStyle').replace(/Style$/, '')}`}
                onClick={() => activate(item)}
                onKeyDown={(event) => event.key === 'Enter' && activate(item)}
              >
                {advanced
                  ? regionAt(regions, ['customItems', 'objects', index]).map(
                      (region) => region.content,
                    )
                  : chartCaption(item.caption, props.context, environment)}
              </li>
            ),
          )}
        </ul>
      )}
    </div>
  );
}
