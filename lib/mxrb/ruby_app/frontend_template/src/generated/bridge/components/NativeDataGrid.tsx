import { useId, useState, type ReactNode } from 'react';
import type { EntityRecord, WidgetColumn } from '../../types';
import { GridIcon } from './GridIcon';

interface Props {
  columns: WidgetColumn[];
  records: EntityRecord[];
  sorting: Array<{ attribute: string; direction: string }>;
  sort: (column: WidgetColumn) => void;
  filter: (column: WidgetColumn) => ReactNode;
  selected: (record: EntityRecord) => boolean;
  select: (record: EntityRecord) => void;
  activate: (record: EntityRecord) => void;
  clickTrigger: 'single' | 'double';
  cell: (record: EntityRecord, column: WidgetColumn) => ReactNode;
  header?: ReactNode;
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
    activate,
    cell,
    page,
    pageSize,
    total,
    setPage,
  } = props;
  // Columns over the same attribute (such as an action column) keep their own
  // identity for hiding, ordering and sizing.
  const keys = new Map<WidgetColumn, string>();
  columns.forEach((column) => {
    const base = column.attribute || column.name || '';
    let candidate = base;
    for (let copy = 2; [...keys.values()].includes(candidate); copy += 1)
      candidate = `${base}#${copy}`;
    keys.set(column, candidate);
  });
  const key = (column: WidgetColumn) => keys.get(column) ?? column.attribute ?? column.name ?? '';
  const [hidden, setHidden] = useState<string[]>(() =>
    columns.filter((column) => column.hidable === 'hidden').map(key),
  );
  const [order, setOrder] = useState<string[]>([]);
  const [widths, setWidths] = useState<Record<string, number>>({});
  const [chooser, setChooser] = useState(false);
  const id = useId();
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
  const hidableColumns = columns.filter((column) => column.hidable !== false);
  const alignment = (column: WidgetColumn) => `align-column-${column.alignment || 'left'}`;
  // Column widths as Data grid 2 writes them: autoFill shares the free space by
  // size, autoFit follows the content and manual is a pixel width.
  const track = (column: WidgetColumn) => {
    if (widths[key(column)]) return `${widths[key(column)]}px`;
    if (column.width === 'auto_fit') return 'minmax(auto, auto)';
    if (column.width === 'manual') return `${column.size || 100}px`;
    return `${column.size || 1}fr`;
  };
  const run = (record: EntityRecord) => {
    select(record);
    if (props.clickTrigger === 'single') activate(record);
  };
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
      {props.header && (
        <div className="widget-datagrid-header header-filters" aria-label="Grid header">
          {props.header}
        </div>
      )}
      <div className="widget-datagrid-content">
        <div
          className="widget-datagrid-grid table"
          role="grid"
          style={{
            gridTemplateColumns: [...visible.map(track), ...(columnSelector ? ['54px'] : [])].join(
              ' ',
            ),
          }}
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
                        className={`column-header ${column.sortable === false ? '' : 'clickable'} ${alignment(column)}`}
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
                        {column.sortable !== false && (
                          <GridIcon
                            name={
                              sortingOrder === 'ascending'
                                ? 'long-arrow-alt-up'
                                : sortingOrder === 'descending'
                                  ? 'long-arrow-alt-down'
                                  : 'arrows-alt-v'
                            }
                          />
                        )}
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
                        {hidableColumns.map((column) => (
                          <label key={key(column)}>
                            <input
                              type="checkbox"
                              checked={!hidden.includes(key(column))}
                              disabled={
                                visible.filter((entry) => entry.hidable !== false).length === 1 &&
                                !hidden.includes(key(column))
                              }
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
                onClick={() => run(record)}
                onDoubleClick={() => {
                  if (props.clickTrigger === 'double') activate(record);
                }}
                onKeyDown={(event) => {
                  if (['Enter', ' '].includes(event.key)) {
                    event.preventDefault();
                    select(record);
                    activate(record);
                  }
                }}
              >
                {visible.map((column) => (
                  <div key={key(column)} className={`td ${alignment(column)}`} role="gridcell">
                    {cell(record, column)}
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
