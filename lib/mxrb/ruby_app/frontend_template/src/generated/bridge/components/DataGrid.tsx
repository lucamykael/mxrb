import { useEffect, useMemo, useState } from 'react';
import type {
  ApiRequest,
  EntityCollectionResponse,
  EntityRecord,
  WidgetDefinition,
} from '../../types';
import type { ErrorHandler, SelectRecord } from '../contracts';
import { classes, displayValue, entityCollectionPath, recordValue, sortRecords } from '../value';

interface DataGridProps {
  widget: WidgetDefinition;
  request: ApiRequest;
  pageContext: EntityRecord | null;
  revision: number;
  onError: ErrorHandler;
  onMutation: () => void;
  onRowAction: (record: EntityRecord) => unknown;
  onSelectRecord: SelectRecord;
}

export function DataGrid({
  widget,
  request,
  pageContext,
  revision,
  onError,
  onMutation,
  onRowAction,
  onSelectRecord,
}: DataGridProps) {
  const options = widget.options || {};
  const [records, setRecords] = useState<EntityRecord[]>([]);
  const [pageNumber, setPageNumber] = useState(0);
  const [reload, setReload] = useState(0);
  const [selected, setSelected] = useState<EntityRecord | null>(null);
  const [loading, setLoading] = useState(false);
  const [filters, setFilters] = useState<Record<string, string>>({});
  const pageSize = Math.max(1, Number(options.page_size || options.pageSize || 20));
  const columns = options.columns || [];

  useEffect(() => {
    if (!options.entity) return;
    setLoading(true);
    request<EntityCollectionResponse>(
      entityCollectionPath(options.entity, options.association, pageContext),
    )
      .then((payload) => {
        const values = sortRecords(payload.records || [], options.sort || []);
        setRecords(values);
        setPageNumber((current) =>
          Math.min(current, Math.max(0, Math.ceil(values.length / pageSize) - 1)),
        );
      })
      .catch(onError)
      .finally(() => setLoading(false));
  }, [
    options.entity,
    options.association,
    pageContext?.type,
    pageContext?.id,
    pageSize,
    reload,
    revision,
    request,
    onError,
  ]);

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
      records.filter((record) =>
        columns.every((column) => {
          if (!column.filter) return true;
          const key = column.name || column.attribute || '';
          const query = (filters[key] || '').trim().toLocaleLowerCase();
          if (!query) return true;
          const value = displayValue(recordValue(record, column.attribute || column.name));
          return String(value).toLocaleLowerCase().includes(query);
        }),
      ),
    [columns, filters, records],
  );
  const pageCount = Math.max(1, Math.ceil(filteredRecords.length / pageSize));
  const visible = filteredRecords.slice(pageNumber * pageSize, (pageNumber + 1) * pageSize);

  return (
    <div
      className={classes('data-grid', 'mxrb-data-grid-runtime', loading && 'is-loading')}
      data-entity={options.entity || ''}
    >
      <div className="data-grid__toolbar mxrb-grid-toolbar">
        {toolbar.some((button) => button.type === 'new') ? (
          <button type="button" onClick={createRecord}>
            New
          </button>
        ) : null}
        {toolbar.some((button) => button.type === 'delete') ? (
          <button type="button" disabled={!selected} onClick={deleteRecord}>
            Delete
          </button>
        ) : null}
        <button type="button" onClick={() => setReload((value) => value + 1)}>
          Reload
        </button>
      </div>
      <table>
        <thead>
          <tr>
            {columns.map((column) => (
              <th key={column.name || column.attribute}>{column.caption || column.name}</th>
            ))}
          </tr>
          {columns.some((column) => column.filter) ? (
            <tr className="data-grid__filters">
              {columns.map((column) => {
                const key = column.name || column.attribute || '';
                const label = column.caption || column.name || column.attribute || 'column';
                return (
                  <th key={key}>
                    {column.filter ? (
                      <input
                        type="search"
                        aria-label={`Filter ${label}`}
                        placeholder={`Filter ${label}`}
                        value={filters[key] || ''}
                        onChange={(event) => {
                          setFilters((current) => ({ ...current, [key]: event.target.value }));
                          setPageNumber(0);
                        }}
                      />
                    ) : null}
                  </th>
                );
              })}
            </tr>
          ) : null}
        </thead>
        <tbody>
          {visible.map((record) => (
            <tr
              key={record.id}
              className={selected?.id === record.id ? 'is-selected' : ''}
              onClick={() => {
                setSelected(record);
                onSelectRecord(record);
                onRowAction(record);
              }}
            >
              {columns.map((column) => (
                <td key={column.name || column.attribute}>
                  {displayValue(recordValue(record, column.attribute || column.name))}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="data-grid__pagination mxrb-grid-pagination">
        <button
          type="button"
          disabled={pageNumber === 0}
          onClick={() => setPageNumber((value) => value - 1)}
        >
          Previous
        </button>
        <span>
          Page {pageNumber + 1} of {pageCount} · {filteredRecords.length} rows
        </span>
        <button
          type="button"
          disabled={pageNumber + 1 >= pageCount}
          onClick={() => setPageNumber((value) => value + 1)}
        >
          Next
        </button>
      </div>
    </div>
  );
}
