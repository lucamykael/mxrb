import { useContext, useEffect, useId, useRef, useState } from 'react';
import type { MarketplaceWidgetProps } from '../marketplace';
import { DataGridFilters, OperatorSelector } from './DataGrid';
import { marketplaceAction } from './marketplaceData';

type Properties = Record<string, unknown>;

// The widget's defaultFilter values and the grid filter operators they select.
const OPERATORS: Record<string, string> = {
  contains: 'contains',
  startsWith: 'starts_with',
  endsWith: 'ends_with',
  greater: 'gt',
  greaterEqual: 'gte',
  equal: 'equals',
  notEqual: 'not_equals',
  smaller: 'lt',
  smallerEqual: 'lte',
  empty: 'empty',
  notEmpty: 'not_empty',
};

// A string literal default value ('text'); other expressions start empty.
const defaultText = (value: unknown): string => {
  const source = typeof value === 'string' ? value.trim() : '';
  return /^'(?:[^']|'')*'$/.test(source) ? source.slice(1, -1).replaceAll("''", "'") : '';
};

// Data grid 2 text filter in the filters placeholder: after the configured
// delay it searches the grid's string filter attributes, any of which may match.
export function MarketplaceGridTextFilter(props: MarketplaceWidgetProps) {
  const grid = useContext(DataGridFilters);
  const properties = (props.widget.options?.properties || {}) as Properties;
  const id = useId();
  const [operator, setOperator] = useState(
    OPERATORS[String(properties.defaultFilter)] ?? 'contains',
  );
  const [value, setValue] = useState(() => defaultText(properties.defaultValue));
  const applied = useRef(value);
  const delay = Math.max(0, Number(properties.delay ?? 500)) || 0;
  // The latest props, so re-renders do not restart the delay.
  const latest = useRef(props);
  latest.current = props;

  useEffect(() => {
    if (!grid) return;
    const timer = setTimeout(() => {
      grid.setFilter(id, { operator, value });
      if (applied.current === value) return;
      applied.current = value;
      const { widget, onChange, onAction, context } = latest.current;
      const current = (widget.options?.properties || {}) as Properties;
      const attribute = String(current.valueAttribute || '');
      const action = marketplaceAction(current.onChange);
      void (async () => {
        if (attribute) await onChange(attribute, value);
        if (action) await onAction?.(action, context);
      })();
    }, delay);
    return () => clearTimeout(timer);
  }, [grid, id, operator, value, delay]);
  useEffect(() => () => grid?.setFilter(id, null), [grid, id]);

  if (!grid)
    return (
      <div className="alert alert-danger">
        The Text filter widget must be placed inside the header of the Data grid 2.0 or Gallery
        widget.
      </div>
    );
  if (!grid.attributes.length)
    return (
      <div className="alert alert-danger">
        The Text filter widget can&apos;t be used with the filters options you have selected. It
        requires a &quot;Hashed string or String&quot; attribute to be selected.
      </div>
    );
  const empty = ['empty', 'not_empty'].includes(operator);
  return (
    <div className="filter-container" data-focusindex={0}>
      {properties.adjustable === true ? (
        <OperatorSelector config={{ type: 'text', operator, options: [] }} onSelect={setOperator} />
      ) : null}
      <input
        className="form-control filter-input"
        aria-label={String(properties.screenReaderInputCaption || '') || undefined}
        placeholder={String(properties.placeholder || '') || undefined}
        type="text"
        value={empty ? '' : value}
        disabled={empty}
        onChange={(event) => setValue(event.target.value)}
      />
    </div>
  );
}
