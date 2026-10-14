import type { ReactNode } from 'react';
import type { EntityRecord } from '../../types';
import { chartCaption, useCaptionEnvironment } from '../captions';
import type { MarketplaceWidgetProps, MarketplaceWidgetRegion } from '../marketplace';
import { memberName } from '../value';
import { marketplaceAction, useMarketplaceRecords } from './marketplaceData';

type Properties = Record<string, unknown>;

const regionFor = (regions: MarketplaceWidgetRegion[], role: string) =>
  regions.find((region) => region.role.toLowerCase() === role.toLowerCase());

const attributeName = (value: unknown) =>
  memberName(
    String(
      value && typeof value === 'object' ? ((value as Properties).attribute ?? '') : (value ?? ''),
    ),
  );

// Group headers as the Timeline widget formats them for its group-by options.
const groupFormats: Record<string, Intl.DateTimeFormatOptions> = {
  dayName: { weekday: 'long' },
  dayMonth: { day: 'numeric', month: 'long' },
  fullDate: { day: 'numeric', month: 'long', year: 'numeric' },
  month: { month: 'long' },
  monthYear: { month: 'long', year: 'numeric' },
  year: { year: 'numeric' },
};

const groupFormat = (properties: Properties): Intl.DateTimeFormatOptions => {
  if (properties.groupByKey === 'year') return groupFormats.year;
  if (properties.groupByKey === 'month')
    return groupFormats[String(properties.groupByMonthOptions || 'month')] || groupFormats.month;
  return groupFormats[String(properties.groupByDayOptions || 'dayName')] || groupFormats.dayName;
};

const groupKey = (date: Date, unit: unknown) =>
  unit === 'year'
    ? `${date.getFullYear()}`
    : unit === 'month'
      ? `${date.getFullYear()}-${date.getMonth()}`
      : date.toDateString();

// Timeline: one event per data source object, optionally grouped by a date attribute.
export function MarketplaceTimeline(props: MarketplaceWidgetProps) {
  const properties = (props.widget.options?.properties || {}) as Properties;
  const environment = useCaptionEnvironment(props.schema);
  const regions = props.regions || [];
  const { records, loading, error } = useMarketplaceRecords(properties.data, props);
  if (error) return <p role="alert">{error}</p>;
  if (loading) return <p role="status">Loading…</p>;
  const custom = properties.customVisualization === true;
  const action = marketplaceAction(properties.onClick);
  const content = (record: EntityRecord, role: string, text: unknown): ReactNode =>
    custom ? regionFor(regions, role)?.render?.(record) : chartCaption(text, record, environment);
  const event = (record: EntityRecord) => (
    <li key={record.id} className="mxrb-timeline-event">
      <div
        className="mxrb-timeline-event-body"
        role={action ? 'button' : undefined}
        tabIndex={action ? 0 : undefined}
        onClick={action ? () => props.onAction?.(action, record) : undefined}
      >
        <span className="mxrb-timeline-icon">
          {custom ? regionFor(regions, 'customIcon')?.render?.(record) : '●'}
        </span>
        <time>{content(record, 'customEventDateTime', properties.timeIndication)}</time>
        <strong>{content(record, 'customTitle', properties.title)}</strong>
        <p>{content(record, 'customDescription', properties.description)}</p>
      </div>
    </li>
  );
  const attribute = attributeName(properties.groupAttribute);
  if (properties.groupEvents === false || !attribute)
    return <ol className="mxrb-marketplace-timeline">{records.map(event)}</ol>;

  const groups = new Map<string, { date: Date; record: EntityRecord; records: EntityRecord[] }>();
  const ungrouped: EntityRecord[] = [];
  for (const record of records) {
    const raw = record.attributes[attribute];
    const date = raw === null || raw === undefined ? undefined : new Date(String(raw));
    if (!date || Number.isNaN(date.getTime())) {
      ungrouped.push(record);
      continue;
    }
    const key = groupKey(date, properties.groupByKey);
    const group = groups.get(key) ?? { date, record, records: [] };
    group.records.push(record);
    groups.set(key, group);
  }
  const formatter = new Intl.DateTimeFormat(environment.locale, groupFormat(properties));
  const grouped = [...groups.entries()].map(([key, group]) => (
    <li key={key} className="mxrb-timeline-group">
      <h4>
        {custom
          ? regionFor(regions, 'customGroupHeader')?.render?.(group.record)
          : formatter.format(group.date)}
      </h4>
      <ol>{group.records.map(event)}</ol>
    </li>
  ));
  const rest = ungrouped.length
    ? [
        <li key="ungrouped">
          <ol>{ungrouped.map(event)}</ol>
        </li>,
      ]
    : [];
  return (
    <ol className="mxrb-marketplace-timeline">
      {properties.ungroupedEventsPosition === 'beginning'
        ? [...rest, ...grouped]
        : [...grouped, ...rest]}
    </ol>
  );
}
