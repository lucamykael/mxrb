import { useId, useState, type CSSProperties, type ReactNode } from 'react';
import type { EntityRecord, WidgetColumn } from '../../types';
import { displayValue, recordValue } from '../value';
import { GridIcon } from './GridIcon';

interface Props {
  columns: WidgetColumn[];
  records: EntityRecord[];
  sorting: Array<{ attribute: string; direction: string }>;
  sort: (column: WidgetColumn) => void;
  filter: (column: WidgetColumn) => ReactNode;
  selected: (record: EntityRecord) => boolean;
  select: (record: EntityRecord) => void;
  page: number;
  pageSize: number;
  total: number;
  setPage: (page: number) => void;
  resizable: boolean;
  draggable: boolean;
  hidable: boolean;
}

export function NativeDataGrid(props: Props) {
  const {
    columns,
    records,
    sorting,
    sort,
    filter,
    selected,
    select,
    page,
    pageSize,
    total,
    setPage,
  } = props;
  const [hidden, setHidden] = useState<string[]>([]);
  const [order, setOrder] = useState<string[]>([]);
  const [widths, setWidths] = useState<Record<string, number>>({});
  const [chooser, setChooser] = useState(false);
  const id = useId();
  const key = (column: WidgetColumn) => column.attribute || column.name || '';
  const visible = columns
    .filter((column) => !hidden.includes(key(column)))
    .sort((left, right) => {
      const index = (column: WidgetColumn) =>
        order.includes(key(column))
          ? order.indexOf(key(column))
          : columns.indexOf(column) + order.length;
      return index(left) - index(right);
    });
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const status = `${total ? page * pageSize + 1 : 0} to ${Math.min((page + 1) * pageSize, total)} of ${total}`;
  const columnSelector = props.hidable;
  const button = (
    name: 'step-backward' | 'backward' | 'forward' | 'step-forward',
    label: string,
    target: number,
    disabled: boolean,
  ) => (
    <button
      className="btn pagination-button"
      aria-label={label}
      disabled={disabled}
      onClick={() => setPage(target)}
    >
      <span aria-hidden="true">
        <GridIcon name={name} />
      </span>
    </button>
  );
  return (
    <div className="widget-datagrid">
      <div className="widget-datagrid-top-bar table-header">
        <div className="widget-datagrid-paging-top">
          <div className="widget-datagrid-tb-start" />
          <div className="widget-datagrid-tb-end" />
        </div>
      </div>
      <div className="widget-datagrid-content">
        <div
          className="widget-datagrid-grid table"
          role="grid"
          style={
            {
              '--widgets-grid-template-columns': [
                ...visible.map((column) =>
                  widths[key(column)] ? `${widths[key(column)]}px` : 'minmax(auto, 1fr)',
                ),
                ...(columnSelector ? ['54px'] : []),
              ].join(' '),
            } as CSSProperties
          }
        >
          <div className="widget-datagrid-grid-head" role="rowgroup">
            <div className="tr" role="row">
              {visible.map((column, index) => {
                const name = key(column);
                const label = column.caption || column.name || name;
                const active = sorting.find((entry) => entry.attribute === name);
                const sortingOrder = active
                  ? active.direction === 'Ascending'
                    ? 'ascending'
                    : 'descending'
                  : 'none';
                return (
                  <div
                    key={name}
                    className="th"
                    role="columnheader"
                    title={label}
                    aria-sort={sortingOrder}
                    data-column-id={index}
                    onDragOver={(event) => {
                      if (props.draggable) event.preventDefault();
                    }}
                    onDrop={(event) => {
                      if (!props.draggable) return;
                      event.preventDefault();
                      const source = event.dataTransfer.getData('text/plain');
                      if (!columns.some((entry) => key(entry) === source)) return;
                      const next = visible.map(key).filter((entry) => entry !== source);
                      next.splice(next.indexOf(name), 0, source);
                      setOrder(next);
                    }}
                  >
                    <div
                      className="column-container"
                      draggable={props.draggable}
                      onDragStart={(event) => event.dataTransfer.setData('text/plain', name)}
                    >
                      <div
                        className={`column-header ${column.sortable === false ? '' : 'clickable'} align-column-left`}
                        role={column.sortable === false ? undefined : 'button'}
                        tabIndex={column.sortable === false ? undefined : 0}
                        aria-label={`sort ${label}`}
                        onClick={() => {
                          if (column.sortable !== false) sort(column);
                        }}
                        onKeyDown={(event) => {
                          if (column.sortable !== false && ['Enter', ' '].includes(event.key)) {
                            event.preventDefault();
                            sort(column);
                          }
                        }}
                      >
                        <span>{label}</span>
                        {column.sortable !== false && <GridIcon name="arrows-alt-v" />}
                      </div>
                      <div className="filter">{filter(column)}</div>
                    </div>
                    {props.resizable && index < visible.length - 1 && (
                      <div
                        className="column-resizer"
                        role="separator"
                        aria-label={`Resize ${label}`}
                        aria-orientation="vertical"
                        tabIndex={0}
                        onKeyDown={(event) => {
                          if (['ArrowLeft', 'ArrowRight'].includes(event.key)) {
                            event.preventDefault();
                            const width =
                              event.currentTarget.parentElement!.getBoundingClientRect().width;
                            setWidths((values) => ({
                              ...values,
                              [name]: Math.max(40, width + (event.key === 'ArrowRight' ? 10 : -10)),
                            }));
                          }
                        }}
                        onPointerDown={(event) => {
                          event.preventDefault();
                          const start = event.clientX;
                          const width =
                            event.currentTarget.parentElement!.getBoundingClientRect().width;
                          const element = event.currentTarget;
                          element.setPointerCapture(event.pointerId);
                          element.onpointermove = (move) =>
                            setWidths((values) => ({
                              ...values,
                              [name]: Math.max(40, width + move.clientX - start),
                            }));
                          element.onlostpointercapture = () => {
                            element.onpointermove = null;
                          };
                        }}
                      >
                        <div className="column-resizer-bar" />
                      </div>
                    )}
                  </div>
                );
              })}
              {columnSelector && (
                <div
                  className="th column-selector"
                  role="columnheader"
                  aria-label="Column selector"
                  title="Column selector"
                >
                  <div className="column-selector-content">
                    <button
                      className="btn btn-default column-selector-button"
                      aria-label="Column selector"
                      aria-haspopup="true"
                      aria-expanded={chooser}
                      aria-controls={id}
                      onClick={() => setChooser(!chooser)}
                    >
                      <GridIcon name="eye" />
                    </button>
                    {chooser && (
                      <div
                        id={id}
                        className="column-selectors"
                        role="group"
                        aria-label="Visible columns"
                      >
                        {columns.map((column) => (
                          <label key={key(column)}>
                            <input
                              type="checkbox"
                              checked={!hidden.includes(key(column))}
                              disabled={visible.length === 1 && !hidden.includes(key(column))}
                              onChange={(event) =>
                                setHidden((values) =>
                                  event.target.checked
                                    ? values.filter((value) => value !== key(column))
                                    : [...values, key(column)],
                                )
                              }
                            />
                            {column.caption || column.name}
                          </label>
                        ))}
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>
          </div>
          <div className="widget-datagrid-grid-body table-content" role="rowgroup">
            {records.map((record) => (
              <div
                key={`${record.type}/${record.id}`}
                className={`tr ${selected(record) ? 'tr-selected' : ''}`}
                role="row"
                aria-selected={selected(record)}
                tabIndex={0}
                onClick={() => select(record)}
                onKeyDown={(event) => {
                  if (['Enter', ' '].includes(event.key)) {
                    event.preventDefault();
                    select(record);
                  }
                }}
              >
                {visible.map((column) => (
                  <div key={key(column)} className="td" role="gridcell">
                    {displayValue(recordValue(record, column.attribute || column.name))}
                  </div>
                ))}
                {columnSelector && <div className="td" role="gridcell" />}
              </div>
            ))}
          </div>
        </div>
      </div>
      <div className="widget-datagrid-footer table-footer">
        <div className="widget-datagrid-paging-bottom">
          <div className="widget-datagrid-pb-start" />
          <div className="widget-datagrid-pb-end">
            <div className="pagination-bar" aria-label="Pagination">
              {button('step-backward', 'Go to first page', 0, page === 0)}
              {button('backward', 'Go to previous page', page - 1, page === 0)}
              <span className="sr-only sr-only-focusable">Currently showing {status}</span>
              <div className="paging-status" aria-hidden="true">
                {status}
              </div>
              {button('forward', 'Go to next page', page + 1, page >= pages - 1)}
              {button('step-forward', 'Go to last page', pages - 1, page >= pages - 1)}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
