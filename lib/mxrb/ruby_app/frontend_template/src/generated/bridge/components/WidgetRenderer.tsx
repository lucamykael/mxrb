import { useEffect, useState } from 'react';
import { DataGrid } from './DataGrid';
import { BoundField } from './BoundField';
import { MarketplaceWidget } from '../marketplace';
import type { EntityCollectionResponse, EntityRecord, WidgetEvent } from '../../types';
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
    const parameters = eventArguments(event, eventContext);
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
        </div>
      );
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
        </div>
      );
  }
}
