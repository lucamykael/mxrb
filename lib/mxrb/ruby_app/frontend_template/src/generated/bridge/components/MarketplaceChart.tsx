import { isDecimal, numericText } from '../decimal';
import { useEffect, useState } from 'react';
import type { ApiRequest, EntityCollectionResponse, EntityRecord } from '../../types';
import type { MarketplaceWidgetProps } from '../marketplace';
import { expressionValue, memberName, sortRecords } from '../value';

type Properties = Record<string, unknown>;
type Point = { label: string; value: number; size?: number; row?: string };
type Series = { name: string; points: Point[]; kind?: string };
type ChartState = { key: string; series: Series[]; error?: string; request?: ApiRequest };
const palette = ['#356ac3', '#b24c45', '#278575', '#9262ad', '#af751c', '#53717d'];
const object = (value: unknown): Properties =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Properties) : {};
const attribute = (value: unknown) => memberName(String(object(value).attribute ?? value ?? ''));
const numeric = (value: unknown): number => {
  // Plot coordinates intentionally cross into binary floating point only here.
  if (isDecimal(value)) value = numericText(value);
  if ((typeof value !== 'number' && typeof value !== 'string') || String(value).trim() === '')
    throw new Error('Chart values must be numbers');
  const result = Number(value);
  if (!Number.isFinite(result)) throw new Error('Chart values must be numbers');
  return result;
};

const aggregations = [
  'none',
  'count',
  'sum',
  'avg',
  'min',
  'max',
  'median',
  'mode',
  'first',
  'last',
];

function aggregatePoints(points: Point[], operation: string): Point[] {
  if (operation === 'none') return points;
  const groups = new Map<string, Point[]>();
  for (const point of points) {
    const group = groups.get(point.label) ?? [];
    group.push(point);
    groups.set(point.label, group);
  }
  return [...groups.values()].map((group) => {
    const values = group.map((point) => point.value);
    let value: number;
    if (operation === 'count') value = values.length;
    else if (operation === 'first') value = values[0];
    else if (operation === 'last') value = values[values.length - 1];
    else if (operation === 'min') value = values.reduce((a, b) => Math.min(a, b));
    else if (operation === 'max') value = values.reduce((a, b) => Math.max(a, b));
    else if (operation === 'median') {
      const ordered = [...values].sort((a, b) => a - b);
      const upper = Math.floor(ordered.length / 2);
      value = (ordered[upper] + ordered[Math.floor((ordered.length - 1) / 2)]) / 2;
    } else if (operation === 'mode') {
      const counts = new Map<number, number>();
      value = values[0];
      let highest = 0;
      for (const candidate of values) {
        const frequency = (counts.get(candidate) ?? 0) + 1;
        counts.set(candidate, frequency);
        if (frequency > highest) {
          highest = frequency;
          value = candidate;
        }
      }
    } else {
      value = values.reduce((sum, item) => sum + item, 0);
      if (operation === 'avg') value /= values.length;
    }
    return { ...group[0], value };
  });
}

function chartCaption(value: unknown, context: EntityRecord | null | undefined): string {
  if (value === undefined || value === null) return '';
  if (typeof value === 'string') return value;
  const template = object(value);
  if (
    typeof template.text !== 'string' ||
    (template.parameters !== undefined &&
      (!Array.isArray(template.parameters) ||
        template.parameters.some((item) => typeof item !== 'string')))
  )
    throw new Error('Chart caption requires text and expression parameters');
  let text = template.text;
  for (const [index, parameter] of ((template.parameters ?? []) as string[]).entries()) {
    text = text.replaceAll(
      `{${index + 1}}`,
      String(expressionValue(parameter, context ?? null) ?? ''),
    );
  }
  return text;
}

async function chartSeries(
  properties: Properties,
  props: Pick<MarketplaceWidgetProps, 'context' | 'request'>,
  kind: string,
): Promise<Series[]> {
  if (properties.barmode && properties.barmode !== 'group')
    throw new Error(`Chart bar mode is not supported: ${properties.barmode}`);
  if (properties.dataStatic !== undefined || properties.dataAttribute) {
    const raw = properties.dataAttribute
      ? props.context?.attributes[attribute(properties.dataAttribute)]
      : properties.dataStatic;
    const data: unknown = JSON.parse(String(raw || '[]'));
    if (!Array.isArray(data)) throw new Error('Chart data must contain a list of series');
    return data.map((entry: unknown) => {
      const trace = object(entry);
      if (trace.type && !['scatter', 'bar'].includes(String(trace.type)))
        throw new Error(`Custom chart type is not supported: ${trace.type}`);
      if (!Array.isArray(trace.x) || !Array.isArray(trace.y) || trace.x.length !== trace.y.length)
        throw new Error('Chart labels and values must have matching lengths');
      const labels = trace.x;
      return {
        name: String(trace.name || ''),
        kind: String(trace.type || 'scatter'),
        points: trace.y.flatMap((value, index) =>
          value === null ? [] : [{ label: String(labels[index]), value: numeric(value) }],
        ),
      };
    });
  }

  const grouped = object(properties.series ?? properties.lines).objects;
  const definitions = Array.isArray(grouped) ? grouped.map(object) : [properties];
  const batches = await Promise.all(
    definitions.map(async (definition) => {
      const dynamic = definition.dataSet === 'dynamic';
      if (definition.dataSet && !['static', 'dynamic'].includes(String(definition.dataSet)))
        throw new Error(`Chart data set is not supported: ${definition.dataSet}`);
      const aggregation = String(definition.aggregationType || 'none');
      if (!aggregations.includes(aggregation))
        throw new Error(`Chart aggregation is not supported: ${aggregation}`);
      const configured = object(
        dynamic
          ? definition.dynamicDataSource
          : (definition.staticDataSource ?? definition.seriesDataSource),
      );
      const source =
        typeof configured.data_source === 'string'
          ? { ...configured, entity: configured.data_source }
          : object(configured.data_source);
      const entity = String(source.entity || '');
      if (!entity || !props.request) throw new Error('Chart data source is unavailable');
      const query = new URLSearchParams();
      if (source.xpath) {
        query.set('xpath', String(source.xpath));
        if (props.context) {
          query.set('xpath_context_type', props.context.type);
          query.set('xpath_context_id', props.context.id);
        }
      }
      const response = await props.request<EntityCollectionResponse>(
        `/api/entities/${encodeURIComponent(entity)}${query.size ? `?${query}` : ''}`,
      );
      const sorting = Array.isArray(source.sort)
        ? source.sort.map((item) => {
            const sort = object(item);
            return {
              attribute: String(sort.attribute || ''),
              direction: String(sort.direction || ''),
            };
          })
        : [];
      const horizontal = kind.includes('barchart');
      const xAttribute = dynamic ? definition.dynamicXAttribute : definition.staticXAttribute;
      const yAttribute = dynamic ? definition.dynamicYAttribute : definition.staticYAttribute;
      const x = attribute(
        (horizontal ? yAttribute : xAttribute) ??
          definition.horizontalAxisAttribute ??
          definition.seriesNameAttribute,
      );
      const y = attribute(
        (horizontal ? xAttribute : yAttribute) ?? definition.seriesValueAttribute,
      );
      const size = attribute(
        dynamic ? definition.dynamicSizeAttribute : definition.staticSizeAttribute,
      );
      const row = attribute(definition.verticalAxisAttribute);
      const read = (record: EntityRecord, name: string) => {
        if (!(name in record.attributes))
          throw new Error(`Chart attribute is unavailable: ${name}`);
        return record.attributes[name];
      };
      const groups = new Map<unknown, { name: string; records: EntityRecord[] }>();
      const groupAttribute = attribute(definition.groupByAttribute);
      if (dynamic && !groupAttribute)
        throw new Error('Dynamic chart group attribute is unavailable');
      for (const record of sortRecords(response.records, sorting)) {
        const groupKey = dynamic ? (read(record, groupAttribute) ?? '') : '';
        if (groupKey !== null && typeof groupKey === 'object')
          throw new Error('Chart groups must contain scalar values');
        const group = groups.get(groupKey) ?? { name: '', records: [] };
        group.records.push(record);
        if (!group.name || group.name === '(empty)') {
          group.name = chartCaption(
            dynamic ? definition.dynamicName : (definition.staticName ?? definition.seriesName),
            dynamic ? record : props.context,
          );
        }
        groups.set(groupKey, group);
      }
      return [...groups.values()].map((group) => ({
        name: group.name,
        points: aggregatePoints(
          group.records.flatMap((record, index) => {
            const value = read(record, y);
            if (value === null || value === undefined) return [];
            return [
              {
                label: x
                  ? String(read(record, x) ?? '')
                  : String(definition.seriesName ?? index + 1),
                value: numeric(value),
                size: size ? numeric(read(record, size)) : undefined,
                row: row ? String(read(record, row) ?? '') : undefined,
              },
            ];
          }),
          aggregation,
        ),
      }));
    }),
  );
  return batches.flat();
}

function ChartPlot({ series, kind, name }: { series: Series[]; kind: string; name: string }) {
  const values = series.flatMap((item) => item.points.map((point) => point.value));
  const low = values.reduce((bound, value) => Math.min(bound, value), 0);
  const high = values.reduce((bound, value) => Math.max(bound, value), 0);
  const span = high - low || 1;
  const y = (value: number) => 250 - ((value - low) / span) * 220;
  const axisPoints = [
    ...new Map(
      series.flatMap((item) => item.points.map((point) => [point.label, point] as const)),
    ).values(),
  ];
  const labels = axisPoints.map((point) => point.label);
  const count = Math.max(1, labels.length);
  const width = 540 / count;
  const temporal = kind.includes('timeseries');
  const dates = temporal
    ? series.flatMap((item) => item.points.map((point) => Date.parse(point.label)))
    : [];
  const firstDate = dates.reduce((bound, value) => Math.min(bound, value), Infinity);
  const lastDate = dates.reduce((bound, value) => Math.max(bound, value), -Infinity);
  const x = (index: number, point?: Point) =>
    temporal && point
      ? firstDate === lastDate
        ? 320
        : 50 + ((Date.parse(point.label) - firstDate) / (lastDate - firstDate)) * 540
      : 50 + width * ((point ? labels.indexOf(point.label) : index) + 0.5);
  const horizontal = kind.includes('barchart');
  const valueX = (value: number) => 120 + ((value - low) / span) * 460;
  const categoryY = (index: number, point?: Point) =>
    25 + (230 / count) * ((point ? labels.indexOf(point.label) : index) + 0.5);
  const pie = kind.includes('piechart');
  const heatmap = kind.includes('heatmap');
  let angle = -Math.PI / 2;
  const total = values.reduce((sum, value) => sum + Math.max(0, value), 0);
  return (
    <svg
      viewBox="0 0 640 300"
      role="img"
      aria-label={name}
      style={{ width: '100%', maxHeight: 420 }}
    >
      <title>{name}</title>
      {!pie && !heatmap && (
        <>
          <line
            x1={horizontal ? valueX(0) : 50}
            x2={horizontal ? valueX(0) : 590}
            y1={horizontal ? 25 : y(0)}
            y2={horizontal ? 255 : y(0)}
            stroke="currentColor"
          />
          <text x={horizontal ? 550 : 2} y={horizontal ? 285 : 35}>
            {high}
          </text>
          <text x={horizontal ? 120 : 2} y={horizontal ? 285 : 250}>
            {low}
          </text>
          {axisPoints.map(
            (point, index) =>
              index % Math.ceil(count / 8) === 0 && (
                <text
                  key={index}
                  x={horizontal ? 110 : x(index, point)}
                  y={horizontal ? categoryY(index, point) : 280}
                  textAnchor={horizontal ? 'end' : 'middle'}
                  fontSize="11"
                >
                  {point.label}
                </text>
              ),
          )}
        </>
      )}
      {series.map((item, seriesIndex) => {
        const color = palette[seriesIndex % palette.length];
        const points = item.points
          .map((point, index) => `${x(index, point)},${y(point.value)}`)
          .join(' ');
        const bar = /bar|column/.test(kind) || item.kind === 'bar';
        return (
          <g key={seriesIndex} fill={color}>
            {!pie && !heatmap && !bar && (
              <>
                {kind.includes('area') && (
                  <polygon
                    points={`${x(0, item.points[0])},${y(0)} ${points} ${x(item.points.length - 1, item.points.at(-1))},${y(0)}`}
                    opacity="0.2"
                  />
                )}
                {!kind.includes('bubble') && (
                  <polyline points={points} fill="none" stroke={color} strokeWidth="2" />
                )}
              </>
            )}
            {item.points.map((point, index) => {
              const title = `${item.name} ${point.label}: ${point.value}`.trim();
              if (pie) {
                const start = angle;
                angle += (Math.max(0, point.value) / (total || 1)) * Math.PI * 2;
                const px = (a: number) => 320 + Math.cos(a) * 110;
                const py = (a: number) => 145 + Math.sin(a) * 110;
                const fill = palette[index % palette.length];
                if (point.value === total && total > 0)
                  return (
                    <circle key={index} cx="320" cy="145" r="110" fill={fill}>
                      <title>{title}</title>
                    </circle>
                  );
                return (
                  <path
                    key={index}
                    d={`M320,145 L${px(start)},${py(start)} A110,110 0 ${angle - start > Math.PI ? 1 : 0},1 ${px(angle)},${py(angle)} Z`}
                    fill={fill}
                  >
                    <title>{title}</title>
                  </path>
                );
              }
              if (heatmap) {
                const rows = [...new Set(item.points.map((p) => p.row))];
                const labels = [...new Set(item.points.map((p) => p.label))];
                return (
                  <rect
                    key={index}
                    x={50 + (labels.indexOf(point.label) * 540) / labels.length}
                    y={25 + (rows.indexOf(point.row) * 240) / rows.length}
                    width={540 / labels.length}
                    height={240 / rows.length}
                    opacity={0.15 + (0.85 * (point.value - low)) / span}
                  >
                    <title>{title}</title>
                  </rect>
                );
              }
              if (bar)
                return (
                  <rect
                    key={index}
                    x={
                      horizontal
                        ? Math.min(valueX(0), valueX(point.value))
                        : x(index, point) -
                          width * 0.4 +
                          (seriesIndex * width * 0.8) / series.length
                    }
                    y={
                      horizontal
                        ? categoryY(index, point) -
                          92 / count +
                          (seriesIndex * 184) / count / series.length
                        : Math.min(y(0), y(point.value))
                    }
                    width={
                      horizontal
                        ? Math.abs(valueX(0) - valueX(point.value))
                        : (width * 0.8) / series.length
                    }
                    height={
                      horizontal ? 184 / count / series.length : Math.abs(y(0) - y(point.value))
                    }
                  >
                    <title>{title}</title>
                  </rect>
                );
              return (
                <circle
                  key={index}
                  cx={x(index, point)}
                  cy={y(point.value)}
                  r={
                    kind.includes('bubble')
                      ? Math.max(2, Math.sqrt(Math.abs(point.size ?? point.value)))
                      : 3
                  }
                >
                  <title>{title}</title>
                </circle>
              );
            })}
          </g>
        );
      })}
    </svg>
  );
}

export function MarketplaceChart(props: MarketplaceWidgetProps) {
  const properties = props.widget.options?.properties || {};
  const encoded = JSON.stringify(properties);
  const context = props.context;
  const contextKey = JSON.stringify(context);
  const { request, revision = 0 } = props;
  const kind = String(props.widget.options?.widget_id).toLowerCase();
  const key = `${kind}:${encoded}:${contextKey}:${revision}`;
  const [state, setState] = useState<ChartState>({ key: '', series: [] });
  useEffect(() => {
    let active = true;
    chartSeries(JSON.parse(encoded), { context: JSON.parse(contextKey), request }, kind)
      .then((series) => {
        if (
          kind.includes('timeseries') &&
          series.some((item) =>
            item.points.some((point) => !Number.isFinite(Date.parse(point.label))),
          )
        )
          throw new Error('Chart dates must be valid dates');
        if (active) setState({ key, series, request });
      })
      .catch((failure: unknown) => {
        if (active) setState({ key, series: [], request, error: String(failure) });
      });
    return () => {
      active = false;
    };
  }, [encoded, contextKey, request, key, kind]);
  const name = String(properties.title || props.widget.options?.widget_name || props.widget.name);
  if (state.key !== key || state.request !== request) return <p role="status">Loading chart…</p>;
  if (state.error) return <p role="alert">{state.error}</p>;
  if (!state.series.some((item) => item.points.length)) return <p role="status">No chart data</p>;
  return (
    <figure className="mxrb-marketplace-chart">
      <ChartPlot series={state.series} kind={kind} name={name} />
      <figcaption>{name}</figcaption>
      <details>
        <summary>Chart data</summary>
        <table>
          <thead>
            <tr>
              <th>Series</th>
              <th>Label</th>
              <th>Value</th>
            </tr>
          </thead>
          <tbody>
            {state.series.flatMap((item, i) =>
              item.points.map((point, j) => (
                <tr key={`${i}:${j}`}>
                  <td>{item.name}</td>
                  <td>{point.row ? `${point.row} / ${point.label}` : point.label}</td>
                  <td>{point.value}</td>
                </tr>
              )),
            )}
          </tbody>
        </table>
      </details>
      {props.children}
    </figure>
  );
}
