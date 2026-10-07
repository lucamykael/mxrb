import { useEffect, useRef, useState } from 'react';
import type { CSSProperties } from 'react';
import type { MarketplaceWidgetProps } from '../marketplace';
import { chartAttribute, customChartLayout, customChartSpec, loadPlotly } from '../plotly';
import type { PlotlyEngine, PlotlyGraph } from '../plotly';

const dimension = (unit: unknown, value: unknown): string => {
  const amount = Number(value ?? 100);
  if (!Number.isFinite(amount) || amount < 0)
    throw new Error('Chart dimensions must be non-negative numbers');
  if (unit === 'pixels') return `${amount}px`;
  if (unit === 'percentageOfView') return `${amount}vh`;
  return `${amount}%`;
};

export function MarketplacePlotly(props: MarketplaceWidgetProps) {
  const properties = props.widget.options?.properties || {};
  const encoded = JSON.stringify(properties);
  const context = JSON.stringify(props.context);
  const container = useRef<HTMLDivElement>(null);
  const graph = useRef<PlotlyGraph>(null);
  const engine = useRef<PlotlyEngine | null>(null);
  const queue = useRef<Promise<unknown>>(Promise.resolve());
  const actionPending = useRef(false);
  const [size, setSize] = useState({ width: 600, height: 400 });
  const [state, setState] = useState({ key: '', error: '' });
  const key = `${encoded}:${context}:${size.width}:${size.height}:${props.revision ?? 0}`;
  let spec: ReturnType<typeof customChartSpec> | undefined;
  let error = '';
  let style: CSSProperties = {};
  try {
    spec = customChartSpec(properties, props.context);
    const proportional = !properties.heightUnit || properties.heightUnit === 'percentageOfWidth';
    style = {
      width: dimension(properties.widthUnit, properties.width),
      height: proportional
        ? dimension('pixels', (size.width * Number(properties.height ?? 100)) / 100)
        : dimension(properties.heightUnit, properties.height),
      overflowY: String(properties.OverflowY || 'auto') as CSSProperties['overflowY'],
      ...(properties.minHeightUnit && properties.minHeightUnit !== 'none'
        ? { minHeight: dimension(properties.minHeightUnit, properties.minHeight ?? 250) }
        : {}),
      ...(properties.maxHeightUnit && properties.maxHeightUnit !== 'none'
        ? { maxHeight: dimension(properties.maxHeightUnit, properties.maxHeight ?? 250) }
        : {}),
    };
  } catch (failure) {
    error = String(failure);
  }
  const hasData = Boolean(spec?.data.length);
  useEffect(() => {
    const element = container.current;
    if (!element) return;
    const measure = () => {
      const box = element.getBoundingClientRect();
      if (box.width > 0 && box.height > 0)
        setSize((previous) =>
          previous.width === box.width && previous.height === box.height
            ? previous
            : { width: box.width, height: box.height },
        );
    };
    measure();
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(measure);
    observer?.observe(element);
    window.addEventListener('resize', measure);
    return () => {
      observer?.disconnect();
      window.removeEventListener('resize', measure);
    };
  }, [encoded, error, hasData]);
  useEffect(() => {
    const element = graph.current;
    if (!element || error) return;
    let active = true;
    queue.current = queue.current
      .catch(() => {})
      .then(async () => {
        const loaded = await loadPlotly();
        if (!active) return;
        engine.current = loaded;
        const input = customChartSpec(JSON.parse(encoded), JSON.parse(context));
        await loaded.react(
          element,
          input.data,
          customChartLayout(input.layout, size.width, size.height),
          input.config,
        );
        if (!active) return;
        element.removeAllListeners('plotly_click');
        element.on('plotly_click', (event) => {
          if (props.actionRunning || actionPending.current) return;
          actionPending.current = true;
          const attribute = chartAttribute(properties.eventDataAttribute);
          Promise.resolve()
            .then(async () => {
              if (attribute) {
                const value = JSON.stringify(event.points[0]?.bbox) ?? '';
                await props.onChange(attribute, value);
                if (value && props.onClick) {
                  const action = props.onClick();
                  await props.onChange(attribute, '');
                  await action;
                }
              } else await props.onClick?.();
            })
            .catch((failure) => {
              if (active) setState({ key, error: String(failure) });
            })
            .finally(() => {
              actionPending.current = false;
            });
        });
        setState({ key, error: '' });
      })
      .catch((failure) => {
        if (active) setState({ key, error: String(failure) });
      });
    return () => {
      active = false;
    };
  }, [
    key,
    encoded,
    context,
    error,
    size.width,
    size.height,
    props.actionRunning,
    props.onChange,
    props.onClick,
    properties.eventDataAttribute,
  ]);
  useEffect(() => {
    const element = graph.current;
    return () => {
      queue.current = queue.current
        .catch(() => {})
        .then(() => {
          if (element) engine.current?.purge(element);
        });
    };
  }, [hasData, error]);
  const name = String(properties.title || props.widget.options?.widget_name || props.widget.name);
  if (error) return <p role="alert">{error}</p>;
  if (!spec?.data.length) return <p role="status">No chart data</p>;
  return (
    <figure className="mxrb-marketplace-chart">
      <div ref={container} style={style}>
        <div ref={graph} role="img" aria-label={name} style={{ width: '100%', height: '100%' }} />
      </div>
      {state.key !== key && <p role="status">Loading chart…</p>}
      {state.error && state.key === key && <p role="alert">{state.error}</p>}
      <figcaption>{name}</figcaption>
      <details>
        <summary>Chart data</summary>
        <pre>{JSON.stringify(spec.data, null, 2)}</pre>
      </details>
      {props.children}
    </figure>
  );
}
