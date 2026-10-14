import { useContext, useEffect, useState } from 'react';
import type {
  DataViewSource,
  EntityCollectionResponse,
  EntityRecord,
  WidgetEvent,
} from '../../types';
import type { MarketplaceWidgetProps } from '../marketplace';
import { PageParameters } from '../PageVariables';
import { useListSource } from '../listSource';
import { sortRecords, withXPath } from '../value';

type Properties = Record<string, unknown>;

const object = (value: unknown): Properties =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Properties) : {};

export interface MarketplaceDataSource {
  entity: string;
  xpath: string;
  sort: Array<{ attribute: string; direction: string }>;
  // A microflow, nanoflow or association source instead of an XPath query.
  source?: DataViewSource;
}

// A pluggable widget data source property, either nested as the Ruby pages
// declare it, { data_source: { entity, xpath, sort, source? } }, or flat as the
// page projection writes it, { data_source?: entity, xpath, sort, source? }.
export function marketplaceDataSource(value: unknown): MarketplaceDataSource | undefined {
  const raw = object(value);
  const source =
    typeof raw.data_source === 'string' || raw.data_source === undefined
      ? { ...raw, entity: raw.data_source }
      : object(raw.data_source);
  const entity = String(source.entity || '');
  const list = object(source.source);
  if (!entity && !list.kind) return undefined;
  const sort = Array.isArray(source.sort)
    ? source.sort.map((item) => ({
        attribute: String(object(item).attribute || ''),
        direction: String(object(item).direction || ''),
      }))
    : [];
  return {
    entity,
    xpath: String(source.xpath || ''),
    sort,
    ...(list.kind ? { source: list as unknown as DataViewSource } : {}),
  };
}

export interface MarketplaceRecords {
  records: EntityRecord[];
  loading: boolean;
  error?: string;
}

// Loads the objects of a widget data source with its XPath constraint, the context
// object and the page parameters it refers to, ordered as the data source sorts.
export function useMarketplaceRecords(
  value: unknown,
  props: Pick<MarketplaceWidgetProps, 'context' | 'request' | 'revision'>,
): MarketplaceRecords {
  const parameters = useContext(PageParameters);
  const source = marketplaceDataSource(value);
  const listed = useListSource(
    source?.source,
    props.context,
    props.context,
    props.request,
    props.revision,
  );
  const path =
    source && !source.source
      ? withXPath(
          `/api/entities/${encodeURIComponent(source.entity)}`,
          source.xpath || undefined,
          props.context,
          parameters,
        )
      : '';
  const sortKey = JSON.stringify(source?.sort || []);
  const [state, setState] = useState<MarketplaceRecords & { key: string }>({
    key: '',
    records: [],
    loading: true,
  });
  const key = `${path}:${sortKey}:${props.revision || 0}`;
  useEffect(() => {
    let active = true;
    if (!path || !props.request) {
      setState({ key, records: [], loading: false, error: 'Widget data source is unavailable' });
      return;
    }
    props
      .request<EntityCollectionResponse>(path)
      .then((response) => {
        if (active)
          setState({
            key,
            records: sortRecords(response.records || [], JSON.parse(sortKey)),
            loading: false,
          });
      })
      .catch((failure: unknown) => {
        if (active) setState({ key, records: [], loading: false, error: String(failure) });
      });
    return () => {
      active = false;
    };
  }, [key, path, sortKey, props.request]);
  if (source?.source)
    return listed.loading
      ? listed
      : { ...listed, records: sortRecords(listed.records, source.sort) };
  return state.key === key ? state : { records: [], loading: true };
}

// An action property projected as { action: { kind, handler, arguments } }.
export function marketplaceAction(value: unknown): WidgetEvent | undefined {
  if (value === null || value === undefined) return undefined;
  const action = object(object(value).action ?? value);
  if (typeof action.kind !== 'string' || typeof action.handler !== 'string' || !action.handler)
    return undefined;
  return { ...action, event: 'click' } as WidgetEvent;
}
