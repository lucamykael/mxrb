import { useEffect, useRef, useState } from 'react';
import type { EntityRecord, RuntimeValue } from '../../types';
import { chartCaption, useCaptionEnvironment } from '../captions';
import type { MarketplaceWidgetProps } from '../marketplace';
import { expressionValue, memberName } from '../value';
import { marketplaceAction } from './marketplaceData';

type Properties = Record<string, unknown>;

const propertiesOf = (props: MarketplaceWidgetProps) =>
  (props.widget.options?.properties || {}) as Properties;
const attributeOf = (value: unknown) => memberName(String(value || ''));
const read = (record: EntityRecord | null, attribute: unknown) =>
  record?.attributes[attributeOf(attribute)];
const numberOf = (value: unknown, fallback = 0) => {
  const number = Number(
    value && typeof value === 'object' && '__mxrb_decimal' in value
      ? (value as { __mxrb_decimal: string }).__mxrb_decimal
      : value,
  );
  return Number.isFinite(number) ? number : fallback;
};
const run = (props: MarketplaceWidgetProps, value: unknown) => {
  const action = marketplaceAction(value);
  return action ? props.onAction?.(action, props.context) : undefined;
};
// A delay or interval given as a number or as an expression (milliseconds).
const milliseconds = (properties: Properties, prefix: string, record: EntityRecord | null) =>
  properties[`${prefix}ParameterType`] === 'expression'
    ? numberOf(expressionValue(String(properties[`${prefix}Expression`] || '0'), record))
    : numberOf(properties[prefix]);

// Events: an action when the widget loads (delayed, optionally repeated) and an
// action when a watched attribute of the context object changes.
export function MarketplaceEvents(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const latest = useRef(props);
  latest.current = props;
  const watched = JSON.stringify(read(props.context, properties.onEventChangeAttribute) ?? null);
  const previous = useRef(watched);
  useEffect(() => {
    if (!properties.onComponentLoad) return;
    const delay = milliseconds(properties, 'componentLoadDelay', latest.current.context);
    const interval = milliseconds(
      properties,
      'componentLoadRepeatInterval',
      latest.current.context,
    );
    let repeat: number | undefined;
    const timer = window.setTimeout(() => {
      run(latest.current, properties.onComponentLoad);
      if (properties.componentLoadRepeat === true && interval > 0)
        repeat = window.setInterval(
          () => run(latest.current, properties.onComponentLoad),
          interval,
        );
    }, delay);
    return () => {
      window.clearTimeout(timer);
      if (repeat !== undefined) window.clearInterval(repeat);
    };
    // The load action belongs to the widget's lifetime, not to each render.
  }, []);
  useEffect(() => {
    if (!properties.onEventChange || watched === previous.current) return;
    previous.current = watched;
    const timer = window.setTimeout(
      () => run(latest.current, properties.onEventChange),
      milliseconds(properties, 'onEventChangeDelay', latest.current.context),
    );
    return () => window.clearTimeout(timer);
  }, [watched, properties]);
  return null;
}

// Tab page selector: keeps a tab control's open tab and a 1-based index attribute in sync.
export function MarketplaceTabPageSelector(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const target = String(properties.targetTabCtrl || '').trim();
  const index = numberOf(read(props.context, properties.paneIndexByAttr));
  const latest = useRef(props);
  latest.current = props;
  useEffect(() => {
    if (!target) return;
    const tabs = [...document.querySelectorAll<HTMLLIElement>(`.mx-name-${target} > ul > li`)];
    const listeners = tabs.map((tab, position) => {
      const listener = () =>
        latest.current.onChange(String(properties.paneIndexByAttr), position + 1);
      tab.addEventListener('click', listener);
      return () => tab.removeEventListener('click', listener);
    });
    return () => listeners.forEach((remove) => remove());
  }, [target, properties.paneIndexByAttr]);
  useEffect(() => {
    if (!target || index < 1) return;
    const tab = document.querySelectorAll<HTMLLIElement>(`.mx-name-${target} > ul > li`)[index - 1];
    tab?.querySelector<HTMLElement>('a, button')?.click();
  }, [target, index]);
  return null;
}

// Dynamic enumeration picker: a dropdown or radio buttons over configured values.
export function MarketplaceEnumPicker(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const environment = useCaptionEnvironment(props.schema);
  const attribute = String(properties.enumAttribute || '');
  const current = String(read(props.context, attribute) ?? '');
  const values = Array.isArray((properties.enumValues as Properties | undefined)?.objects)
    ? ((properties.enumValues as Properties).objects as Properties[])
    : [];
  const choose = async (key: string) => {
    await props.onChange(attribute, key || null);
    await run(props, properties.onChangeAction);
  };
  const caption = (item: Properties) =>
    chartCaption(item.enumValue, props.context, environment) || String(item.enumKey || '');
  if (properties.dropdownRadio === 'radio')
    return (
      <div
        role="radiogroup"
        className={`mxrb-enum-picker mxrb-enum-picker-${String(properties.direction || 'vertical')}`}
      >
        {values.map((item) => (
          <label key={String(item.enumKey)}>
            <input
              type="radio"
              checked={current === item.enumKey}
              onChange={() => choose(String(item.enumKey))}
            />
            {caption(item)}
          </label>
        ))}
      </div>
    );
  return (
    <select
      className="form-control mxrb-enum-picker"
      value={current}
      onChange={(event) => choose(event.target.value)}
    >
      <option value="">{chartCaption(properties.placeholder, props.context, environment)}</option>
      {values.map((item) => (
        <option key={String(item.enumKey)} value={String(item.enumKey)}>
          {caption(item)}
        </option>
      ))}
    </select>
  );
}

// Advanced pagination: first/previous/page/next/last over a page attribute.
export function MarketplacePagination(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const environment = useCaptionEnvironment(props.schema);
  const page = Math.max(numberOf(read(props.context, properties.page), 1), 1);
  const count = numberOf(read(props.context, properties.resultCount));
  const size = Math.max(
    properties.pageSizeType === 'attribute'
      ? numberOf(read(props.context, properties.pageSizeAttr), 10)
      : numberOf(expressionValue(String(properties.pageSize || '10'), props.context), 10),
    1,
  );
  const pages = Math.max(Math.ceil(count / size), 1);
  const go = async (target: number) => {
    const next = Math.min(Math.max(target, 1), pages);
    if (next === page) return;
    await props.onChange(String(properties.page), next);
    await run(props, properties.refreshAction);
  };
  const label = (key: string, fallback: string) =>
    chartCaption(properties[key], props.context, environment) || fallback;
  const first = count === 0 ? 0 : (page - 1) * size + 1;
  const last = Math.min(page * size, count);
  const shown = [...new Set([1, page - 1, page, page + 1, pages])].filter(
    (item) => item >= 1 && item <= pages,
  );
  return (
    <nav className="mxrb-advanced-pagination" aria-label="Pagination">
      <button type="button" disabled={page <= 1} onClick={() => go(1)}>
        {label('firstLabel', 'First')}
      </button>
      <button type="button" disabled={page <= 1} onClick={() => go(page - 1)}>
        {label('previousLabel', 'Previous')}
      </button>
      {shown.map((item) => (
        <button
          type="button"
          key={item}
          aria-current={item === page ? 'page' : undefined}
          onClick={() => go(item)}
        >
          {item}
        </button>
      ))}
      <button type="button" disabled={page >= pages} onClick={() => go(page + 1)}>
        {label('nextLabel', 'Next')}
      </button>
      <button type="button" disabled={page >= pages} onClick={() => go(pages)}>
        {label('lastLabel', 'Last')}
      </button>
      <span className="mxrb-advanced-pagination-count">
        {`${first} ${label('toLabel', 'to')} ${last} ${label('ofLabel', 'of')} ${count}`}
      </span>
    </nav>
  );
}

// JSON editor: edits a JSON text attribute and calls its microflow on a valid change.
export function MarketplaceJsonEditor(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const attribute = String(properties.jsonStringAttr || '');
  const stored = String(read(props.context, attribute) ?? '');
  const [draft, setDraft] = useState<string | null>(null);
  const [error, setError] = useState('');
  const text = draft ?? stored;
  const commit = async () => {
    if (draft === null || draft === stored) return;
    try {
      JSON.parse(draft);
    } catch (failure) {
      setError(String(failure));
      return;
    }
    setError('');
    await props.onChange(attribute, draft as RuntimeValue);
    setDraft(null);
    if (typeof properties.onChangeMf === 'string' && properties.onChangeMf)
      await props.onAction?.(
        { event: 'change', kind: 'microflow', handler: properties.onChangeMf },
        props.context,
      );
  };
  return (
    <div className="mxrb-json-editor">
      <textarea
        aria-label={props.widget.name}
        value={text}
        readOnly={properties.editable === false}
        style={{ height: numberOf(properties.height) || undefined }}
        onChange={(event) => setDraft(event.target.value)}
        onBlur={commit}
      />
      {error && <p role="alert">{error}</p>}
    </div>
  );
}
