import { useEffect, useRef, useState, type CSSProperties } from 'react';
import { DataGrid } from './DataGrid';
import { BoundField } from './BoundField';
import { MarketplaceWidget, type MarketplaceWidgetRegion } from '../marketplace';
import type {
  EntityCollectionResponse,
  DataViewSource,
  EntityRecord,
  InvocationResult,
  RuntimeValue,
  RuntimeVariables,
  WidgetDefinition,
  WidgetEvent,
  WidgetOptions,
} from '../../types';
import type { WidgetRuntimeProps } from '../contracts';
import {
  caption,
  classes,
  dynamicClass,
  entityCollectionPath,
  eventArguments,
  expressionValue,
  inlineStyle,
  isEntityRecord,
  isVisible,
  memberName,
  sortRecords,
} from '../value';

type GalleryProps = Omit<WidgetRuntimeProps, 'context'>;

interface StructuralNode {
  options?: WidgetOptions;
  widgets?: WidgetDefinition[];
}

interface TableCellNode extends StructuralNode {
  column?: number;
  colspan?: number;
  rowspan?: number;
  header?: boolean;
}

interface TableRowNode extends StructuralNode {
  cells?: TableCellNode[];
}

type LayoutColumnNode = StructuralNode;

interface LayoutRowNode extends StructuralNode {
  columns?: LayoutColumnNode[];
}

const structuralRows = <Node,>(value: unknown): Node[] =>
  Array.isArray(value) ? (value as Node[]) : [];

const tableColumnWidth = (
  width: unknown,
  unit: unknown,
  totalWeight: number,
): string | undefined => {
  const value = Number(width);
  if (!Number.isFinite(value) || value <= 0) return;
  if (unit === 'percentage') return `${value}%`;
  if (unit === 'pixels') return `${value}px`;
  return totalWeight > 0 ? `${(value / totalWeight) * 100}%` : undefined;
};

const layoutColumnStyle = (options: WidgetOptions): CSSProperties => {
  const width = options.desktop;
  if (width === 'auto') return { flex: '0 0 auto' };
  if (width === 'grow' || width === undefined) return { flex: '1 1 0' };
  const columns = Number(width);
  return Number.isFinite(columns) && columns > 0
    ? { flex: `0 0 ${(columns / 12) * 100}%` }
    : { flex: '1 1 0' };
};

function Gallery({
  widget,
  moduleName,
  invoke,
  invokeNanoflow,
  navigate,
  pageContext,
  revision,
  schema,
  request,
  saveRecord,
  onError,
  onMutation,
  onSelectRecord,
}: GalleryProps) {
  const options = widget.options || {};
  const [records, setRecords] = useState<EntityRecord[]>([]);
  useEffect(() => {
    if (!options.entity) return;
    request<EntityCollectionResponse>(
      entityCollectionPath(options.entity, options.association, pageContext),
    )
      .then((payload) => setRecords(sortRecords(payload.records || [], options.sort || [])))
      .catch(onError);
  }, [
    options.entity,
    options.association,
    pageContext?.type,
    pageContext?.id,
    revision,
    request,
    onError,
  ]);
  return (
    <div
      className={classes('gallery', 'mxrb-widget', 'mxrb-gallery', options.class)}
      data-widget-name={widget.name}
      data-widget-type={widget.type}
    >
      <div className="gallery__items mxrb-gallery-items gallery-items">
        {records.map((record) => (
          <div className="gallery__item mxrb-gallery-item gallery-item" key={record.id}>
            {(widget.children || []).map((child, index) => (
              <WidgetRenderer
                key={`${child.name}-${index}`}
                widget={child}
                moduleName={moduleName}
                invoke={invoke}
                invokeNanoflow={invokeNanoflow}
                navigate={navigate}
                context={record}
                schema={schema}
                request={request}
                saveRecord={saveRecord}
                onError={onError}
                onMutation={onMutation}
                onSelectRecord={onSelectRecord}
                pageContext={pageContext}
                revision={revision}
              />
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

function DataView({
  widget,
  moduleName,
  invoke,
  invokeNanoflow,
  navigate,
  context,
  pageContext,
  revision,
  schema,
  request,
  saveRecord,
  onError,
  onMutation,
  onSelectRecord,
}: WidgetRuntimeProps) {
  const options = widget.options || {};
  const source = options.source as DataViewSource | undefined;
  const inheritedContext = context || pageContext;
  const [record, setRecord] = useState<EntityRecord | null>(inheritedContext);
  const [loading, setLoading] = useState(false);
  const [unsupported, setUnsupported] = useState<string | null>(null);
  const contextRef = useRef(inheritedContext);
  contextRef.current = inheritedContext;
  const sourceRevision = source?.kind === 'association' ? revision : 0;

  useEffect(() => {
    let current = true;
    const activeContext = contextRef.current;
    const accept = (value: unknown) => {
      const candidate = value as RuntimeValue;
      if (current) setRecord(isEntityRecord(candidate) ? candidate : null);
    };
    const mappings = (): RuntimeVariables =>
      Object.fromEntries(
        (source?.mappings || []).map((entry) => {
          const mapping = entry as Record<string, unknown>;
          const parameter = String(mapping.parameter || '').split('.').pop() || '';
          if (mapping.variable) return [parameter, activeContext || undefined];
          return [
            parameter,
            expressionValue(String(mapping.expression || ''), activeContext),
          ];
        }),
      );

    setUnsupported(null);
    setLoading(false);
    if (!source || source.kind === 'context') {
      return () => {
        current = false;
      };
    }
    if (source.kind === 'listen') {
      setRecord(null);
      setUnsupported(`listen source ${source.target || ''} requires a selection adapter`);
      return () => {
        current = false;
      };
    }

    setLoading(true);
    let pending: Promise<unknown>;
    if (source.kind === 'microflow' && source.name) {
      pending = request<InvocationResult>(
        `/api/microflows/${encodeURIComponent(source.name)}`,
        {
          method: 'POST',
          body: JSON.stringify({
            ...mappings(),
            ...(activeContext ? { __mxrb_context: activeContext } : {}),
          }),
        },
      ).then((payload) => payload.context || payload.result || null);
    } else if (source.kind === 'nanoflow' && source.name) {
      pending = invokeNanoflow(source.name, mappings(), activeContext);
    } else if (source.kind === 'association') {
      if ((source.steps?.length || 0) > 1) {
        setLoading(false);
        setRecord(null);
        setUnsupported('multi-step association sources require a traversal adapter');
        return () => {
          current = false;
        };
      }
      const step = source.steps?.at(-1);
      const entity = source.entity || step?.entity;
      if (!entity) {
        setLoading(false);
        setRecord(null);
        setUnsupported('association source has no destination entity');
        return () => {
          current = false;
        };
      }
      pending = request<EntityCollectionResponse>(
        entityCollectionPath(entity, step?.association, activeContext),
      ).then((payload) => payload.records?.[0] || null);
    } else {
      setLoading(false);
      setRecord(null);
      setUnsupported(`unsupported data view source ${source.kind}`);
      return () => {
        current = false;
      };
    }

    pending
      .then(accept)
      .catch((failure) => {
        if (current) onError(failure);
      })
      .finally(() => {
        if (current) setLoading(false);
      });
    return () => {
      current = false;
    };
  }, [
    source,
    inheritedContext?.type,
    inheritedContext?.id,
    sourceRevision,
    invokeNanoflow,
    request,
    onError,
  ]);

  const resolvedRecord = !source || source.kind === 'context' ? inheritedContext : record;

  const render = (widgets: WidgetDefinition[] | undefined, region: string) =>
    (widgets || []).map((child, index) => (
      <WidgetRenderer
        key={`${region}-${child.name}-${index}`}
        widget={child}
        moduleName={moduleName}
        invoke={invoke}
        invokeNanoflow={invokeNanoflow}
        navigate={navigate}
        context={resolvedRecord}
        pageContext={pageContext}
        revision={revision}
        schema={schema}
        request={request}
        saveRecord={saveRecord}
        onError={onError}
        onMutation={onMutation}
        onSelectRecord={onSelectRecord}
      />
    ));

  if (unsupported)
    return (
      <div className="mxrb-data-view mxrb-data-view--unsupported" role="alert">
        Could not resolve data view {widget.name}: {unsupported}
      </div>
    );
  if (loading)
    return (
      <div className="mxrb-data-view mxrb-data-view--loading" aria-busy="true">
        Loading…
      </div>
    );
  if (!resolvedRecord)
    return (
      <div className="mxrb-data-view mxrb-data-view--empty">
        {String(options.no_entity_message || '')}
      </div>
    );

  return (
    <section
      className={classes('app-widget', 'mxrb-widget', 'mxrb-data-view', options.class)}
      data-widget-name={widget.name}
      data-widget-type={widget.type}
      data-editability={String(options.editable || 'always')}
    >
      <div className="mxrb-data-view__body" data-widget-region="body">
        {render(widget.body, 'body')}
      </div>
      {options.show_footer !== false && (widget.footer || []).length > 0 && (
        <footer className="mxrb-data-view__footer" data-widget-region="footer">
          {render(widget.footer, 'footer')}
        </footer>
      )}
    </section>
  );
}

export function WidgetRenderer({
  widget,
  children: compiledChildren,
  moduleName,
  invoke,
  invokeNanoflow,
  navigate,
  context,
  pageContext,
  revision,
  schema,
  request,
  saveRecord,
  onError,
  onMutation,
  onSelectRecord,
}: WidgetRuntimeProps) {
  const options = widget.options || {};
  if (!isVisible(options.visible, context || pageContext)) return null;
  const className = classes(
    'app-widget',
    `app-widget--${widget.type}`,
    `mxrb-widget`,
    `mxrb-${widget.type}`,
    `mx-name-${widget.name}`,
    options.class,
    dynamicClass(options.dynamic_class, context || pageContext),
  );
  const runtimeProps = {
    'data-widget-name': widget.name,
    'data-widget-type': widget.type,
  };
  const children =
    compiledChildren ??
    (widget.children || []).map((child, index) => (
      <WidgetRenderer
        key={`${child.name}-${index}`}
        widget={child}
        moduleName={moduleName}
        invoke={invoke}
        invokeNanoflow={invokeNanoflow}
        navigate={navigate}
        context={context}
        pageContext={pageContext}
        revision={revision}
        schema={schema}
        request={request}
        saveRecord={saveRecord}
        onError={onError}
        onMutation={onMutation}
        onSelectRecord={onSelectRecord}
      />
    ));
  const click = (widget.events || []).find((event) => event.event === 'on_click');
  const change = (widget.events || []).find((event) => event.event === 'on_change');
  const runEvent = (
    event: WidgetEvent | undefined,
    eventContext: EntityRecord | null = context || pageContext,
  ): Promise<unknown> => {
    if (!event) return Promise.resolve();
    const handler = event.handler.includes('.') ? event.handler : `${moduleName}.${event.handler}`;
    let parameters: RuntimeVariables;
    try {
      parameters = eventArguments(event, eventContext, {
        pageParameter: pageContext,
        widgetValues: { [widget.name]: eventContext },
      });
    } catch (failure) {
      onError(failure);
      return Promise.resolve();
    }
    if (event.kind === 'nanoflow') return invokeNanoflow(handler, parameters, eventContext);
    if (event.kind === 'page') {
      const candidate = Object.values(parameters)[0];
      const targetContext = isEntityRecord(candidate) ? candidate : pageContext || context || null;
      return navigate(handler, targetContext);
    }
    return invoke(handler, parameters, eventContext);
  };
  const onClick = click ? () => runEvent(click) : undefined;
  const onChanged = (updated: EntityRecord) => runEvent(change, updated);
  const activeRecord = context || pageContext;
  const label = caption(widget, options, activeRecord);
  const renderWidgets = (widgets: WidgetDefinition[] | undefined, region: string) =>
    (widgets || []).map((child, index) => (
      <WidgetRenderer
        key={`${region}-${child.name}-${index}`}
        widget={child}
        moduleName={moduleName}
        invoke={invoke}
        invokeNanoflow={invokeNanoflow}
        navigate={navigate}
        context={context}
        pageContext={pageContext}
        revision={revision}
        schema={schema}
        request={request}
        saveRecord={saveRecord}
        onError={onError}
        onMutation={onMutation}
        onSelectRecord={onSelectRecord}
      />
    ));
  const namedRegions = Object.entries(widget.regions || {}).map(([name, widgets]) => (
    <div key={name} className="mxrb-widget-region" data-widget-region={name}>
      {renderWidgets(widgets, name)}
    </div>
  ));
  const slotRegions = (widget.slots || []).map((slot, index) => {
    const path = slot.path.map(String).join('.');
    return (
      <div key={`${path}-${index}`} className="mxrb-widget-slot" data-widget-slot={path}>
        {renderWidgets(slot.widgets, `slot-${path}`)}
      </div>
    );
  });
  const marketplaceRegions: MarketplaceWidgetRegion[] = [
    ...Object.entries(widget.regions || {}).map(([name, widgets]) => ({
      path: [name],
      role: name,
      content: renderWidgets(widgets, `marketplace-region-${name}`),
    })),
    ...(widget.slots || []).map((slot, index) => {
      const role =
        slot.role ||
        [...slot.path].reverse().find((part): part is string => typeof part === 'string') ||
        `slot-${index}`;
      const path = slot.path.map(String).join('.');
      return {
        path: slot.path,
        role,
        content: renderWidgets(slot.widgets, `marketplace-slot-${path}`),
      };
    }),
  ];

  switch (widget.type) {
    case 'container':
      return (
        <div
          {...runtimeProps}
          className={className}
          style={inlineStyle(options.style)}
          onClick={onClick}
          role={onClick ? 'button' : undefined}
          tabIndex={onClick ? 0 : undefined}
        >
          {children}
          {namedRegions}
          {slotRegions}
        </div>
      );
    case 'data_view':
      return (
        <DataView
          widget={widget}
          moduleName={moduleName}
          invoke={invoke}
          invokeNanoflow={invokeNanoflow}
          navigate={navigate}
          context={context}
          pageContext={pageContext}
          revision={revision}
          schema={schema}
          request={request}
          saveRecord={saveRecord}
          onError={onError}
          onMutation={onMutation}
          onSelectRecord={onSelectRecord}
        />
      );
    case 'table': {
      const rows = structuralRows<TableRowNode>(options.rows);
      const columns = structuralRows<{ width?: number }>(options.columns);
      const totalWeight = columns.reduce((total, column) => total + Number(column.width || 0), 0);
      return (
        <table
          {...runtimeProps}
          className={classes(className, 'mxrb-table')}
          style={inlineStyle(options.style)}
        >
          {columns.length > 0 && (
            <colgroup>
              {columns.map((column, index) => (
                <col
                  key={index}
                  style={{
                    width: tableColumnWidth(column.width, options.width_unit, totalWeight),
                  }}
                />
              ))}
            </colgroup>
          )}
          <tbody>
            {rows.map((row, rowIndex) =>
              !isVisible(row.options?.visible, activeRecord) ? null : (
              <tr
                key={rowIndex}
                className={classes(
                  'mxrb-table__row',
                  row.options?.class,
                  dynamicClass(row.options?.dynamic_class, activeRecord),
                )}
                style={inlineStyle(row.options?.style)}
              >
                {(row.cells || []).map((cell, cellIndex) => {
                  if (!isVisible(cell.options?.visible, activeRecord)) return null;
                  const Cell = cell.header ? 'th' : 'td';
                  return (
                    <Cell
                      key={`${cell.column ?? cellIndex}-${cellIndex}`}
                      className={classes(
                        'mxrb-table__cell',
                        cell.options?.class,
                        dynamicClass(cell.options?.dynamic_class, activeRecord),
                      )}
                      style={inlineStyle(cell.options?.style)}
                      colSpan={cell.colspan || 1}
                      rowSpan={cell.rowspan || 1}
                    >
                      {renderWidgets(cell.widgets, `row-${rowIndex}-cell-${cellIndex}`)}
                    </Cell>
                  );
                })}
              </tr>
              ),
            )}
          </tbody>
        </table>
      );
    }
    case 'layout_grid': {
      const rows = structuralRows<LayoutRowNode>(options.rows);
      return (
        <div
          {...runtimeProps}
          className={classes(className, 'mxrb-layout-grid')}
          style={inlineStyle(options.style)}
        >
          {rows.map((row, rowIndex) =>
            !isVisible(row.options?.visible, activeRecord) ? null : (
            <div
              key={rowIndex}
              className={classes(
                'mxrb-layout-grid__row',
                row.options?.class,
                dynamicClass(row.options?.dynamic_class, activeRecord),
              )}
              style={{
                ...inlineStyle(row.options?.style),
                display: 'flex',
                gap: row.options?.gutters === false ? 0 : undefined,
              }}
            >
              {(row.columns || []).map((column, columnIndex) =>
                !isVisible(column.options?.visible, activeRecord) ? null : (
                <div
                  key={columnIndex}
                  className={classes(
                    'mxrb-layout-grid__column',
                    column.options?.class,
                    dynamicClass(column.options?.dynamic_class, activeRecord),
                  )}
                  style={{
                    ...inlineStyle(column.options?.style),
                    ...layoutColumnStyle(column.options || {}),
                  }}
                  data-desktop-width={String(column.options?.desktop ?? 'grow')}
                  data-tablet-width={String(column.options?.tablet ?? 'grow')}
                  data-phone-width={String(column.options?.phone ?? 'grow')}
                >
                  {renderWidgets(column.widgets, `row-${rowIndex}-column-${columnIndex}`)}
                </div>
                ),
              )}
            </div>
            ),
          )}
        </div>
      );
    }
    case 'text':
      return (
        <span {...runtimeProps} className={className}>
          {label}
        </span>
      );
    case 'button':
      return (
        <button {...runtimeProps} type="button" className={className} onClick={onClick}>
          {label}
        </button>
      );
    case 'check_box':
      return (
        <label {...runtimeProps} className={className}>
          <BoundField
            widget={widget}
            record={activeRecord}
            schema={schema}
            request={request}
            saveRecord={saveRecord}
            revision={revision}
            onChanged={onChanged}
            onError={onError}
          />
          {label}
        </label>
      );
    case 'text_area':
    case 'text_box':
    case 'number_input':
    case 'date_picker':
    case 'drop_down':
    case 'reference_selector':
      return (
        <label {...runtimeProps} className={className}>
          {label}
          <BoundField
            widget={widget}
            record={activeRecord}
            schema={schema}
            request={request}
            saveRecord={saveRecord}
            revision={revision}
            onChanged={onChanged}
            onError={onError}
          />
        </label>
      );
    case 'tab_control':
      return (
        <div {...runtimeProps} className={className}>
          {(options.tabs || []).map((tab) => (
            <section key={tab.name}>
              <h3>{tab.caption || tab.name}</h3>
              {(tab.widgets || []).map((child, index) => (
                <WidgetRenderer
                  key={`${child.name}-${index}`}
                  widget={child}
                  moduleName={moduleName}
                  invoke={invoke}
                  invokeNanoflow={invokeNanoflow}
                  navigate={navigate}
                  context={context}
                  pageContext={pageContext}
                  revision={revision}
                  schema={schema}
                  request={request}
                  saveRecord={saveRecord}
                  onError={onError}
                  onMutation={onMutation}
                  onSelectRecord={onSelectRecord}
                />
              ))}
            </section>
          ))}
        </div>
      );
    case 'data_grid':
      return (
        <div {...runtimeProps} className={className}>
          <DataGrid
            widget={widget}
            request={request}
            pageContext={pageContext}
            revision={revision}
            onError={onError}
            onMutation={onMutation}
            onSelectRecord={onSelectRecord}
            onRowAction={(record) => runEvent(change || click, record)}
          />
        </div>
      );
    case 'gallery':
      return (
        <Gallery
          widget={widget}
          moduleName={moduleName}
          invoke={invoke}
          invokeNanoflow={invokeNanoflow}
          navigate={navigate}
          pageContext={pageContext}
          revision={revision}
          schema={schema}
          request={request}
          saveRecord={saveRecord}
          onError={onError}
          onMutation={onMutation}
          onSelectRecord={onSelectRecord}
        />
      );
    case 'pluggable_widget':
      return (
        <div
          {...runtimeProps}
          className={classes(className, 'marketplace-widget', 'mxrb-marketplace-widget')}
          data-widget-id={options.widget_id || ''}
        >
          <MarketplaceWidget
            widget={widget}
            context={activeRecord}
            regions={marketplaceRegions}
            onChange={(attribute, value) => {
              const member = memberName(attribute);
              if (!activeRecord || !member) return Promise.resolve(activeRecord);
              return saveRecord(activeRecord, { [member]: value }).then((updated) => {
                if (updated) return onChanged(updated);
                return updated;
              });
            }}
          >
            {children}
          </MarketplaceWidget>
        </div>
      );
    case 'native_widget':
      return (
        <div
          {...runtimeProps}
          className={classes(className, 'native-widget', 'mxrb-native-widget')}
          data-native-type={options.native_type || ''}
          role="alert"
        >
          Could not render widget {widget.name}: unsupported native type{' '}
          {options.native_type || 'unknown'}
        </div>
      );
    default:
      return (
        <div {...runtimeProps} className={className} role="alert">
          Could not render widget {widget.name}: unsupported type {widget.type}
          {children}
          {renderWidgets(widget.body, 'body')}
          {renderWidgets(widget.footer, 'footer')}
          {namedRegions}
          {slotRegions}
        </div>
      );
  }
}
