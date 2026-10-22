// The native widgets that render their content once per object of a data
// source: the gallery with its text filter, the repeater and the carousel.
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import type { EntityRecord } from '../../types';
import { chartCaption, useCaptionEnvironment } from '../captions';
import type { MarketplaceWidgetProps, MarketplaceWidgetRegion } from '../marketplace';
import { classes, expressionValue, memberName } from '../value';
import { marketplaceAction, useMarketplaceRecords } from './marketplaceData';

type Properties = Record<string, unknown>;
const object = (value: unknown): Properties =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Properties) : {};
const objects = (value: unknown): Properties[] => {
  const list = object(value).objects;
  return Array.isArray(list) ? list.map(object) : [];
};
const propertiesOf = (props: MarketplaceWidgetProps): Properties =>
  (props.widget.options?.properties || {}) as Properties;
const regionFor = (
  regions: MarketplaceWidgetRegion[],
  path: string,
  record?: EntityRecord,
): ReactNode =>
  regions
    .filter((region) => String(region.path[0]) === path)
    .map((region) => (record && region.render ? region.render(record) : region.content));
const numberOf = (value: unknown, fallback: number) => {
  const number = Number(value);
  return Number.isFinite(number) && value !== '' && value !== null && value !== undefined
    ? number
    : fallback;
};

// The text filter of a gallery writes here; the gallery filters its objects by it.
export interface GalleryFilter {
  value: string;
  operator: string;
  set(value: string, operator: string): void;
}
export const GalleryFilterContext = createContext<GalleryFilter | null>(null);

const normalized = (value: unknown) => String(value ?? '').toLowerCase();

// Whether a value satisfies the filter operator of the gallery text filter.
export function matchesText(value: unknown, filter: string, operator: string): boolean {
  const text = normalized(value);
  const query = filter.toLowerCase();
  const numeric = Number(value);
  const bound = Number(filter);
  switch (operator) {
    case 'startsWith':
      return text.startsWith(query);
    case 'endsWith':
      return text.endsWith(query);
    case 'equal':
      return text === query;
    case 'notEqual':
      return text !== query;
    case 'greater':
      return numeric > bound;
    case 'greaterEqual':
      return numeric >= bound;
    case 'smaller':
      return numeric < bound;
    case 'smallerEqual':
      return numeric <= bound;
    case 'empty':
      return text === '';
    case 'notEmpty':
      return text !== '';
    default:
      return text.includes(query);
  }
}

export function NativeGallery(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const [filter, setFilter] = useState({ value: '', operator: 'contains' });
  const [pages, setPages] = useState(1);
  const [reloads, setReloads] = useState(0);
  const { records, loading, error } = useMarketplaceRecords(properties.datasource, {
    ...props,
    revision: (props.revision || 0) + reloads,
  });
  const attributes = objects(properties.filterList).map((entry) =>
    memberName(String(entry.filter || '')),
  );
  const filtered =
    filter.value || ['empty', 'notEmpty'].includes(filter.operator)
      ? records.filter((record) =>
          attributes.some((attribute) =>
            matchesText(record.attributes[attribute], filter.value, filter.operator),
          ),
        )
      : records;
  const pageSize = numberOf(properties.pageSize, 20);
  const shown = filtered.slice(0, pageSize * pages);
  const columns = numberOf(properties.phoneColumns, 1);
  const horizontal = properties.scrollDirection === 'horizontal';
  const click = marketplaceAction(properties.onClick);
  const pullDown = marketplaceAction(properties.pullDown);
  const loadMore = String(properties.pagination || 'virtualScrolling');
  const context: GalleryFilter = {
    ...filter,
    set: (value, operator) => {
      setPages(1);
      setFilter({ value, operator });
    },
  };
  return (
    <GalleryFilterContext.Provider value={context}>
      <section className="mxrb-native-gallery" aria-label={props.widget.name} aria-busy={loading}>
        {regionFor(regions, 'filtersPlaceholder')}
        {pullDown && (
          <button
            type="button"
            className="mxrb-native-gallery__refresh"
            onClick={() => {
              setReloads((count) => count + 1);
              void props.onAction?.(pullDown, props.context);
            }}
          >
            Refresh
          </button>
        )}
        {error && <p role="alert">{error}</p>}
        {!loading && !filtered.length && (
          <div className="mxrb-native-gallery__empty">{regionFor(regions, 'emptyPlaceholder')}</div>
        )}
        <ul
          className={classes(
            'mxrb-native-gallery__items',
            horizontal && 'mxrb-native-gallery__items--horizontal',
          )}
          style={
            horizontal
              ? undefined
              : { gridTemplateColumns: `repeat(${Math.max(1, columns)}, minmax(0, 1fr))` }
          }
        >
          {shown.map((record) => (
            <li key={record.id} className="mxrb-native-gallery__item" data-record-id={record.id}>
              {click ? (
                <button
                  type="button"
                  className="mxrb-native-gallery__click"
                  onClick={() => props.onAction?.(click, record)}
                >
                  {regionFor(regions, 'content', record)}
                </button>
              ) : (
                regionFor(regions, 'content', record)
              )}
            </li>
          ))}
        </ul>
        {shown.length < filtered.length && (
          <button
            type="button"
            className="mxrb-native-gallery__more"
            onClick={() => setPages((count) => count + 1)}
          >
            {(loadMore === 'buttons' &&
              chartCaption(properties.loadMoreButtonCaption, props.context, environment)) ||
              'Load more'}
          </button>
        )}
      </section>
    </GalleryFilterContext.Provider>
  );
}

export function NativeGalleryTextFilter(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = propertiesOf(props);
  const gallery = useContext(GalleryFilterContext);
  const operator = String(properties.defaultFilter || 'contains');
  const initial =
    typeof properties.defaultValue === 'string' && properties.defaultValue
      ? String(expressionValue(properties.defaultValue, props.context) ?? '')
      : '';
  const [value, setValue] = useState(initial);
  const delay = numberOf(properties.delay, 500);
  useEffect(() => {
    const timer = window.setTimeout(() => {
      gallery?.set(value, operator);
      const attribute = properties.valueAttribute;
      void Promise.resolve(attribute ? props.onChange(String(attribute), value) : undefined).then(
        () => {
          const action = marketplaceAction(properties.onChange);
          if (action) return props.onAction?.(action, props.context);
        },
      );
    }, delay);
    return () => window.clearTimeout(timer);
    // Only the typed value and the operator schedule the filter.
  }, [value, operator]);
  const placeholder = typeof properties.placeholder === 'string' ? properties.placeholder : '';
  return (
    <input
      type="search"
      className="mxrb-native-gallery-filter form-control"
      aria-label={placeholder || props.widget.name}
      placeholder={placeholder || undefined}
      value={value}
      lang={environment.locale}
      onChange={(event) => setValue(event.target.value)}
    />
  );
}

export function NativeRepeater(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const { records, loading, error } = useMarketplaceRecords(properties.datasource, props);
  return (
    <div className="mxrb-native-repeater" aria-busy={loading}>
      {error && <p role="alert">{error}</p>}
      {records.map((record) => (
        <div key={record.id} className="mxrb-native-repeater__item" data-record-id={record.id}>
          {regionFor(regions, 'content', record)}
        </div>
      ))}
    </div>
  );
}

export function NativeCarousel(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const regions = props.regions || [];
  const { records, loading, error } = useMarketplaceRecords(properties.contentSource, props);
  const [index, setIndex] = useState(0);
  const current = Math.min(index, Math.max(records.length - 1, 0));
  return (
    <div
      className={classes(
        'mxrb-native-carousel',
        `mxrb-native-carousel--${String(properties.layout || 'card')}`,
      )}
      role="region"
      aria-roledescription="carousel"
      aria-label={props.widget.name}
      aria-busy={loading}
    >
      {error && <p role="alert">{error}</p>}
      {records.length > 0 && (
        <div className="mxrb-native-carousel__slide" data-record-id={records[current].id}>
          {regionFor(regions, 'content', records[current])}
        </div>
      )}
      {records.length > 1 && (
        <div className="mxrb-native-carousel__controls">
          <button
            type="button"
            aria-label="Previous slide"
            disabled={current === 0}
            onClick={() => setIndex(current - 1)}
          >
            ‹
          </button>
          {properties.showPagination !== false && (
            <ol className="mxrb-native-carousel__pagination">
              {records.map((record, position) => (
                <li key={record.id} aria-current={position === current ? 'true' : undefined}>
                  <button
                    type="button"
                    aria-label={`Slide ${position + 1}`}
                    onClick={() => setIndex(position)}
                  />
                </li>
              ))}
            </ol>
          )}
          <button
            type="button"
            aria-label="Next slide"
            disabled={current >= records.length - 1}
            onClick={() => setIndex(current + 1)}
          >
            ›
          </button>
        </div>
      )}
    </div>
  );
}
