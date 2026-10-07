import type { EntityRecord } from '../types';
import { memberName } from './value';

export type PlotlyObject = Record<string, unknown>;
export type PlotlyClick = { points: Array<{ bbox?: PlotlyObject }> };
export interface PlotlyGraph extends HTMLDivElement {
  on(name: 'plotly_click', callback: (event: PlotlyClick) => void): void;
  removeAllListeners(name: 'plotly_click'): void;
}
export interface PlotlyEngine {
  react(
    graph: PlotlyGraph,
    data: PlotlyObject[],
    layout: PlotlyObject,
    config: PlotlyObject,
  ): Promise<unknown>;
  purge(graph: PlotlyGraph): void;
}

export const loadPlotly = async (): Promise<PlotlyEngine> => {
  const module = await import('plotly.js-dist-min');
  return module.default;
};

const object = (value: unknown): PlotlyObject => {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new Error('Chart options must be a JSON object');
  return value as PlotlyObject;
};
const options = (source: unknown): PlotlyObject =>
  source ? object(JSON.parse(String(source))) : {};
const data = (source: unknown): PlotlyObject[] => {
  const value: unknown = source ? JSON.parse(String(source)) : [];
  if (!Array.isArray(value)) throw new Error('Chart data must contain a list of series');
  return value.map(object);
};

export const chartAttribute = (value: unknown): string => {
  const source = value && typeof value === 'object' ? (value as PlotlyObject).attribute : value;
  return String(source || '');
};

export function customChartSpec(properties: PlotlyObject, context: EntityRecord | null) {
  const attributeValue = (name: string) =>
    context?.attributes[memberName(chartAttribute(properties[name]))];
  const dynamicData = data(attributeValue('dataAttribute'));
  const dynamicLayout = options(attributeValue('layoutAttribute'));
  return {
    data: [
      ...data(properties.dataStatic),
      ...dynamicData,
      ...(dynamicData.length ? [] : data(properties.sampleData)),
    ],
    layout: {
      ...options(properties.layoutStatic),
      ...dynamicLayout,
      ...(Object.keys(dynamicLayout).length ? {} : options(properties.sampleLayout)),
    },
    config: { displayModeBar: false, ...options(properties.configurationOptions) },
  };
}

export function customChartLayout(
  layout: PlotlyObject,
  width: number,
  height: number,
): PlotlyObject {
  const nested = (value: unknown) =>
    value && typeof value === 'object' && !Array.isArray(value) ? (value as PlotlyObject) : {};
  const legend = nested(layout.legend);
  const xaxis = nested(layout.xaxis);
  const yaxis = nested(layout.yaxis);
  const textSize = Math.max((width / 1000) * 10, 7);
  return {
    ...layout,
    width,
    height,
    autosize: true,
    font: {
      family: 'Open Sans, sans-serif',
      size: Math.max((width / 1000) * 12, 8),
      ...nested(layout.font),
    },
    legend: {
      font: { size: textSize, ...nested(legend.font) },
      itemwidth: Math.max((width / 1000) * 10, 3),
      itemsizing: 'constant',
      ...legend,
    },
    xaxis: { tickfont: { size: textSize, ...nested(xaxis.tickfont) }, ...xaxis },
    yaxis: { tickfont: { size: textSize, ...nested(yaxis.tickfont) }, ...yaxis },
    margin: { l: 60, r: 60, t: 60, b: 60, pad: 10, ...nested(layout.margin) },
  };
}
