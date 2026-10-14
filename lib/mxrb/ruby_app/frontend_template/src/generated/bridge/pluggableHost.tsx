import Big from 'big.js';
import { useContext, useEffect, useRef, useState, type ComponentType } from 'react';
import type { EntityCollectionResponse, EntityRecord, RuntimeValue, WidgetEvent } from '../types';
import {
  captionDate,
  chartCaption,
  useCaptionEnvironment,
  type CaptionEnvironment,
} from './captions';
import { decimal, isDecimal } from './decimal';
import {
  ListSourceNanoflows,
  loadListSource,
  sourceMappings,
  sourceStart,
  useSourceScopes,
} from './listSource';
import {
  registerMarketplaceWidget,
  type MarketplaceWidgetProps,
  type MarketplaceWidgetRegion,
} from './marketplace';
import { matchesFilter, type FilterCondition, type FilterValue } from './mendixFilters';
import { LocalVariables, PageParameters } from './PageVariables';
import { attributeDefinition } from './schemaLookup';
import { marketplaceAction, marketplaceDataSource } from './components/marketplaceData';
import { VariableScope, WidgetObjectScope } from './components/VariableScope';
import { displayValue, expressionValue, memberName, sortRecords, withXPath } from './value';

// A property of a project widget, as its package declares it.
export interface WidgetPropertyDefinition {
  key: string;
  type: string;
  list?: boolean;
  data_source?: string;
  default?: string;
  properties?: WidgetPropertyDefinition[];
}

type Properties = Record<string, unknown>;
type ObjectItem = { id: string };
type ListState = {
  offset: number;
  limit?: number;
  sortOrder: Array<[string, 'asc' | 'desc']>;
  filter?: FilterCondition;
};
type Loaded = { records: EntityRecord[]; loading: boolean };

const object = (value: unknown): Properties =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Properties) : {};

// Attribute and expression values as the pluggable widget API types them:
// numbers as Big, date and time as Date, empty as undefined.
export function apiValue(value: RuntimeValue | undefined, type = ''): unknown {
  if (value === null || value === undefined || value === '') return undefined;
  if (isDecimal(value)) return new Big(value.__mxrb_decimal);
  if (typeof value === 'number') return new Big(value);
  if (['datetime', 'date'].includes(type.toLowerCase()) && typeof value === 'string')
    return new Date(value);
  return value;
}

// A value a widget sets, back in the runtime's representation.
export function runtimeValue(value: unknown, type = ''): RuntimeValue {
  if (value === undefined || value === null) return null;
  if (value instanceof Big)
    return type.toLowerCase() === 'decimal' ? decimal(value.toString()) : Number(value.toString());
  if (value instanceof Date) return value.toISOString();
  return value as RuntimeValue;
}

const text = (value: unknown): string =>
  value instanceof Date ? value.toISOString() : value === undefined ? '' : String(value);

// Dates show in the user's locale, as the Mendix client formats them.
function shownValue(raw: RuntimeValue | undefined, type: string, locale: string): string {
  if (typeof raw === 'string' && raw && ['datetime', 'date'].includes(type.toLowerCase()))
    return captionDate(raw, { date_format: 'Date' }, locale);
  return String(displayValue(raw));
}

function editableValue(
  record: EntityRecord | null,
  attribute: string,
  type: string,
  locale: string,
  set: ((value: RuntimeValue) => unknown) | null,
) {
  const raw = record?.attributes[memberName(attribute)];
  return {
    status: record ? 'available' : 'unavailable',
    readOnly: !set,
    value: apiValue(raw, type),
    displayValue: shownValue(raw, type, locale),
    validation: undefined,
    setValidator: () => undefined,
    setValue: (value: unknown) => set?.(runtimeValue(value, type)),
    setTextValue: (value: string) => set?.(value),
    formatter: {
      format: text,
      parse: (value: string) => ({ valid: true, value }),
    },
    setFormatter: () => undefined,
  };
}

const dynamic = (value: unknown) => ({ status: 'available', value });

function actionValue(
  property: unknown,
  record: EntityRecord | null,
  props: MarketplaceWidgetProps,
): { canExecute: boolean; isExecuting: boolean; execute: () => void } | undefined {
  const action = marketplaceAction(property);
  if (!action) return undefined;
  return {
    canExecute: !props.actionRunning,
    isExecuting: Boolean(props.actionRunning),
    execute: () => void props.onAction?.(action as WidgetEvent, record),
  };
}

// Builds the props a widget build receives from the projected property values.
function widgetProps(
  definitions: WidgetPropertyDefinition[],
  values: Properties,
  context: EntityRecord | null,
  host: HostContext,
): Properties {
  return Object.fromEntries(
    definitions.map((definition) => [
      definition.key,
      propertyValue(definition, values[definition.key], context, host),
    ]),
  );
}

interface HostContext {
  props: MarketplaceWidgetProps;
  variables: Record<string, RuntimeValue>;
  environment: CaptionEnvironment;
  records: (key: string) => EntityRecord | undefined;
  lists: Record<string, unknown>;
  region: (key: string) => MarketplaceWidgetRegion | undefined;
}

function propertyValue(
  definition: WidgetPropertyDefinition,
  value: unknown,
  context: EntityRecord | null,
  host: HostContext,
): unknown {
  const { props, variables, environment } = host;
  const expression = typeof value === 'string' ? value : definition.default;
  const linked = definition.data_source;
  const forItem =
    <T,>(read: (record: EntityRecord) => T) =>
    (item: ObjectItem) => {
      const record = host.records(item.id);
      return record ? read(record) : undefined;
    };
  switch (definition.type) {
    case 'DataSource':
      return host.lists[definition.key];
    case 'Attribute': {
      const attribute = String(value || '');
      if (!attribute) return undefined;
      const type = (record: EntityRecord | null) =>
        attributeDefinition(props.schema, record?.type || '', attribute)?.type || '';
      if (linked)
        return {
          id: `${definition.key}:${attribute}`,
          sortable: true,
          filterable: true,
          get: forItem((record) =>
            editableValue(record, attribute, type(record), environment.locale, null),
          ),
        };
      return editableValue(context, attribute, type(context), environment.locale, (next) =>
        props.onChange(attribute, next),
      );
    }
    case 'Expression': {
      if (!expression) return undefined;
      const evaluate = (record: EntityRecord | null) =>
        dynamic(apiValue(expressionValue(expression, record, variables)));
      return linked ? { get: forItem(evaluate) } : evaluate(context);
    }
    case 'TextTemplate': {
      const template = value ?? definition.default ?? '';
      const caption = (record: EntityRecord | null) =>
        dynamic(chartCaption(template, record, environment));
      return linked ? { get: forItem(caption) } : caption(context);
    }
    case 'Action':
      return linked
        ? { get: forItem((record) => actionValue(value, record, props)) }
        : actionValue(value, context, props);
    case 'Widgets': {
      const region = host.region(definition.key);
      if (linked) return { get: forItem((record) => region?.render?.(record) ?? null) };
      return region?.content ?? null;
    }
    case 'Object': {
      const objects = Array.isArray(object(value).objects)
        ? (object(value).objects as Properties[])
        : [];
      const nested = (item: Properties) =>
        widgetProps(definition.properties || [], object(item), context, host);
      return definition.list ? objects.map(nested) : objects[0] && nested(objects[0]);
    }
    case 'Decimal':
      return value === undefined || value === null || value === ''
        ? undefined
        : new Big(String(value));
    case 'Icon':
    case 'Image': {
      const uri = typeof value === 'string' ? value : String(object(value).uri || '');
      if (!uri) return undefined;
      return dynamic(
        definition.type === 'Image'
          ? { uri }
          : uri.includes('/')
            ? { type: 'image', iconUrl: uri }
            : { type: 'glyph', iconClass: uri },
      );
    }
    case 'String':
    case 'Boolean':
    case 'Integer':
    case 'Enumeration':
      return value ?? definition.default;
    default:
      // Selections, associations and files are not projected yet.
      return undefined;
  }
}

// The objects of each data source property, loaded once per source and context.
function useDataSources(
  definitions: WidgetPropertyDefinition[],
  properties: Properties,
  props: MarketplaceWidgetProps,
  reloads: number,
): Record<string, Loaded> {
  const scopes = useSourceScopes(props.context);
  const parameters = useContext(PageParameters);
  const invokeNanoflow = useContext(ListSourceNanoflows);
  const sources = definitions
    .filter((definition) => definition.type === 'DataSource')
    .map((definition) => {
      const source = marketplaceDataSource(properties[definition.key]);
      const list = source?.source;
      return {
        key: definition.key,
        source,
        start: list ? sourceStart(list, props.context, scopes) : props.context,
        mappings: list ? sourceMappings(list, props.context, scopes) : {},
        path:
          source && !list
            ? withXPath(
                `/api/entities/${encodeURIComponent(source.entity)}`,
                source.xpath || undefined,
                props.context,
                parameters,
              )
            : '',
      };
    });
  const key = JSON.stringify([sources, props.revision || 0, reloads]);
  const [loaded, setLoaded] = useState<{ key: string; lists: Record<string, Loaded> }>({
    key: '',
    lists: {},
  });
  const pending = useRef(sources);
  pending.current = sources;
  useEffect(() => {
    const request = props.request;
    if (!request) return;
    let active = true;
    Promise.all(
      pending.current.map(async ({ key: name, source, start, mappings, path }) => {
        if (!source) return [name, [] as EntityRecord[]] as const;
        const records = source.source
          ? await loadListSource(source.source, start, mappings, request, invokeNanoflow)
          : ((await request<EntityCollectionResponse>(path)).records ?? []);
        return [name, sortRecords(records, source.sort)] as const;
      }),
    )
      .then((entries) => {
        if (!active) return;
        const lists = Object.fromEntries(
          entries.map(([name, records]) => [name, { records, loading: false }]),
        );
        setLoaded({ key, lists });
      })
      .catch((failure: unknown) => {
        if (active) setLoaded({ key, lists: {} });
        console.error(failure);
      });
    return () => {
      active = false;
    };
  }, [key, props.request, invokeNanoflow]);
  return loaded.key === key ? loaded.lists : {};
}

// Empty values first, then numbers, dates and text in their natural order.
function compareValues(left: FilterValue, right: FilterValue): number {
  const key = (value: FilterValue) =>
    value instanceof Date
      ? value.getTime()
      : value instanceof Big
        ? Number(value.toString())
        : value;
  const a = key(left);
  const b = key(right);
  if (a === undefined || b === undefined) return a === b ? 0 : a === undefined ? -1 : 1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  return String(a).localeCompare(String(b), undefined, { numeric: true });
}

// The ListValue of one data source: filtered, sorted and paged in the browser.
function listValue(
  loaded: Loaded | undefined,
  state: ListState,
  update: (change: Partial<ListState>) => void,
  read: (record: EntityRecord, attributeId: string) => FilterValue,
  item: (record: EntityRecord) => ObjectItem,
  reload: () => void,
) {
  let records = loaded?.records ?? [];
  if (state.filter) {
    const condition = state.filter;
    records = records.filter((record) => matchesFilter(condition, (id) => read(record, id)));
  }
  if (state.sortOrder.length) {
    records = [...records].sort((left, right) => {
      for (const [id, direction] of state.sortOrder) {
        const order = compareValues(read(left, id), read(right, id));
        if (order) return direction === 'desc' ? -order : order;
      }
      return 0;
    });
  }
  const page =
    state.limit === undefined
      ? records.slice(state.offset)
      : records.slice(state.offset, state.offset + state.limit);
  return {
    status: loaded ? 'available' : 'loading',
    offset: state.offset,
    limit: state.limit ?? Number.POSITIVE_INFINITY,
    items: loaded ? page.map(item) : undefined,
    hasMoreItems: state.offset + page.length < records.length,
    totalCount: records.length,
    sortOrder: state.sortOrder,
    filter: state.filter,
    setOffset: (offset: number) => update({ offset }),
    setLimit: (limit: number | undefined) => update({ limit }),
    setSortOrder: (sortOrder: ListState['sortOrder'] | undefined) =>
      update({ sortOrder: sortOrder ?? [] }),
    setFilter: (filter: FilterCondition | undefined) => update({ filter, offset: 0 }),
    requestTotalCount: () => undefined,
    reload,
  };
}

interface HostProps extends MarketplaceWidgetProps {
  component: ComponentType<Record<string, unknown>>;
  definitions: WidgetPropertyDefinition[];
}

// Runs a project widget build with the pluggable widget API over the runtime.
export function PluggableHost(hostProps: HostProps) {
  const { component: Widget, definitions, ...props } = hostProps;
  const properties = object(props.widget.options?.properties);
  const environment = useCaptionEnvironment(props.schema);
  const pageParameters = useContext(PageParameters);
  const localVariables = useContext(LocalVariables);
  const snippet = useContext(VariableScope);
  const widgetObjects = useContext(WidgetObjectScope);
  const [reloads, setReloads] = useState(0);
  const lists = useDataSources(definitions, properties, props, reloads);
  const [states, setStates] = useState<Record<string, ListState>>({});
  const items = useRef(new Map<string, ObjectItem>());
  const recordsById = new Map<string, EntityRecord>();
  Object.values(lists).forEach((list) =>
    list.records.forEach((record) => recordsById.set(record.id, record)),
  );
  const item = (record: EntityRecord): ObjectItem => {
    const known = items.current.get(record.id);
    if (known) return known;
    const created = { id: record.id };
    items.current.set(record.id, created);
    return created;
  };
  const variables = {
    ...pageParameters,
    ...localVariables.values,
    ...snippet,
    ...widgetObjects,
  } as Record<string, RuntimeValue>;
  // A linked attribute's id is "<property>:<attribute>".
  const read = (record: EntityRecord, attributeId: string): FilterValue => {
    const attribute = attributeId.slice(attributeId.indexOf(':') + 1);
    const type = attributeDefinition(props.schema, record.type, attribute)?.type || '';
    return apiValue(record.attributes[memberName(attribute)], type) as FilterValue;
  };
  const listValues = Object.fromEntries(
    definitions
      .filter((definition) => definition.type === 'DataSource')
      .map((definition) => {
        const state = states[definition.key] ?? { offset: 0, sortOrder: [] };
        const update = (change: Partial<ListState>) =>
          setStates((current) => ({
            ...current,
            [definition.key]: { ...(current[definition.key] ?? state), ...change },
          }));
        return [
          definition.key,
          listValue(lists[definition.key], state, update, read, item, () =>
            setReloads((count) => count + 1),
          ),
        ];
      }),
  );
  const host: HostContext = {
    props,
    variables,
    environment,
    records: (id) => recordsById.get(id),
    lists: listValues,
    region: (key) => (props.regions || []).find((region) => region.role === key),
  };
  const widgetValues = widgetProps(definitions, properties, props.context, host);
  return (
    <Widget
      {...widgetValues}
      name={props.widget.name}
      class={String(props.widget.options?.class || '')}
      tabIndex={0}
    />
  );
}

// Registers one of the project's own widget builds under its widget id.
export function registerProjectWidget(
  id: string,
  module: Record<string, unknown>,
  name: string,
  definitions: WidgetPropertyDefinition[],
): () => void {
  const component = (module.default ?? module[name]) as
    ComponentType<Record<string, unknown>> | undefined;
  if (!component) throw new Error(`Widget build ${id} exports no ${name} component`);
  return registerMarketplaceWidget(id, (props) => (
    <PluggableHost {...props} component={component} definitions={definitions} />
  ));
}
