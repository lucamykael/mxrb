import { useEffect, useRef, useState, type HTMLAttributeReferrerPolicy } from 'react';
import type { EntityRecord, WidgetEvent } from '../../types';
import { useCaptionEnvironment } from '../captions';
import type { MarketplaceWidgetProps } from '../marketplace';
import { displayValue, expressionValue, memberName } from '../value';

type Properties = Record<string, unknown>;

const flowEvent = (kind: 'microflow' | 'nanoflow', handler: unknown): WidgetEvent | undefined =>
  typeof handler === 'string' && handler ? { event: 'click', kind, handler } : undefined;

// A translatable string property: { language code: text }; the session language wins.
export function translatedText(value: unknown, locale: string): string {
  if (typeof value === 'string') return value;
  if (!value || typeof value !== 'object') return '';
  const texts = value as Record<string, string>;
  const code = locale.replace('-', '_');
  return texts[code] ?? texts.en_US ?? Object.values(texts)[0] ?? '';
}

// HTML snippet: renders HTML, or runs JavaScript with the element as `this` and the
// context object as `contextObj`, as the snippet widget does; clicks may call a microflow.
export function MarketplaceHtmlSnippet(props: MarketplaceWidgetProps) {
  const properties = (props.widget.options?.properties || {}) as Properties;
  const { locale } = useCaptionEnvironment(props.schema);
  const element = useRef<HTMLDivElement>(null);
  const [error, setError] = useState('');
  const contents = translatedText(properties.contents, locale);
  const javascript = String(properties.contenttype || 'html').startsWith('js');
  const contextKey = JSON.stringify(props.context);
  useEffect(() => {
    if (!javascript || !element.current) return;
    try {
      new Function('contextObj', contents).call(element.current, JSON.parse(contextKey));
      setError('');
    } catch (failure) {
      setError(String(failure));
    }
  }, [javascript, contents, contextKey]);
  const click = flowEvent('microflow', properties.onclickmf);
  return (
    <div
      ref={element}
      className="mxrb-html-snippet"
      onClick={click ? () => props.onAction?.(click, props.context) : undefined}
      dangerouslySetInnerHTML={javascript ? undefined : { __html: contents }}
    >
      {javascript && error ? <span role="alert">{error}</span> : undefined}
    </div>
  );
}

// Microflow timer: calls its microflow or nanoflow every interval (or once).
export function MarketplaceMicroflowTimer(props: MarketplaceWidgetProps) {
  const properties = (props.widget.options?.properties || {}) as Properties;
  const nanoflow = properties.callEvent === 'callNanoflow';
  const event = flowEvent(
    nanoflow ? 'nanoflow' : 'microflow',
    nanoflow ? properties.nanoflow : properties.microflow,
  );
  const interval = Math.max(Number(properties.interval) || 30000, 1);
  const once = properties.once === true;
  const immediately = properties.startatonce !== false;
  const { onAction, context } = props;
  const latest = useRef({ onAction, context });
  latest.current = { onAction, context };
  useEffect(() => {
    if (!event) return;
    const run = () => latest.current.onAction?.(event, latest.current.context);
    if (once) {
      const timer = window.setTimeout(run, immediately ? 0 : interval);
      return () => window.clearTimeout(timer);
    }
    if (immediately) run();
    const timer = window.setInterval(run, interval);
    return () => window.clearInterval(timer);
  }, [event?.kind, event?.handler, interval, once, immediately]);
  return null;
}

const csvRows = (text: string): string[][] => {
  const rows: string[][] = [[]];
  let field = '';
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (quoted) {
      if (char === '"' && text[index + 1] === '"') {
        field += '"';
        index += 1;
      } else if (char === '"') quoted = false;
      else field += char;
    } else if (char === '"') quoted = true;
    else if (char === ',') {
      rows[rows.length - 1].push(field);
      field = '';
    } else if (char === '\n' || char === '\r') {
      if (char === '\r' && text[index + 1] === '\n') index += 1;
      rows[rows.length - 1].push(field);
      field = '';
      rows.push([]);
    } else field += char;
  }
  rows[rows.length - 1].push(field);
  return rows.filter((row) => row.some((cell) => cell !== ''));
};

// CSV as table: the first CSV line is the header.
export function MarketplaceCsvTable(props: MarketplaceWidgetProps) {
  const properties = (props.widget.options?.properties || {}) as Properties;
  const attribute = memberName(String(properties.csv || ''));
  const text = String(props.context?.attributes[attribute] ?? '');
  const [header = [], ...rows] = csvRows(text);
  return (
    <table className="table mxrb-csv-table">
      <thead>
        <tr>
          {header.map((cell, index) => (
            <th key={index}>{cell}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((row, rowIndex) => (
          <tr key={rowIndex}>
            {row.map((cell, index) => (
              <td key={index}>{cell}</td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

const textOf = (expression: unknown, context: EntityRecord | null) =>
  expression ? String(displayValue(expressionValue(String(expression), context)) ?? '') : '';
const option = (value: unknown) => (!value || value === 'notSet' ? undefined : String(value));

// IFrame component: URL or inline document from expressions, size and browser policies.
export function MarketplaceIFrame(props: MarketplaceWidgetProps) {
  const properties = (props.widget.options?.properties || {}) as Properties;
  const load = properties.onLoad
    ? { ...(properties.onLoad as Record<string, unknown>) }
    : undefined;
  const action =
    load && typeof (load.action as Properties | undefined)?.handler === 'string'
      ? ({ ...(load.action as Properties), event: 'load' } as unknown as WidgetEvent)
      : undefined;
  const sandbox = option(properties.miscSandbox);
  return (
    <iframe
      className="mxrb-iframe"
      title={props.widget.name}
      src={textOf(properties.urlExpression, props.context) || undefined}
      srcDoc={textOf(properties.srcExpression, props.context) || undefined}
      width={textOf(properties.uiSizeWidth, props.context) || undefined}
      height={textOf(properties.uiSizeHeight, props.context) || undefined}
      loading={option(properties.miscLoading) as 'eager' | 'lazy' | undefined}
      referrerPolicy={
        option(properties.miscReferrerPolicy) as HTMLAttributeReferrerPolicy | undefined
      }
      sandbox={sandbox === 'none' ? '' : sandbox}
      allow={textOf(properties.miscAllowExpression, props.context) || undefined}
      onLoad={action ? () => props.onAction?.(action, props.context) : undefined}
    />
  );
}
