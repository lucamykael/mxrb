import { decimal, isDecimal } from './decimal';
import { useState } from 'react';
import { MarketplaceControl, MarketplaceImage } from './components/MarketplaceControls';
import { MarketplaceChart } from './components/MarketplaceChart';
import { MarketplacePlotly } from './components/MarketplacePlotly';
import { LanguageSelector } from './components/LanguageSelector';
import marketplaceWidgets from './marketplaceWidgets.json';
import { MarketplaceTimeline } from './components/MarketplaceTimeline';
import {
  MarketplaceCsvTable,
  MarketplaceHtmlSnippet,
  MarketplaceIFrame,
  MarketplaceMicroflowTimer,
} from './components/MarketplaceLegacy';
import { MarketplaceTreeNode } from './components/MarketplaceTreeNode';
import { MarketplaceBadgeButton, MarketplacePopupMenu } from './components/MarketplaceMenus';
import type { ComponentType, ReactNode } from 'react';
import type {
  ApiRequest,
  ApplicationSchema,
  EntityRecord,
  RuntimeValue,
  WidgetDefinition,
  WidgetEvent,
} from '../types';

export interface MarketplaceWidgetRegion {
  path: Array<string | number>;
  role: string;
  content: ReactNode;
  // The region's widgets rendered for one object of the widget's data source.
  render?(record: EntityRecord): ReactNode;
}

export interface MarketplaceWidgetProps {
  widget: WidgetDefinition;
  context: EntityRecord | null;
  children?: ReactNode;
  schema?: ApplicationSchema;
  request?: ApiRequest;
  revision?: number;
  onClick?(): unknown;
  onAction?(event: WidgetEvent, context: EntityRecord | null): Promise<unknown>;
  actionRunning?: boolean;
  regions?: MarketplaceWidgetRegion[];
  onChange(attribute: string | undefined, value: RuntimeValue): unknown;
}

const widgetAdapters = new Map<string, ComponentType<MarketplaceWidgetProps>>();

// Exact widget identities let application-owned implementations override a
// built-in projection without changing generated bridge sources.
export function registerMarketplaceWidget(
  id: string,
  component: ComponentType<MarketplaceWidgetProps>,
): () => void {
  if (!id.trim()) throw new Error('A qualified widget identity is required');
  const previous = widgetAdapters.get(id);
  widgetAdapters.set(id, component);
  return () => {
    if (widgetAdapters.get(id) !== component) return;
    if (previous) widgetAdapters.set(id, previous);
    else widgetAdapters.delete(id);
  };
}

export function MarketplaceWidget(props: MarketplaceWidgetProps) {
  const Adapter = widgetAdapters.get(String(props.widget.options?.widget_id || ''));
  return Adapter ? <Adapter {...props} /> : <BuiltinMarketplaceWidget {...props} />;
}

type Properties = Record<string, unknown>;

const asProperties = (value: unknown): Properties =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Properties) : {};

const firstText = (properties: Properties, keys: string[], fallback: string): string => {
  for (const key of keys) {
    const value = properties[key];
    if (typeof value === 'string' && value.trim()) return value;
    if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  }
  return fallback;
};

const findAttribute = (value: unknown): string | undefined => {
  if (!value || typeof value !== 'object') return undefined;
  if (Array.isArray(value)) {
    for (const child of value) {
      const found = findAttribute(child);
      if (found) return found;
    }
    return undefined;
  }
  for (const [key, child] of Object.entries(value as Properties)) {
    if (/attribute/i.test(key) && typeof child === 'string' && child.includes('.')) return child;
    const found = findAttribute(child);
    if (found) return found;
  }
  return undefined;
};

const memberName = (value: string | undefined): string => (value || '').split(/[./]/).pop() || '';

const normalizedRole = (role: string): string => role.replace(/[^a-z0-9]/gi, '').toLowerCase();

const regionsByRole = (
  regions: MarketplaceWidgetRegion[],
  role: string,
): MarketplaceWidgetRegion[] =>
  regions.filter((region) => normalizedRole(region.role) === normalizedRole(role));

const regionsByPath = (
  regions: MarketplaceWidgetRegion[],
  path: Array<string | number>,
): MarketplaceWidgetRegion[] =>
  regions.filter((region) =>
    path.every((part, index) => String(region.path[index]) === String(part)),
  );

const regionContent = (
  regions: MarketplaceWidgetRegion[],
  role: string,
  fallback?: ReactNode,
): ReactNode => {
  const matches = regionsByRole(regions, role);
  return matches.length ? matches.map((region) => region.content) : fallback;
};

const renderRegions = (regions: MarketplaceWidgetRegion[], fallback?: ReactNode): ReactNode =>
  regions.length
    ? regions.map((region, index) => (
        <div
          key={`${region.path.map(String).join('.')}-${region.role}-${index}`}
          className="mxrb-marketplace-region"
          data-region-role={region.role}
          data-region-path={region.path.map(String).join('.')}
        >
          {region.content}
        </div>
      ))
    : fallback;

const groupIndex = (region: MarketplaceWidgetRegion): string | undefined => {
  const groupPath = region.path.map(String);
  const groups = groupPath.findIndex(
    (part, index) => part === 'groups' && groupPath[index + 1] === 'objects',
  );
  return groups >= 0 ? groupPath[groups + 2] : undefined;
};

const accordion = (
  label: string,
  regions: MarketplaceWidgetRegion[],
  fallback?: ReactNode,
): ReactNode => {
  const indices = [
    ...new Set(regions.map(groupIndex).filter((index): index is string => Boolean(index))),
  ];
  if (!indices.length)
    return (
      <details>
        <summary>{label}</summary>
        {renderRegions(regions, fallback)}
      </details>
    );

  const ungrouped = regions.filter((region) => groupIndex(region) === undefined);
  return (
    <div className="mxrb-marketplace-accordion">
      {indices.map((index) => {
        const group = regionsByPath(regions, ['groups', 'objects', index]);
        return (
          <details key={index}>
            <summary>{regionContent(group, 'headerContent', label)}</summary>
            {regionContent(group, 'content')}
          </details>
        );
      })}
      {renderRegions(ungrouped)}
    </div>
  );
};

function BuiltinMarketplaceWidget(props: MarketplaceWidgetProps) {
  const { widget, context, children, regions = [], onChange } = props;
  const options = widget.options || {};
  const properties = asProperties(options.properties);
  const id = String(options.widget_id || options.native_type || widget.name).toLowerCase();
  const name = String(options.widget_name || widget.name);
  const attribute = findAttribute(properties);
  const current = context?.attributes?.[memberName(attribute)];
  const [localValue, setLocalValue] = useState<RuntimeValue>(current ?? 0);
  const update = (value: RuntimeValue) => {
    if (typeof value === 'number' && isDecimal(current)) value = decimal(value);
    setLocalValue(value);
    return onChange(attribute, value);
  };
  const label = firstText(
    properties,
    ['label', 'value', 'caption', 'title', 'legend', 'textMessage', 'alternativeText'],
    name,
  );
  const content = renderRegions(regions, children);

  if (id.endsWith('.image')) return <MarketplaceImage {...props} />;
  if (id.includes('customchart'))
    return <MarketplacePlotly {...props}>{content}</MarketplacePlotly>;
  if (/(progressbar|progresscircle|rangeslider|slider|rating|colorpicker|togglebuttons)\./.test(id))
    return <MarketplaceControl {...props} />;

  if (
    /(area|bar|bubble|column|custom|heatmap|line|pie|time)chart/.test(id) ||
    id.includes('timeseries') ||
    id.includes('heatmap')
  )
    return <MarketplaceChart {...props}>{content}</MarketplaceChart>;
  if (id.includes('switch')) {
    return (
      <label>
        <input
          type="checkbox"
          checked={Boolean(current ?? localValue)}
          onChange={(event) => update(event.target.checked)}
        />
        {label}
      </label>
    );
  }
  if (id.includes('badgebutton')) return <MarketplaceBadgeButton {...props} />;
  if (id.includes('badge')) return <output className="mxrb-marketplace-badge">{label}</output>;
  if (id.includes('accordion')) return accordion(label, regions, children);
  if (id.includes('fieldset'))
    return (
      <fieldset>
        <legend>{label}</legend>
        {regionContent(regions, 'content', children)}
      </fieldset>
    );
  if (id.includes('accessibilityhelper'))
    return <div aria-live="polite">{regionContent(regions, 'content', children)}</div>;
  if (id.includes('htmlelement')) return <article>{content || label}</article>;
  if (id.includes('languageselector'))
    return (
      <LanguageSelector
        properties={properties}
        schema={props.schema}
        request={props.request}
        label={name}
      />
    );
  if (id.includes('popupmenu')) return <MarketplacePopupMenu {...props} />;
  if (id.includes('timeline')) return <MarketplaceTimeline {...props} />;
  if (id.includes('tooltip'))
    return (
      <span className="mxrb-marketplace-tooltip">
        {regionContent(regions, 'trigger', children || label)}
        <span role="tooltip">{regionContent(regions, 'htmlMessage')}</span>
      </span>
    );
  if (id.includes('carousel'))
    return (
      <div className="mxrb-marketplace-carousel">{regionContent(regions, 'content', children)}</div>
    );
  if (id.includes('safearea'))
    return (
      <div className="mxrb-marketplace-safe-area">
        {regionContent(regions, 'content', children)}
      </div>
    );
  if (id.includes('treenode') || id.includes('treeview')) return <MarketplaceTreeNode {...props} />;
  if (id.includes('videoplayer')) {
    const source = firstText(properties, ['videoUrl', 'videoURL', 'url'], '');
    return (
      <video controls src={source || undefined}>
        {label}
      </video>
    );
  }
  if (id.startsWith('htmlsnippet.widget.htmlsnippet')) return <MarketplaceHtmlSnippet {...props} />;
  if (id === 'microflowtimer.widget.microflowtimer')
    return <MarketplaceMicroflowTimer {...props} />;
  if (id.endsWith('csvastable')) return <MarketplaceCsvTable {...props} />;
  if (id.endsWith('iframecomponent')) return <MarketplaceIFrame {...props} />;
  if (id.includes('barcodescanner')) return <button type="button">{label}</button>;

  return (
    <section
      className="mxrb-marketplace-generic"
      role="alert"
      aria-label={name}
      data-mxrb-unsupported={String(options.widget_id || options.native_type || widget.name)}
    >
      <strong>{name}</strong>
      <small>Unsupported widget {String(options.widget_id || options.native_type || '')}</small>
      {content}
    </section>
  );
}

// Every family the renderer above handles, shared with the Ruby portability report.
export const recognizedMarketplaceWidget = (widgetId: string) =>
  marketplaceWidgets.widgets.find((entry) =>
    new RegExp(entry.pattern).test(widgetId.toLowerCase()),
  );
