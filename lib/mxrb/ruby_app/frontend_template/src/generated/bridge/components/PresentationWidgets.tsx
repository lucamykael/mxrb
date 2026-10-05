import { createContext, useContext, useEffect, useId, useRef, useState } from 'react';
import type { CSSProperties, ReactNode } from 'react';
import type {
  EntityCollectionResponse,
  EntityRecord,
  PresentationMenuItem,
  PresentationResource,
  NavigationItem,
  RuntimeVariables,
} from '../../types';
import type { WidgetRuntimeProps } from '../contracts';
import { editable, ReadOnlyContext } from './FieldPolicy';
import { WidgetRenderer } from './WidgetRenderer';
import { NativeScrollContainer } from './NativeScrollContainer';
import { PageNameContext, NavigationSelection } from './PageTitleContext';
import { ClientActions } from '../PageEdits';
import { useWidgetEvent } from '../useWidgetEvent';
import { VariableScope } from './VariableScope';
import {
  PageParameters,
  LocalVariables,
  VariableEnvironment,
  resolveParameters,
} from '../PageVariables';
import {
  classes,
  displayValue,
  dynamicClass,
  inlineStyle,
  memberName,
  recordValue,
  eventArguments,
  entityCollectionPath,
  isEntityRecord,
} from '../value';

const SnippetStack = createContext<string[]>([]);

export const presentationFrame = ({ widget, context, pageContext }: WidgetRuntimeProps) => ({
  'data-widget-name': widget.name,
  'data-widget-type': widget.type,
  className: classes(
    'mxrb-widget',
    `mxrb-${widget.type}`,
    `mx-name-${widget.name}`,
    widget.options?.class,
    dynamicClass(widget.options?.dynamic_class, context || pageContext),
  ),
  style: inlineStyle(widget.options?.style),
});

export function SharedPresentation(props: WidgetRuntimeProps) {
  const { widget, schema } = props;
  const options = widget.options || {};
  const stack = useContext(SnippetStack);
  const inheritedVariables = useContext(VariableScope);
  const pageParameters = useContext(PageParameters);
  const localVariables = useContext(LocalVariables);
  const name = String(options.snippet || options.menu || options.image || '');
  const profile = options.navigation_profile
    ? schema.navigation?.profiles?.find(
        (entry) =>
          entry.kind === options.navigation_profile || entry.name === options.navigation_profile,
      )
    : undefined;
  const convert = (entries: NavigationItem[]): PresentationMenuItem[] =>
    entries.map((entry) => ({
      caption: entry.caption?.en_US || entry.page || '',
      caption_translations: entry.caption,
      page: entry.page,
      icon: entry.icon,
      items: convert(entry.items || []),
    }));
  const resource: PresentationResource | undefined = profile
    ? { kind: 'menu', items: convert(profile.items || []) }
    : schema.presentation?.[name];
  const frame = presentationFrame(props);
  if (!resource)
    return (
      <div {...frame} role="alert">
        Missing presentation resource: {name}
      </div>
    );
  if (widget.type === 'snippet') {
    if (resource.kind !== 'snippet' || stack.includes(name) || stack.length >= 32)
      return (
        <div {...frame} role="alert">
          Invalid or recursive snippet: {name}
        </div>
      );
    let variables: RuntimeVariables;
    try {
      variables = eventArguments(
        {
          event: 'snippet',
          kind: 'snippet',
          handler: name,
          arguments: options.arguments as RuntimeVariables,
        },
        props.context || props.pageContext,
        {
          pageParameter: props.pageContext,
          pageParameters,
          localVariables: localVariables.values,
          snippetParameters: inheritedVariables,
        },
      );
      variables = resolveParameters(
        resource.parameters,
        variables,
        props.context || props.pageContext,
        schema,
      );
    } catch (failure) {
      return (
        <div {...frame} role="alert">
          {String(failure)}
        </div>
      );
    }
    return (
      <SnippetStack.Provider value={[...stack, name]}>
        <VariableEnvironment
          scope="snippet"
          parameters={variables}
          parameterDefinitions={resource.parameters}
          definitions={resource.variables}
          context={props.context || props.pageContext}
          schema={schema}
        >
          <div {...frame}>
            {resource.widgets?.map((child, index) => (
              <WidgetRenderer {...props} key={`${child.name}-${index}`} widget={child} />
            ))}
          </div>
        </VariableEnvironment>
      </SnippetStack.Provider>
    );
  }
  if (widget.type === 'static_image') {
    if (resource.kind !== 'image') return <div role="alert">Invalid image: {name}</div>;
    const size = (dimension: 'width' | 'height'): string | undefined => {
      const value = Number(options[dimension]);
      if (!(value > 0) || options[`${dimension}_unit`] === 'auto') return;
      return `${value}${options[`${dimension}_unit`] === 'percentage' ? '%' : 'px'}`;
    };
    return (
      <img
        {...frame}
        src={resource.path}
        alt={String(options.alternative_text || '')}
        style={{
          width: size('width'),
          height: size('height'),
          maxWidth: options.responsive ? '100%' : undefined,
          ...frame.style,
        }}
      />
    );
  }
  if (resource.kind !== 'menu') return <div role="alert">Invalid menu: {name}</div>;
  const itemCaption = (item: PresentationMenuItem) => {
    const locale = String(
      options.locale || document.documentElement.lang || navigator.language,
    ).replace('-', '_');
    return item.caption_translations?.[locale] || item.caption;
  };
  const itemLabel = (item: PresentationMenuItem) => (
    <>
      {item.icon && (
        <>
          <span
            aria-hidden="true"
            className={typeof item.icon === 'number' ? 'glyphicon' : `mxrb-menu-icon ${item.icon}`}
          >
            {typeof item.icon === 'number'
              ? String.fromCodePoint(item.icon)
              : item.icon.startsWith('glyphicon')
                ? ''
                : item.icon}
          </span>{' '}
        </>
      )}
      {itemCaption(item)}
    </>
  );
  const items = (entries: PresentationMenuItem[], depth = 0) => (
    <ul
      style={
        widget.type === 'menu_bar' && depth === 0
          ? { display: 'flex', gap: '1rem', listStyle: 'none' }
          : undefined
      }
    >
      {entries.map((item, index) => (
        <li key={`${depth}-${index}`}>
          {item.page || item.microflow || item.action ? (
            <MenuAction props={props} item={item} link={!!profile}>
              {itemLabel(item)}
            </MenuAction>
          ) : item.items?.length ? null : (
            <span>{itemLabel(item)}</span>
          )}
          {!!item.items?.length && (
            <details>
              <summary>{itemLabel(item)}</summary>
              {items(item.items, depth + 1)}
            </details>
          )}
        </li>
      ))}
    </ul>
  );
  return (
    <nav
      {...frame}
      className={classes(
        frame.className,
        widget.type === 'navigation_tree' ? 'mx-navigationtree' : 'mx-navbar',
      )}
      aria-label={widget.name}
    >
      <div className="navbar-inner">{items(resource.items || [])}</div>
    </nav>
  );
}

function MenuAction({
  props,
  item,
  link,
  children,
}: {
  props: WidgetRuntimeProps;
  item: PresentationMenuItem;
  link: boolean;
  children: ReactNode;
}) {
  const execution = useWidgetEvent(props);
  const selected = useContext(NavigationSelection);
  const currentPage = useContext(PageNameContext);
  const menuKey = String(
    props.widget.options?.navigation_profile || props.widget.options?.menu || props.widget.name,
  );
  const page = item.page || (item.action?.kind === 'page' ? item.action.handler : undefined);
  const action = item.action || {
    event: 'on_click',
    kind: item.page ? 'page' : 'microflow',
    handler: item.page || item.microflow!,
  };
  const disabled = execution.running && action.settings?.disabled_during_execution !== false;
  const Button = link ? 'a' : 'button';
  return (
    <>
      {execution.feedback}
      <Button
        className={
          page && page === currentPage && selected?.get(menuKey) === page ? 'active' : undefined
        }
        href={link ? '#' : undefined}
        type={link ? undefined : 'button'}
        disabled={link ? undefined : disabled}
        aria-disabled={disabled || undefined}
        aria-busy={execution.running || undefined}
        onClick={(event) => {
          event.preventDefault();
          if (page) selected?.set(menuKey, page);
          void execution.runEvent(action);
        }}
      >
        {children}
      </Button>
    </>
  );
}

export function ScrollContainer(props: WidgetRuntimeProps) {
  return props.widget.options?.native_layout ? (
    <NativeScrollContainer {...props} />
  ) : (
    <LegacyScrollContainer {...props} />
  );
}

function LegacyScrollContainer(props: WidgetRuntimeProps) {
  const { widget } = props;
  const regions = widget.regions || {};
  const options = widget.options || {};
  const settings = (options.region_options || {}) as Record<
    string,
    {
      size?: number;
      size_mode?: string;
      toggle_mode?: string;
      class?: string;
      style?: string;
    }
  >;
  const [toggles, setToggles] = useState<Record<string, boolean>>({});
  const id = useId();
  const mode = (region: string) => settings[region]?.toggle_mode || 'none';
  const open = (region: string) =>
    toggles[region] ??
    !['shrink_content_initially_closed', 'push_content_aside', 'slide_over_content'].includes(
      mode(region),
    );
  const floating = (region: string) =>
    ['push_content_aside', 'slide_over_content'].includes(mode(region));
  const size = (region: string) =>
    settings[region]?.size_mode === 'auto' || !settings[region]?.size_mode
      ? 'auto'
      : `${Math.max(0, Number(settings[region]?.size || 0))}${settings[region]?.size_mode === 'percentage' ? '%' : 'px'}`;
  const track = (region: string) => (!open(region) || floating(region) ? '0px' : size(region));
  const shift = (region: string) =>
    mode(region) === 'push_content_aside' && open(region)
      ? size(region) === 'auto'
        ? '200px'
        : size(region)
      : '0px';
  const sidebar = options.layout_mode === 'sidebar';
  return (
    <div
      {...presentationFrame(props)}
      style={{
        width:
          options.width_mode === 'auto' || !options.width_mode
            ? undefined
            : `${Number(options.width || 0)}${options.width_mode === 'percentage' ? '%' : 'px'}`,
        marginLeft:
          options.alignment === 'right' || options.alignment === 'center' ? 'auto' : undefined,
        marginRight:
          options.alignment === 'left' || options.alignment === 'center' ? 'auto' : undefined,
        ...inlineStyle(options.style),
      }}
    >
      {Object.keys(regions)
        .filter((region) => mode(region) !== 'none')
        .map((region) => (
          <button
            key={region}
            type="button"
            aria-expanded={open(region)}
            aria-controls={`${id}-${region}`}
            onClick={() => setToggles((previous) => ({ ...previous, [region]: !open(region) }))}
          >
            Toggle {region}
          </button>
        ))}
      <div
        style={{
          display: 'grid',
          position: 'relative',
          minHeight: 0,
          gridTemplateColumns: `${track('left')} minmax(0, 1fr) ${track('right')}`,
          gridTemplateRows: `${track('top')} minmax(0, 1fr) ${track('bottom')}`,
          gridTemplateAreas: sidebar
            ? '"left top right" "left center right" "left bottom right"'
            : '"top top top" "left center right" "bottom bottom bottom"',
          overflow: widget.options?.scroll_behavior === 'per_region' ? undefined : 'auto',
        }}
      >
        {Object.entries(regions).map(([region, widgets]) => (
          <section
            key={region}
            id={`${id}-${region}`}
            hidden={!open(region)}
            className={settings[region]?.class}
            data-widget-region={region}
            style={
              {
                gridArea: region,
                minWidth: 0,
                minHeight: 0,
                overflow: widget.options?.scroll_behavior === 'per_region' ? 'auto' : undefined,
                scrollbarWidth: widget.options?.hide_scrollbars ? 'none' : undefined,
                ...(floating(region)
                  ? {
                      position: 'absolute',
                      zIndex: 1,
                      [region]: 0,
                      width: ['left', 'right'].includes(region) ? size(region) : '100%',
                      height: ['top', 'bottom'].includes(region) ? size(region) : '100%',
                    }
                  : {}),
                transform:
                  region === 'center'
                    ? `translate(calc(${shift('left')} - ${shift('right')}), calc(${shift('top')} - ${shift('bottom')}))`
                    : undefined,
                ...inlineStyle(settings[region]?.style),
              } as CSSProperties
            }
          >
            {widgets.map((child, index) => (
              <WidgetRenderer {...props} key={`${child.name}-${index}`} widget={child} />
            ))}
          </section>
        ))}
        {widget.children?.map((child, index) => (
          <WidgetRenderer {...props} key={index} widget={child} />
        ))}
      </div>
    </div>
  );
}

export function ReferenceSetSelector(
  props: WidgetRuntimeProps & { onChanged: (record: EntityRecord) => unknown },
) {
  const actions = useContext(ClientActions);
  const { widget, context, pageContext, request, revision, saveRecord, onError, onChanged } = props;
  const record = context || pageContext;
  const options = widget.options || {};
  const readOnly = useContext(ReadOnlyContext);
  const [choices, setChoices] = useState<EntityRecord[]>([]);
  const [busy, setBusy] = useState(false);
  const [current, setCurrent] = useState(record);
  const [failure, setFailure] = useState<string | null>(null);
  const generation = useRef(0);
  const association = memberName(options.association || options.attribute || '');
  const target = options.target_entity || options.entity;
  const path = options.association_path as
    Array<{ association: string; entity: string }> | undefined;
  const unsupported = Number(options.association_steps || 1) > 1 && !path?.length;
  const disabled =
    busy ||
    !record ||
    !current ||
    readOnly ||
    !editable(options, record, props.schema.module_roles) ||
    !association ||
    !target ||
    unsupported ||
    !!failure;
  useEffect(() => {
    let active = true;
    generation.current++;
    setChoices([]);
    setCurrent(null);
    setFailure(null);
    setBusy(false);
    if (target && !unsupported && record) {
      setBusy(true);
      void (async () => {
        let owner = record;
        for (const step of (path || []).slice(0, -1)) {
          if (!active) return;
          if (!step.entity || !step.association) throw new Error('Incomplete association path');
          const payload = await request<EntityCollectionResponse>(
            entityCollectionPath(step.entity, step.association, owner),
          );
          if (payload.records.length > 1)
            throw new Error('Selector owner path must resolve to one object');
          if (!payload.records.length) return;
          owner = payload.records[0];
        }
        const query = new URLSearchParams();
        if (options.selectable_xpath) {
          query.set('xpath', String(options.selectable_xpath));
          query.set('xpath_context_type', record.type);
          query.set('xpath_context_id', record.id);
        }
        const response = await request<EntityCollectionResponse>(
          `/api/entities/${encodeURIComponent(target)}${query.size ? `?${query}` : ''}`,
        );
        if (active) {
          setCurrent(actions?.edits.resolve(owner) || owner);
          setChoices(response.records);
        }
      })()
        .catch((error) => {
          if (active) {
            setFailure(String(error));
            onError(error);
          }
        })
        .finally(() => {
          if (active) setBusy(false);
        });
    }
    return () => {
      active = false;
    };
  }, [target, unsupported, request, revision, onError, record, path, options.selectable_xpath]);
  const selected =
    recordValue(current, association) || recordValue(current, memberName(association));
  const ids = new Set(
    Array.isArray(selected)
      ? selected.map((entry) =>
          typeof entry === 'object' && entry ? (entry as EntityRecord).id : String(entry),
        )
      : [],
  );
  return (
    <fieldset {...presentationFrame(props)} disabled={disabled}>
      <legend>{String(options.caption || widget.name)}</legend>
      {unsupported && (
        <div role="alert">
          This selector requires an implemented constraint or association path.
        </div>
      )}
      {failure && <div role="alert">{failure}</div>}
      {choices.map((choice) => (
        <label key={choice.id}>
          <input
            type="checkbox"
            checked={ids.has(choice.id)}
            onChange={(event) => {
              setBusy(true);
              const savingGeneration = generation.current;
              const existing = Array.isArray(selected) ? selected : [];
              const retained = existing.filter(
                (entry) => isEntityRecord(entry) && entry.id !== choice.id,
              );
              const values = event.target.checked ? [...retained, choice] : retained;
              void saveRecord(current, {
                [association]: values,
              })
                .then(async (updated) => {
                  if (updated && savingGeneration === generation.current) {
                    setCurrent(updated);
                    await onChanged(updated);
                  }
                })
                .catch((error) => {
                  if (savingGeneration === generation.current) onError(error);
                })
                .finally(() => {
                  if (savingGeneration === generation.current) setBusy(false);
                });
            }}
          />
          {displayValue(recordValue(choice, memberName(options.display_attribute || 'Name'))) ||
            choice.id}
        </label>
      ))}
    </fieldset>
  );
}
