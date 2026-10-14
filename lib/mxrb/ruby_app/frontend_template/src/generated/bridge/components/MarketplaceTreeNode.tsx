import { useState, type ReactNode } from 'react';
import type { EntityRecord } from '../../types';
import { chartCaption, useCaptionEnvironment, type CaptionEnvironment } from '../captions';
import type { MarketplaceWidgetProps, MarketplaceWidgetRegion } from '../marketplace';
import { useMarketplaceRecords } from './marketplaceData';

type Properties = Record<string, unknown>;

const regionFor = (regions: MarketplaceWidgetRegion[], role: string) =>
  regions.find((region) => region.role.toLowerCase() === role.toLowerCase());

function TreeItem({
  record,
  properties,
  regions,
  environment,
}: {
  record: EntityRecord;
  properties: Properties;
  regions: MarketplaceWidgetRegion[];
  environment: CaptionEnvironment;
}) {
  const expandable = properties.hasChildren !== false;
  const [open, setOpen] = useState(properties.startExpanded === true);
  const header: ReactNode =
    properties.headerType === 'custom'
      ? regionFor(regions, 'headerContent')?.render?.(record)
      : chartCaption(properties.headerCaption, record, environment);
  const toggle = () => expandable && setOpen((value) => !value);
  const onIcon = properties.openNodeOn === 'iconClick';
  const icon =
    expandable && properties.showIcon !== 'no' ? (
      <button
        type="button"
        className="mxrb-tree-node-icon"
        aria-label={open ? 'Collapse' : 'Expand'}
        onClick={onIcon ? toggle : undefined}
        tabIndex={onIcon ? 0 : -1}
      >
        {open ? '▾' : '▸'}
      </button>
    ) : null;
  return (
    <li role="treeitem" aria-expanded={expandable ? open : undefined} className="mxrb-tree-node">
      <div
        className="mxrb-tree-node-header"
        role={onIcon ? undefined : 'button'}
        tabIndex={onIcon ? undefined : 0}
        onClick={onIcon ? undefined : toggle}
        onKeyDown={(event) => {
          if (!onIcon && (event.key === 'Enter' || event.key === ' ')) {
            event.preventDefault();
            toggle();
          }
        }}
      >
        {properties.showIcon !== 'right' && icon}
        <span>{header}</span>
        {properties.showIcon === 'right' && icon}
      </div>
      {expandable && open && (
        <div role="group" className="mxrb-tree-node-children">
          {regionFor(regions, 'children')?.render?.(record)}
        </div>
      )}
    </li>
  );
}

// Tree node: one item per data source object, with a text or custom header and
// collapsible children (usually nested tree nodes over an association).
export function MarketplaceTreeNode(props: MarketplaceWidgetProps) {
  const properties = (props.widget.options?.properties || {}) as Properties;
  const environment = useCaptionEnvironment(props.schema);
  const { records, loading, error } = useMarketplaceRecords(properties.datasource, props);
  if (error) return <p role="alert">{error}</p>;
  if (loading) return <p role="status">Loading…</p>;
  return (
    <ul role="tree" className="mxrb-tree-node-list" aria-label={props.widget.name}>
      {records.map((record) => (
        <TreeItem
          key={record.id}
          record={record}
          properties={properties}
          regions={props.regions || []}
          environment={environment}
        />
      ))}
    </ul>
  );
}
