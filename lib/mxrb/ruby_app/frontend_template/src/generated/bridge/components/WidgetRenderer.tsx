import {
  useContext,
  useEffect,
  useId,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from 'react';
import { useWidgetEvent } from '../useWidgetEvent';
import { ClientActions } from '../PageEdits';
import { SidebarToggle } from './NativeScrollContainer';
import { VariableScope } from './VariableScope';
import { PageParameters, LocalVariables } from '../PageVariables';
import { DataGrid } from './DataGrid';
import { BoundField } from './BoundField';
import { TabControl } from './TabControl';
import { SharedPresentation, ScrollContainer, ReferenceSetSelector } from './PresentationWidgets';
import { FileWidget } from './FileWidget';
import { PageTitleContext } from './PageTitleContext';
import { editable, matchesCondition, ReadOnlyContext, ReadOnlyStyleContext } from './FieldPolicy';
import { useSelections } from './SelectionScope';
import { MarketplaceWidget, type MarketplaceWidgetRegion } from '../marketplace';
import type {
  EntityCollectionResponse,
  DataViewSource,
  EntityRecord,
  InvocationResult,
  RuntimeValue,
  RuntimeVariables,
  WidgetDefinition,
  WidgetOptions,
} from '../../types';
import type { WidgetRuntimeProps } from '../contracts';
import {
  caption,
  classes,
  dynamicClass,
  entityCollectionPath,
  eventArguments,
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

const gridAlignment = (alignment: unknown) =>
  alignment === 'center'
    ? 'center'
    : alignment === 'start'
      ? 'flex-start'
      : alignment === 'end'
        ? 'flex-end'
        : undefined;

const layoutColumnStyle = (options: WidgetOptions): CSSProperties => {
  const flex = (width: unknown) => {
    if (width === 'auto') return '0 0 auto';
    const columns = Number(width);
    return Number.isFinite(columns) && columns > 0 && columns <= 12
      ? `0 0 ${(columns / 12) * 100}%`
      : '1 1 0';
  };
  return {
    alignSelf: gridAlignment(options.vertical_alignment),
    '--mxrb-desktop-flex': flex(options.desktop),
    '--mxrb-tablet-flex': flex(options.tablet ?? options.desktop),
    '--mxrb-phone-flex': flex(options.phone ?? options.tablet ?? options.desktop),
  } as CSSProperties;
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

export function DataView({
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
  renderRecord,
}: WidgetRuntimeProps & { renderRecord?: (record: EntityRecord | null) => ReactNode }) {
  const options = widget.options || {};
  const source = options.source as DataViewSource | undefined;
  const inheritedReadOnly = useContext(ReadOnlyContext);
  const inheritedReadOnlyStyle = useContext(ReadOnlyStyleContext);
  const selections = useSelections();
  const variables = useContext(VariableScope);
  const pageParameters = useContext(PageParameters);
  const localVariables = useContext(LocalVariables);
  const listenTarget = source?.target?.split('.').at(-1) || '';
  const variable = source?.variable as { kind?: string; name?: string } | undefined;
  const namedRecord =
    variable?.kind === 'page_parameter'
      ? pageParameters[memberName(variable.name || '')]
      : variables[memberName(variable?.name || '')];
  const inheritedContext =
    variable &&
    ['snippet_parameter', 'page_parameter', 'local_variable'].includes(variable.kind || '')
      ? isEntityRecord(namedRecord)
        ? namedRecord
        : null
      : context || pageContext;
  const [record, setRecord] = useState<EntityRecord | null>(inheritedContext);
  const [loading, setLoading] = useState(false);
  const [unsupported, setUnsupported] = useState<string | null>(null);
  const contextRef = useRef(inheritedContext);
  contextRef.current = inheritedContext;
  const nanoflowRef = useRef(invokeNanoflow);
  nanoflowRef.current = invokeNanoflow;
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
          const parameter =
            String(mapping.parameter || '')
              .split('.')
              .pop() || '';
          return [
            parameter,
            eventArguments(
              {
                event: 'source',
                kind: 'source',
                handler: '',
                arguments: {
                  value: (mapping.variable || String(mapping.expression || '')) as RuntimeValue,
                },
              },
              activeContext,
              {
                pageParameter: pageContext,
                pageParameters,
                localVariables: localVariables.values,
                snippetParameters: variables,
                widgetValues: { ...selections.records, ...selections.lists },
              },
            ).value,
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
      return () => {
        current = false;
      };
    }

    setLoading(true);
    let pending: Promise<unknown>;
    if (source.kind === 'microflow' && source.name) {
      pending = request<InvocationResult>(`/api/microflows/${encodeURIComponent(source.name)}`, {
        method: 'POST',
        body: JSON.stringify({
          ...mappings(),
          ...(activeContext ? { __mxrb_context: activeContext } : {}),
        }),
      }).then((payload) => payload.context || payload.result || null);
    } else if (source.kind === 'nanoflow' && source.name) {
      pending = nanoflowRef.current(source.name, mappings(), activeContext);
    } else if (source.kind === 'association') {
      const steps = source.steps || [];
      if (!steps.length || steps.some((step) => !step.entity || !step.association)) {
        setLoading(false);
        setRecord(null);
        setUnsupported(
          'association source must declare its association and destination at each step',
        );
        return () => {
          current = false;
        };
      }
      pending = (async () => {
        let candidate = activeContext;
        for (const step of steps) {
          // Never turn an empty association into an unscoped entity query.
          if (!candidate || !current) return null;
          const payload = await request<EntityCollectionResponse>(
            entityCollectionPath(step.entity!, step.association, candidate),
          );
          candidate = payload.records?.[0] || null;
        }
        return candidate;
      })();
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
    request,
    onError,
    variables,
  ]);

  const resolvedRecord =
    source?.kind === 'listen'
      ? selections.records[listenTarget] || null
      : !source || source.kind === 'context'
        ? inheritedContext
        : record;
  const saveResolvedRecord: typeof saveRecord = async (current, changes) => {
    const updated = await saveRecord(current, changes);
    if (updated) setRecord((previous) => (previous?.id === updated.id ? updated : previous));
    if (updated && source?.kind === 'listen') selections.select(listenTarget, updated);
    return updated;
  };

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
        saveRecord={saveResolvedRecord}
        onError={onError}
        onMutation={onMutation}
        onSelectRecord={onSelectRecord}
      />
    ));

  if (options.visibility && !matchesCondition(options.visibility, resolvedRecord, schema.module_roles)) return null;
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
  if (renderRecord) return renderRecord(resolvedRecord);
  if (!resolvedRecord)
    return (
      <div className="mxrb-data-view mxrb-data-view--empty">
        {String(options.no_entity_message || '')}
      </div>
    );

  return (
    <ReadOnlyContext.Provider value={inheritedReadOnly || !editable(options, resolvedRecord, schema.module_roles)}>
      <ReadOnlyStyleContext.Provider
        value={
          options.read_only_style === 'text' || options.read_only_style === 'control'
            ? options.read_only_style
            : inheritedReadOnlyStyle
        }
      >
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
      </ReadOnlyStyleContext.Provider>
    </ReadOnlyContext.Provider>
  );
}

export function WidgetRenderer(props: WidgetRuntimeProps) {
  const execution = useWidgetEvent(props);
  return (
    <>
      {execution.feedback}
      <WidgetContent {...props} execution={execution} />
    </>
  );
}

function WidgetContent({
  execution,
  widget,
  children: compiledChildren,
  moduleName,
  invoke,
  invokeNanoflow,
  navigate,
  context: suppliedContext,
  pageContext: suppliedPageContext,
  revision,
  schema,
  request,
  saveRecord,
  onError,
  onMutation,
  onSelectRecord,
}: WidgetRuntimeProps & { execution: ReturnType<typeof useWidgetEvent> }) {
  const { runEvent, running } = execution;
  const fieldId = useId();
  const actions = useContext(ClientActions);
  const context = actions ? actions.edits.resolve(suppliedContext) : suppliedContext;
  const pageContext = actions ? actions.edits.resolve(suppliedPageContext) : suppliedPageContext;
  const selections = useSelections();
  const variables = useContext(VariableScope);
  const pageTitle = useContext(PageTitleContext);
  const options = widget.options || {};
  if (!isVisible(options.visible, context || pageContext)) return null;
  if (widget.type !== 'data_view' && options.visibility &&
      !matchesCondition(options.visibility, context || pageContext, schema.module_roles)) return null;
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
  const enter = (widget.events || []).find((event) => event.event === 'on_enter');
  const leave = (widget.events || []).find((event) => event.event === 'on_leave');
  const onClick = click ? () => runEvent(click) : undefined;
  const onChanged = (updated: EntityRecord | null) => runEvent(change, updated);
  const onEntered = (record: EntityRecord | null) => runEvent(enter, record);
  const onLeft = (record: EntityRecord | null) => runEvent(leave, record);
  const activeRecord = context || pageContext;
  const sharedProps = {
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
  };
  const label = caption(widget, options, activeRecord, variables);
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
    case 'file_manager':
    case 'image_uploader':
    case 'image_viewer':
      return <FileWidget {...sharedProps} />;
    case 'snippet':
    case 'static_image':
    case 'menu_bar':
    case 'navigation_tree':
      return <SharedPresentation {...sharedProps} />;
    case 'sidebar_toggle':
      return <SidebarToggle {...sharedProps} />;
    case 'scroll_container':
      return <ScrollContainer {...sharedProps} />;
    case 'reference_set_selector':
      return <ReferenceSetSelector {...sharedProps} onChanged={onChanged} />;
    case 'navigation_list':
      return (
        <nav {...runtimeProps} className={className} aria-label={widget.name}>
          {children}
        </nav>
      );
    case 'container':
      return (
        <div
          {...runtimeProps}
          className={className}
          style={inlineStyle(options.style)}
          onClick={onClick}
          onKeyDown={
            onClick
              ? (event) => {
                  if (
                    event.target === event.currentTarget &&
                    (event.key === 'Enter' || event.key === ' ')
                  ) {
                    event.preventDefault();
                    void onClick();
                  }
                }
              : undefined
          }
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
                  flexWrap: 'wrap',
                  justifyContent: gridAlignment(row.options?.horizontal_alignment),
                  alignItems: gridAlignment(row.options?.vertical_alignment),
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
        <span
          {...runtimeProps}
          className={classes('mx-text', className)}
          style={inlineStyle(options.style)}
        >
          {label}
        </span>
      );
    case 'page_title':
      return (
        <h1 {...runtimeProps} className={className} style={inlineStyle(options.style)}>
          {pageTitle}
        </h1>
      );
    case 'button':
      return (
        <button
          {...runtimeProps}
          type="button"
          className={classes(
            className,
            'btn mx-button',
            `btn-${String(options.button_style || 'default')}`,
          )}
          onClick={onClick}
          disabled={running && click?.settings?.disabled_during_execution !== false}
          aria-busy={running || undefined}
        >
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
            onEntered={onEntered}
            onLeft={onLeft}
            onError={onError}
          />
          {label}
        </label>
      );
    case 'radio_button_group':
      return (
        <fieldset {...runtimeProps} className={className} style={inlineStyle(options.style)}>
          <legend>{label}</legend>
          <BoundField
            widget={widget}
            record={activeRecord}
            schema={schema}
            request={request}
            saveRecord={saveRecord}
            revision={revision}
            onChanged={onChanged}
            onEntered={onEntered}
            onLeft={onLeft}
            onError={onError}
          />
        </fieldset>
      );
    case 'text_area':
    case 'text_box':
    case 'number_input':
    case 'date_picker':
    case 'drop_down':
    case 'reference_selector':
      return (
        <div
          {...runtimeProps}
          className={classes(
            className,
            'form-group no-columns',
            `mx-${widget.type === 'text_box' || widget.type === 'number_input' ? 'textbox' : widget.type.replaceAll('_', '')}`,
          )}
        >
          <label className="control-label" htmlFor={fieldId}>
            {label}
          </label>
          <BoundField
            id={fieldId}
            widget={widget}
            record={activeRecord}
            schema={schema}
            request={request}
            saveRecord={saveRecord}
            revision={revision}
            onChanged={onChanged}
            onEntered={onEntered}
            onLeft={onLeft}
            onError={onError}
          />
        </div>
      );
    case 'tab_control':
      return (
        <div {...runtimeProps} className={className}>
          <TabControl
            tabs={options.tabs || []}
            label={label}
            renderPanel={(tab) => renderWidgets(tab.widgets, `tab-${tab.name}`)}
          />
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
            onSelectRecords={(records) => {
              selections.selectMany(widget.name, records);
              onSelectRecord(records[0] || null);
            }}
            onSelectRecord={(record) => {
              selections.select(widget.name, record);
              onSelectRecord(record);
            }}
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
            schema={schema}
            request={request}
            revision={revision}
            onClick={onClick}
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
