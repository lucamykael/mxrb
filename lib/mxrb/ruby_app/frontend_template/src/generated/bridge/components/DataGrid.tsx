import { decimal, type DecimalValue, isDecimal, numericCompare, numericText } from '../decimal';
import { useEffect, useMemo, useState, type ChangeEvent } from 'react';
import type {
  ApiRequest,
  EntityCollectionResponse,
  EntityRecord,
  RuntimeValue,
  WidgetColumn,
  WidgetDefinition,
} from '../../types';
import type { ErrorHandler, SelectRecord } from '../contracts';
import { classes, displayValue, entityCollectionPath, recordValue, sortRecords } from '../value';
import { NativeDataGrid } from './NativeDataGrid';

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
}

type FilterType = 'text' | 'number' | 'date' | 'boolean' | 'enum';
type FilterConfig = {
  type: FilterType;
  operator: string;
  options: Array<{ value: string; caption: string }>;
};
type Sorting = { attribute: string; direction: 'Ascending' | 'Descending' };

const defaultOperator: Record<FilterType, string> = {
  text: 'contains',
  number: 'equals',
  date: 'equals',
  boolean: 'equals',
  enum: 'equals',
};

const filterConfig = (column: WidgetColumn): FilterConfig | null => {
  if (!column.filter) return null;
  const source =
    typeof column.filter === 'object'
      ? column.filter
      : { type: column.filter, operator: undefined, options: undefined };
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

const activeFilter = (value: string, config: FilterConfig): boolean =>
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

const FilterInput = ({
  column,
  value,
  onChange,
}: {
  column: WidgetColumn;
  value: string;
  onChange: (value: string) => void;
}) => {
  const config = filterConfig(column);
  if (!config) return null;
  const label = column.caption || column.name || column.attribute || 'column';
  const update = (event: ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    onChange(event.target.value);
  if (['empty', 'not_empty'].includes(config.operator)) {
    return (
      <span aria-label={`Filter ${label}`}>
        {config.operator === 'empty' ? 'Empty' : 'Not empty'}
      </span>
    );
  }
  if (config.type === 'boolean') {
    return (
      <select aria-label={`Filter ${label}`} value={value} onChange={update}>
        <option value="">Any</option>
        <option value="true">True</option>
        <option value="false">False</option>
      </select>
    );
  }
  if (config.type === 'enum') {
    return (
      <select aria-label={`Filter ${label}`} value={value} onChange={update}>
        <option value="">Any</option>
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
}: DataGridProps) {
  const options = widget.options || {};
  const [records, setRecords] = useState<EntityRecord[]>([]);
  const [total, setTotal] = useState(0);
  const [pageNumber, setPageNumber] = useState(0);
  const [reload, setReload] = useState(0);
  const multi = ['multi', 'multiple'].includes(String(options.selection));
  const [selection, setSelection] = useState<EntityRecord[]>([]);
  const [selected, setSelected] = useState<EntityRecord | null>(null);
  const [loading, setLoading] = useState(false);
  const [filters, setFilters] = useState<Record<string, string>>({});
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
  const filterSpecs = columns.flatMap((column) => {
    const config = filterConfig(column);
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
  const basePath = entityCollectionPath(options.entity || '', options.association, pageContext);
  const collectionPath = serverSide
    ? serverCollectionPath(basePath, filterSpecs, sorting, pageNumber, pageSize)
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
        : records.filter((record) =>
            columns.every((column) => {
              const config = filterConfig(column);
              if (!config) return true;
              const key = column.name || column.attribute || '';
              const query = filters[key] || '';
              return (
                !activeFilter(query, config) ||
                matchesGridFilter(
                  recordValue(record, column.attribute || column.name),
                  query,
                  config,
                )
              );
            }),
          ),
    [columns, filters, records, serverSide],
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
        filter={(column) => (
          <FilterInput
            column={column}
            value={filters[column.name || column.attribute || ''] || ''}
            onChange={(value) => {
              setFilters((current) => ({
                ...current,
                [column.name || column.attribute || '']: value,
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
          onRowAction(record);
        }}
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
