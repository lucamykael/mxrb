import { decimal, type DecimalValue, isDecimal, numericCompare, numericText } from '../decimal';
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ChangeEvent,
  type ReactNode,
} from 'react';
import type {
  ApiRequest,
  ApplicationSchema,
  EntityCollectionResponse,
  EntityRecord,
  RuntimeValue,
  WidgetColumn,
  WidgetDefinition,
} from '../../types';
import type { ErrorHandler, SelectRecord } from '../contracts';
import { attributeDefinition, enumerationDefinition } from '../schemaLookup';
import {
  classes,
  displayValue,
  entityCollectionPath,
  expressionValue,
  isEntityRecord,
  memberName,
  recordValue,
  sortRecords,
  withXPath,
} from '../value';
import { PageParameters } from '../PageVariables';
import { NativeDataGrid } from './NativeDataGrid';
import { GridIcon } from './GridIcon';

interface DataGridProps {
  widget: WidgetDefinition;
  request: ApiRequest;
  pageContext: EntityRecord | null;
  revision: number;
  onError: ErrorHandler;
  onMutation: () => void;
  onRowAction: (record: EntityRecord) => unknown;
  onSelectRecord: SelectRecord;
  onSelectRecords?: (records: EntityRecord[]) => void;
  schema?: ApplicationSchema | null;
  // Renders widgets with a row as their context, or the grid's own context.
  renderWidgets?: (
    widgets: WidgetDefinition[],
    record: EntityRecord | null,
    key: string,
  ) => ReactNode;
}

type FilterType = 'text' | 'number' | 'date' | 'boolean' | 'enum';
export type FilterConfig = {
  type: FilterType;
  operator: string;
  options: Array<{ value: string; caption: string }>;
};
type Sorting = { attribute: string; direction: 'Ascending' | 'Descending' };

// A filter widget in the filters placeholder searches the grid's filter list:
// a record matches when any of its string attributes does.
export type PlaceholderFilter = { operator: string; value: string };
export const DataGridFilters = createContext<{
  attributes: string[];
  setFilter: (id: string, filter: PlaceholderFilter | null) => void;
} | null>(null);

const defaultOperator: Record<FilterType, string> = {
  text: 'contains',
  number: 'equals',
  date: 'equals',
  boolean: 'equals',
  enum: 'equals',
};

// A Data grid 2 drop-down filter lists the values of a boolean or enumeration
// attribute; over an association it has no attribute values to offer.
const dropDownFilter = (
  column: WidgetColumn,
  entity: string,
  schema: ApplicationSchema | null | undefined,
): Pick<FilterConfig, 'type' | 'options'> | null => {
  if (column.association_path?.length) return null;
  const attribute = attributeDefinition(schema, entity, column.attribute || column.name || '');
  if (attribute?.type === 'boolean') return { type: 'boolean', options: [] };
  const enumeration =
    attribute?.enumeration && enumerationDefinition(schema, attribute.enumeration);
  if (!enumeration) return null;
  return {
    type: 'enum',
    options: enumeration.values.map((value) => ({ value: value.name, caption: value.caption })),
  };
};

const filterConfig = (
  column: WidgetColumn,
  entity = '',
  schema?: ApplicationSchema | null,
): FilterConfig | null => {
  if (!column.filter) return null;
  const source =
    typeof column.filter === 'object'
      ? column.filter
      : { type: column.filter, operator: undefined, options: undefined };
  if (String(source.type).toLowerCase() === 'drop_down') {
    const resolved = dropDownFilter(column, entity, schema);
    return resolved && { ...resolved, operator: 'equals' };
  }
  const candidate = String(source.type || 'text').toLowerCase();
  const type: FilterType = ['text', 'number', 'date', 'boolean', 'enum'].includes(candidate)
    ? (candidate as FilterType)
    : 'text';
  const options = Array.isArray(source.options)
    ? source.options.map((option) => {
        if (option && typeof option === 'object') {
          return {
            value: String(option.value ?? ''),
            caption: String(option.caption ?? option.value ?? ''),
          };
        }
        return { value: String(option ?? ''), caption: String(option ?? '') };
      })
    : [];
  return { type, operator: String(source.operator || defaultOperator[type]), options };
};

const comparable = (
  value: RuntimeValue | undefined,
  type: FilterType,
): string | number | DecimalValue | null => {
  if (value == null || value === '') return null;
  if (type === 'number') {
    try {
      return decimal(value);
    } catch {
      return null;
    }
  }
  if (type === 'date') {
    const date = Date.parse(String(value).slice(0, 10));
    return Number.isNaN(date) ? null : date;
  }
  if (type === 'boolean') {
    if (typeof value === 'boolean') return value ? 1 : 0;
    if (String(value).toLowerCase() === 'true') return 1;
    if (String(value).toLowerCase() === 'false') return 0;
    return null;
  }
  return String(value).toLocaleLowerCase();
};

const bounds = (query: string): [string, string] | null => {
  const values = query.split(/\.\.|,/).map((value) => value.trim());
  return values.length === 2 && values.every(Boolean) ? [values[0], values[1]] : null;
};

const compare = (
  left: string | number | DecimalValue,
  right: string | number | DecimalValue,
): number =>
  isDecimal(left) && isDecimal(right)
    ? numericCompare(left, right)
    : typeof left === 'number' && typeof right === 'number'
      ? left - right
      : numericText(left).localeCompare(numericText(right), undefined, { numeric: true });

export const matchesGridFilter = (
  actual: RuntimeValue | undefined,
  query: string,
  config: FilterConfig,
): boolean => {
  if (config.operator === 'empty') return actual == null || actual === '';
  if (config.operator === 'not_empty') return actual != null && actual !== '';
  const left = comparable(actual, config.type);
  if (left == null) return false;
  if (config.operator === 'between') {
    const range = bounds(query);
    if (!range) return false;
    const start = comparable(range[0], config.type);
    const finish = comparable(range[1], config.type);
    return (
      start != null && finish != null && compare(left, start) >= 0 && compare(left, finish) <= 0
    );
  }
  const right = comparable(query, config.type);
  if (right == null) return false;
  if (config.operator === 'contains') return numericText(left).includes(numericText(right));
  if (config.operator === 'starts_with') return numericText(left).startsWith(numericText(right));
  if (config.operator === 'ends_with') return numericText(left).endsWith(numericText(right));
  if (config.operator === 'not_equals') return compare(left, right) !== 0;
  if (['gt', 'after'].includes(config.operator)) return compare(left, right) > 0;
  if (['gte', 'on_or_after'].includes(config.operator)) return compare(left, right) >= 0;
  if (['lt', 'before'].includes(config.operator)) return compare(left, right) < 0;
  if (['lte', 'on_or_before'].includes(config.operator)) return compare(left, right) <= 0;
  return compare(left, right) === 0;
};

// The value a column shows: its attribute, read over its association path
// (a list when a step is a reference set).
export const columnValue = (
  record: EntityRecord,
  column: WidgetColumn,
): RuntimeValue | undefined => {
  const attribute = column.attribute || column.name;
  if (!column.association_path?.length) return recordValue(record, attribute);
  let objects: EntityRecord[] = [record];
  column.association_path.forEach((step) => {
    objects = objects.flatMap((object) => {
      const value = recordValue(object, step.association);
      return (Array.isArray(value) ? value : [value]).filter(isEntityRecord);
    });
  });
  const values = objects.map((object) => object.attributes[memberName(attribute)] ?? null);
  return values.length === 1 ? values[0] : values;
};

const dynamicText = (column: WidgetColumn, record: EntityRecord): string =>
  (column.parameters || []).reduce<string>(
    (text, parameter, index) =>
      text.replaceAll(`{${index + 1}}`, String(displayValue(expressionValue(parameter, record)))),
    column.dynamic_text || '',
  );

const textFilter = (operator: string): FilterConfig => ({ type: 'text', operator, options: [] });

export const activeFilter = (value: string, config: FilterConfig): boolean =>
  ['empty', 'not_empty'].includes(config.operator) || value.trim() !== '';

const serverCollectionPath = (
  base: string,
  filters: Array<Record<string, unknown>>,
  sort: Sorting[],
  pageNumber: number,
  pageSize: number,
): string => {
  const [path, query = ''] = base.split('?', 2);
  const parameters = new URLSearchParams(query);
  parameters.set('filters', JSON.stringify(filters));
  parameters.set('sort', JSON.stringify(sort));
  parameters.set('offset', String(pageNumber * pageSize));
  parameters.set('limit', String(pageSize));
  return `${path}?${parameters}`;
};

// The operators a Data grid 2 filter offers, with its icon class and caption.
const FILTER_OPERATORS: Record<FilterType, string[]> = {
  text: [
    'contains',
    'starts_with',
    'ends_with',
    'gt',
    'gte',
    'equals',
    'not_equals',
    'lt',
    'lte',
    'empty',
    'not_empty',
  ],
  number: ['gt', 'gte', 'equals', 'not_equals', 'lt', 'lte', 'empty', 'not_empty'],
  date: ['between', 'gt', 'gte', 'equals', 'not_equals', 'lt', 'lte', 'empty', 'not_empty'],
  boolean: [],
  enum: [],
};
const OPERATOR_LABELS: Record<string, [string, string]> = {
  contains: ['contains', 'Contains'],
  starts_with: ['startsWith', 'Starts with'],
  ends_with: ['endsWith', 'Ends with'],
  gt: ['greater', 'Greater than'],
  gte: ['greaterEqual', 'Greater than or equal'],
  equals: ['equal', 'Equal'],
  not_equals: ['notEqual', 'Not equal'],
  lt: ['smaller', 'Smaller than'],
  lte: ['smallerEqual', 'Smaller than or equal'],
  empty: ['empty', 'Empty'],
  not_empty: ['notEmpty', 'Not empty'],
  between: ['between', 'Between'],
};

export const OperatorSelector = ({
  config,
  onSelect,
}: {
  config: FilterConfig;
  onSelect: (operator: string) => void;
}) => {
  const [open, setOpen] = useState(false);
  const [icon, caption] = OPERATOR_LABELS[config.operator] || [config.operator, config.operator];
  return (
    <div className="filter-selector">
      <div className="filter-selector-content">
        <button
          type="button"
          className={`btn btn-default filter-selector-button button-icon ${icon}`}
          aria-label={caption}
          title={caption}
          aria-haspopup="listbox"
          aria-expanded={open}
          onClick={() => setOpen(!open)}
        />
        <ul
          className={`filter-selectors ${open ? 'visible' : 'hidden'}`}
          role="listbox"
          aria-label="Select filter type"
          hidden={!open}
        >
          {FILTER_OPERATORS[config.type].map((operator) => (
            <li
              key={operator}
              role="option"
              aria-selected={operator === config.operator}
              className={`filter-listitem${operator === config.operator ? ' filter-selected' : ''}`}
              onClick={() => {
                onSelect(operator);
                setOpen(false);
              }}
            >
              <div className={`filter-icon ${OPERATOR_LABELS[operator][0]}`} aria-hidden="true" />
              <div className="filter-label">{OPERATOR_LABELS[operator][1]}</div>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
};

const FilterInput = ({
  column,
  config,
  value,
  onChange,
  onOperator,
}: {
  column: WidgetColumn;
  config: FilterConfig | null;
  value: string;
  onChange: (value: string) => void;
  // Data grid 2 filters let the user choose the operator.
  onOperator?: (operator: string) => void;
}) => {
  if (!config) return null;
  const label = column.caption || column.name || column.attribute || 'column';
  const update = (event: ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    onChange(event.target.value);
  if (onOperator && FILTER_OPERATORS[config.type].length) {
    const empty = ['empty', 'not_empty'].includes(config.operator);
    const input = (
      <input
        className="form-control filter-input"
        aria-label={`Filter ${label}`}
        type={config.operator !== 'between' && config.type !== 'text' ? config.type : 'search'}
        value={empty ? '' : value}
        disabled={empty}
        onChange={update}
      />
    );
    return (
      <div className="filter-container">
        <OperatorSelector config={config} onSelect={onOperator} />
        {config.type === 'date' ? (
          <>
            <div className="react-datepicker-wrapper">
              <div className="react-datepicker__input-container">{input}</div>
            </div>
            <button
              type="button"
              className="btn btn-default btn-calendar"
              aria-label="Show calendar"
              disabled={empty}
              onClick={(event) => {
                const field = event.currentTarget.parentElement?.querySelector<HTMLInputElement>(
                  '.react-datepicker-wrapper input',
                );
                field?.showPicker?.();
              }}
            >
              <GridIcon name="calendar" />
            </button>
          </>
        ) : (
          input
        )}
      </div>
    );
  }
  if (['empty', 'not_empty'].includes(config.operator)) {
    return (
      <span aria-label={`Filter ${label}`}>
        {config.operator === 'empty' ? 'Empty' : 'Not empty'}
      </span>
    );
  }
  // Data grid 2 drop-down filters read like the widget: Select, Yes and No.
  const native = Boolean(onOperator);
  if (config.type === 'boolean') {
    return (
      <select
        className={native ? 'form-control' : undefined}
        aria-label={`Filter ${label}`}
        value={value}
        onChange={update}
      >
        <option value="">{native ? 'Select' : 'Any'}</option>
        <option value="true">{native ? 'Yes' : 'True'}</option>
        <option value="false">{native ? 'No' : 'False'}</option>
      </select>
    );
  }
  if (config.type === 'enum') {
    return (
      <select
        className={native ? 'form-control' : undefined}
        aria-label={`Filter ${label}`}
        value={value}
        onChange={update}
      >
        <option value="">{native ? 'Select' : 'Any'}</option>
        {config.options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.caption}
          </option>
        ))}
      </select>
    );
  }
  const type =
    config.operator === 'between'
      ? 'search'
      : config.type === 'date'
        ? 'date'
        : config.type === 'number'
          ? 'number'
          : 'search';
  return (
    <input
      aria-label={`Filter ${label}`}
      type={type}
      placeholder={`Filter ${label}`}
      value={value}
      onChange={update}
    />
  );
};

export function DataGrid({
  widget,
  request,
  pageContext,
  revision,
  onError,
  onMutation,
  onRowAction,
  onSelectRecord,
  onSelectRecords,
  schema,
  renderWidgets,
}: DataGridProps) {
  const options = widget.options || {};
  const pageParameters = useContext(PageParameters);
  const [operators, setOperators] = useState<Record<string, string>>({});
  const withOperator = (config: FilterConfig | null, column: WidgetColumn) => {
    const chosen = operators[column.name || column.attribute || ''];
    return config && chosen ? { ...config, operator: chosen } : config;
  };
  const configOf = (column: WidgetColumn) =>
    withOperator(filterConfig(column, options.entity, schema), column);
  const [records, setRecords] = useState<EntityRecord[]>([]);
  const [total, setTotal] = useState(0);
  const [pageNumber, setPageNumber] = useState(0);
  const [reload, setReload] = useState(0);
  const multi = ['multi', 'multiple'].includes(String(options.selection));
  const [selection, setSelection] = useState<EntityRecord[]>([]);
  const [selected, setSelected] = useState<EntityRecord | null>(null);
  const [loading, setLoading] = useState(false);
  const [filters, setFilters] = useState<Record<string, string>>({});
  const [placeholderFilters, setPlaceholderFilters] = useState<Record<string, PlaceholderFilter>>(
    {},
  );
  const setPlaceholderFilter = useCallback((id: string, filter: PlaceholderFilter | null) => {
    setPlaceholderFilters((current) => {
      const { [id]: previous, ...rest } = current;
      if (!filter) return previous ? rest : current;
      return previous?.operator === filter.operator && previous.value === filter.value
        ? current
        : { ...rest, [id]: filter };
    });
    setPageNumber(0);
  }, []);
  const [sorting, setSorting] = useState<Sorting[]>(() =>
    (options.sort || []).map((item) => ({
      attribute: item.attribute,
      direction: item.direction === 'Descending' ? 'Descending' : 'Ascending',
    })),
  );
  const toggleSelection = (record: EntityRecord) => {
    const values = selection.some((item) => item.id === record.id && item.type === record.type)
      ? selection.filter((item) => item.id !== record.id || item.type !== record.type)
      : [...selection, record];
    setSelection(values);
    setSelected(values[0] || null);
    onSelectRecords?.(values);
  };
  const pageSize = Math.max(1, Number(options.page_size || options.pageSize || 20));
  const columns = options.columns || [];
  const serverSide = options.server_side === true;
  const searchAttributes = useMemo(
    () =>
      (options.filter_attributes || []).filter((attribute) => {
        const type = attributeDefinition(schema, options.entity || '', attribute)?.type;
        return !type || type.toLowerCase() === 'string';
      }),
    [options.filter_attributes, options.entity, schema],
  );
  const searches = useMemo(
    () =>
      searchAttributes.length
        ? Object.values(placeholderFilters).filter((filter) =>
            activeFilter(filter.value, textFilter(filter.operator)),
          )
        : [],
    [placeholderFilters, searchAttributes],
  );
  const searchSpecs = searches.map((filter) => ({
    any: searchAttributes.map((attribute) => ({
      attribute,
      type: 'text',
      operator: filter.operator,
      value: filter.value,
    })),
  }));
  const placeholderContext = useMemo(
    () => ({ attributes: searchAttributes, setFilter: setPlaceholderFilter }),
    [searchAttributes, setPlaceholderFilter],
  );
  const filterSpecs = columns.flatMap((column) => {
    const config = configOf(column);
    const key = column.name || column.attribute || '';
    const value = filters[key] || '';
    return config && activeFilter(value, config)
      ? [
          {
            attribute: column.attribute || column.name || '',
            type: config.type,
            operator: config.operator,
            value: config.operator === 'between' ? bounds(value) || value : value,
          },
        ]
      : [];
  });
  const basePath = withXPath(
    entityCollectionPath(options.entity || '', options.association, pageContext),
    options.xpath,
    pageContext,
    pageParameters,
  );
  const collectionPath = serverSide
    ? serverCollectionPath(
        basePath,
        [...filterSpecs, ...searchSpecs],
        sorting,
        pageNumber,
        pageSize,
      )
    : basePath;

  useEffect(() => {
    if (!options.entity) return;
    setLoading(true);
    request<EntityCollectionResponse>(collectionPath)
      .then((payload) => {
        const values = payload.records || [];
        setRecords(values);
        setTotal(payload.total ?? values.length);
        if (serverSide) {
          setPageNumber((current) =>
            Math.min(
              current,
              Math.max(0, Math.ceil((payload.total ?? values.length) / pageSize) - 1),
            ),
          );
        }
      })
      .catch(onError)
      .finally(() => setLoading(false));
  }, [collectionPath, options.entity, pageSize, reload, revision, request, onError, serverSide]);

  const mutate = <T,>(operation: Promise<T>): Promise<T> =>
    operation
      .then((result) => {
        setReload((value) => value + 1);
        onMutation();
        return result;
      })
      .catch((failure: unknown) => {
        onError(failure);
        throw failure;
      });
  const createRecord = () =>
    mutate(
      request<EntityRecord>(`/api/entities/${encodeURIComponent(options.entity || '')}`, {
        method: 'POST',
        body: '{}',
      }),
    ).then((record) => {
      setSelected(record);
      if (record) onSelectRecord(record);
    });
  const deleteRecord = () =>
    selected &&
    mutate(
      request(
        `/api/entities/${encodeURIComponent(options.entity || '')}/${encodeURIComponent(selected.id)}`,
        { method: 'DELETE' },
      ),
    ).then(() => {
      setSelected(null);
      onSelectRecord(null);
    });
  const toolbar = options.toolbar?.buttons || [{ type: 'new' }, { type: 'delete' }];
  const filteredRecords = useMemo(
    () =>
      serverSide
        ? records
        : records.filter(
            (record) =>
              searches.every((filter) =>
                searchAttributes.some((attribute) =>
                  matchesGridFilter(
                    recordValue(record, attribute),
                    filter.value,
                    textFilter(filter.operator),
                  ),
                ),
              ) &&
              columns.every((column) => {
                const base = filterConfig(column, options.entity, schema);
                const chosen = operators[column.name || column.attribute || ''];
                const config = base && chosen ? { ...base, operator: chosen } : base;
                if (!config) return true;
                const key = column.name || column.attribute || '';
                const query = filters[key] || '';
                const value = columnValue(record, column);
                return (
                  !activeFilter(query, config) ||
                  (Array.isArray(value) ? value : [value]).some((item) =>
                    matchesGridFilter(item, query, config),
                  )
                );
              }),
          ),
    [
      columns,
      filters,
      records,
      serverSide,
      options.entity,
      schema,
      operators,
      searches,
      searchAttributes,
    ],
  );
  const orderedRecords = useMemo(
    () => (serverSide ? filteredRecords : sortRecords(filteredRecords, sorting)),
    [filteredRecords, serverSide, sorting],
  );
  const rowCount = serverSide ? total : orderedRecords.length;
  const pageCount = Math.max(1, Math.ceil(rowCount / pageSize));
  const visible = serverSide
    ? orderedRecords
    : orderedRecords.slice(pageNumber * pageSize, (pageNumber + 1) * pageSize);

  const toggleSort = (column: WidgetColumn) => {
    const attribute = column.attribute || column.name || '';
    const current = sorting.find((item) => item.attribute === attribute);
    setSorting(
      !current
        ? [{ attribute, direction: 'Ascending' }]
        : current.direction === 'Ascending'
          ? [{ attribute, direction: 'Descending' }]
          : [],
    );
    setPageNumber(0);
  };

  if (options.presentation === 'datagrid2')
    return (
      <NativeDataGrid
        columns={columns}
        records={visible}
        sorting={sorting}
        sort={toggleSort}
        header={
          widget.header?.length && renderWidgets ? (
            <DataGridFilters.Provider value={placeholderContext}>
              {renderWidgets(widget.header, null, `${widget.name}-header`)}
            </DataGridFilters.Provider>
          ) : undefined
        }
        cell={(record, column) => {
          if (column.content && renderWidgets)
            return renderWidgets(column.content, record, `${record.id}-${column.name}`);
          if (column.dynamic_text !== undefined) return dynamicText(column, record);
          const value = columnValue(record, column);
          // Data grid 2 shows booleans as the Mendix client formats them.
          if (typeof value === 'boolean') return value ? 'Yes' : 'No';
          return displayValue(value);
        }}
        filter={(column) => (
          <FilterInput
            column={column}
            config={configOf(column)}
            value={filters[column.name || column.attribute || ''] || ''}
            onChange={(value) => {
              setFilters((current) => ({
                ...current,
                [column.name || column.attribute || '']: value,
              }));
              setPageNumber(0);
            }}
            onOperator={(operator) => {
              setOperators((current) => ({
                ...current,
                [column.name || column.attribute || '']: operator,
              }));
              setPageNumber(0);
            }}
          />
        )}
        selected={(record) =>
          multi
            ? selection.some((entry) => entry.id === record.id && entry.type === record.type)
            : selected?.id === record.id && selected.type === record.type
        }
        select={(record) => {
          if (multi) toggleSelection(record);
          else if (options.selection) {
            setSelected(record);
            onSelectRecord(record);
          }
        }}
        activate={onRowAction}
        clickTrigger={options.on_click_trigger === 'double' ? 'double' : 'single'}
        page={pageNumber}
        pageSize={pageSize}
        total={rowCount}
        setPage={setPageNumber}
        resizable={options.columns_resizable !== false}
        draggable={options.columns_draggable !== false}
        hidable={options.columns_hidable !== false}
      />
    );

  return (
    <div
      className={classes(
        'data-grid mx-grid mx-datagrid',
        'mxrb-data-grid-runtime',
        loading && 'is-loading',
      )}
      data-entity={options.entity || ''}
      data-server-side={serverSide ? 'true' : 'false'}
    >
      <div className="data-grid__toolbar mxrb-grid-toolbar mx-grid-controlbar">
        {toolbar.some((button) => button.type === 'new') ? (
          <button type="button" className="btn btn-primary mx-button" onClick={createRecord}>
            New
          </button>
        ) : null}
        {toolbar.some((button) => button.type === 'delete') ? (
          <button
            type="button"
            className="btn btn-default mx-button"
            disabled={!selected}
            onClick={deleteRecord}
          >
            Delete
          </button>
        ) : null}
        <button
          type="button"
          className="btn btn-default mx-button"
          onClick={() => setReload((value) => value + 1)}
        >
          Reload
        </button>
      </div>
      <table className="mx-datagrid-table">
        <thead className="mx-datagrid-head">
          <tr>
            {columns.map((column) => {
              const key = column.name || column.attribute;
              const label = column.caption || column.name;
              const active = sorting.find(
                (item) => item.attribute === (column.attribute || column.name),
              );
              return (
                <th
                  key={key}
                  aria-sort={
                    active
                      ? active.direction === 'Ascending'
                        ? 'ascending'
                        : 'descending'
                      : 'none'
                  }
                >
                  {column.sortable === false ? (
                    label
                  ) : (
                    <button
                      type="button"
                      aria-label={`Sort ${label}`}
                      className="mx-datagrid-head-caption mxrb-grid-sort"
                      onClick={() => toggleSort(column)}
                    >
                      {label}
                      {active ? (active.direction === 'Ascending' ? ' ▲' : ' ▼') : ''}
                    </button>
                  )}
                </th>
              );
            })}
          </tr>
          {columns.some((column) => column.filter) ? (
            <tr className="data-grid__filters">
              {columns.map((column) => {
                const key = column.name || column.attribute || '';
                return (
                  <th key={key}>
                    <FilterInput
                      column={column}
                      config={configOf(column)}
                      value={filters[key] || ''}
                      onChange={(value) => {
                        setFilters((current) => ({ ...current, [key]: value }));
                        setPageNumber(0);
                      }}
                    />
                  </th>
                );
              })}
            </tr>
          ) : null}
        </thead>
        <tbody className="mx-datagrid-body">
          {visible.map((record) => (
            <tr
              key={record.id}
              className={
                (
                  multi
                    ? selection.some((item) => item.id === record.id)
                    : selected?.id === record.id
                )
                  ? 'is-selected selected'
                  : ''
              }
              aria-selected={
                multi ? selection.some((item) => item.id === record.id) : selected?.id === record.id
              }
              tabIndex={0}
              onKeyDown={(event) => {
                if (event.key === ' ' || event.key === 'Enter') {
                  event.preventDefault();
                  event.currentTarget.click();
                }
              }}
              onClick={() => {
                if (multi) {
                  toggleSelection(record);
                  onRowAction(record);
                  return;
                }
                setSelected(record);
                onSelectRecord(record);
                onRowAction(record);
              }}
            >
              {columns.map((column) => (
                <td key={column.name || column.attribute}>
                  <div className="mx-datagrid-data-wrapper">
                    {displayValue(recordValue(record, column.attribute || column.name))}
                  </div>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="data-grid__pagination mxrb-grid-pagination mx-grid-pagingbar">
        <button
          type="button"
          className="btn btn-default mx-button"
          disabled={pageNumber === 0}
          onClick={() => setPageNumber((value) => value - 1)}
        >
          Previous
        </button>
        <span>
          Page {pageNumber + 1} of {pageCount} · {rowCount} rows
        </span>
        <button
          type="button"
          className="btn btn-default mx-button"
          disabled={pageNumber + 1 >= pageCount}
          onClick={() => setPageNumber((value) => value + 1)}
        >
          Next
        </button>
      </div>
    </div>
  );
}
