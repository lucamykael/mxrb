import { useState, type KeyboardEvent } from 'react';
import type { EntityRecord } from '../../types';
import { chartCaption, useCaptionEnvironment } from '../captions';
import type { MarketplaceWidgetProps } from '../marketplace';
import { memberName } from '../value';
import { marketplaceAction, useMarketplaceRecords } from './marketplaceData';

type Properties = Record<string, unknown>;

const propertiesOf = (props: MarketplaceWidgetProps) =>
  (props.widget.options?.properties || {}) as Properties;
const attributeOf = (value: unknown) => memberName(String(value || ''));
const text = (record: EntityRecord, attribute: unknown) =>
  String(record.attributes[attributeOf(attribute)] ?? '');

// Tag selector: the tag text goes to the context object's tag label attribute,
// then the select, create, remove or remove-all action runs.
export function MarketplaceTagSelector(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const current = useMarketplaceRecords(properties.currentTags, props);
  const suggestions = useMarketplaceRecords(properties.tagSuggestions, props);
  const [input, setInput] = useState('');
  const labelAttribute = String(properties.tagLabel || '');
  const tags = current.records.map((record) => text(record, properties.currentTagLabel));
  const perform = async (actionProperty: unknown, label: string) => {
    const action = marketplaceAction(actionProperty);
    if (!action) return;
    if (labelAttribute) await props.onChange(labelAttribute, label);
    await props.onAction?.(action, props.context);
  };
  const choices = suggestions.records
    .map((record) => text(record, properties.tagSuggestionsLabel))
    .filter(
      (label) => !tags.includes(label) && label.toLowerCase().includes(input.trim().toLowerCase()),
    );
  const submit = async () => {
    const label = input.trim().replace(/[, ]$/, '');
    if (!label) return;
    setInput('');
    if (choices.includes(label)) return perform(properties.selectTag, label);
    if (properties.enableCreate !== false) return perform(properties.createTag, label);
  };
  const keyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    const separator =
      (event.key === ',' && properties.enableComma === true) ||
      (event.key === ' ' && properties.enableSpace === true);
    if (event.key === 'Enter' || separator) {
      event.preventDefault();
      void submit();
    } else if (event.key === 'Backspace' && !input && tags.length) {
      void perform(properties.removeTag, tags[tags.length - 1]);
    }
  };
  if (current.error || suggestions.error)
    return <p role="alert">{current.error || suggestions.error}</p>;
  return (
    <div className={['mxrb-tag-selector', String(properties.className || '')].join(' ').trim()}>
      <ul aria-label="Selected tags">
        {tags.map((tag) => (
          <li key={tag}>
            {tag}
            <button
              type="button"
              aria-label={`Remove ${tag}`}
              onClick={() => perform(properties.removeTag, tag)}
            >
              ×
            </button>
          </li>
        ))}
      </ul>
      <input
        aria-label={props.widget.name}
        list={`${props.widget.name}-suggestions`}
        placeholder={String(properties.placeholder || '')}
        value={input}
        onChange={(event) => setInput(event.target.value)}
        onKeyDown={keyDown}
      />
      <datalist id={`${props.widget.name}-suggestions`}>
        {choices.map((choice) => (
          <option key={choice} value={choice} />
        ))}
      </datalist>
      {tags.length > 0 && properties.removeAllTags ? (
        <button type="button" onClick={() => perform(properties.removeAllTags, '')}>
          Clear
        </button>
      ) : null}
    </div>
  );
}

interface Option {
  title: string;
  key?: unknown;
}

const sameOption = (left: Option, right: Option) =>
  left.key !== undefined || right.key !== undefined
    ? left.key === right.key
    : left.title === right.title;

// Autocomplete multiselect: options from a data source; the selection is stored as
// JSON ({ title, key }) in the response attribute, then the change action runs.
export function MarketplaceAutocomplete(props: MarketplaceWidgetProps) {
  const properties = propertiesOf(props);
  const environment = useCaptionEnvironment(props.schema);
  const source = useMarketplaceRecords(properties.dataSourceOptions, props);
  const multiple = properties.multiple !== false;
  const [query, setQuery] = useState('');
  const options: Array<Option & { record: EntityRecord }> = source.records.map((record) => ({
    title: text(record, properties.titleAttr),
    ...(properties.keyAttr ? { key: record.attributes[attributeOf(properties.keyAttr)] } : {}),
    record,
  }));
  const stored = props.context?.attributes[attributeOf(properties.responseAttribute)];
  const defaults = props.context?.attributes[attributeOf(properties.defaultSelectedStringAttr)];
  const parse = (value: unknown): Option[] | undefined => {
    if (typeof value !== 'string' || !value) return undefined;
    try {
      const parsed = JSON.parse(value) as Option | Option[] | null;
      return parsed === null ? [] : Array.isArray(parsed) ? parsed : [parsed];
    } catch {
      return undefined;
    }
  };
  const initial =
    parse(stored) ??
    parse(defaults) ??
    options
      .filter(
        (option) => option.record.attributes[attributeOf(properties.defaultSelectedAttr)] === true,
      )
      .map(({ title, key }) => ({ title, ...(key !== undefined ? { key } : {}) }));
  const selected = options.filter((option) => initial.some((item) => sameOption(item, option)));
  const store = async (next: Option[]) => {
    const plain = next.map(({ title, key }) => ({ title, ...(key !== undefined ? { key } : {}) }));
    await props.onChange(
      String(properties.responseAttribute || ''),
      JSON.stringify(multiple ? plain : (plain[0] ?? null)),
    );
    const action = marketplaceAction(properties.onChangeAction);
    if (action) await props.onAction?.(action, props.context);
  };
  const toggle = (option: Option) =>
    store(
      selected.some((item) => sameOption(item, option))
        ? selected.filter((item) => !sameOption(item, option))
        : multiple
          ? [...selected, option]
          : [option],
    );
  if (source.error) return <p role="alert">{source.error}</p>;
  const visible = options.filter((option) =>
    option.title.toLowerCase().includes(query.trim().toLowerCase()),
  );
  return (
    <div className="mxrb-autocomplete">
      <label>
        {chartCaption(properties.label, props.context, environment)}
        <input
          role="combobox"
          aria-expanded="true"
          placeholder={chartCaption(properties.placeholder, props.context, environment)}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
      </label>
      <ul aria-label="Selected">
        {selected.map((option) => (
          <li key={`${option.title}:${String(option.key)}`}>
            {option.title}
            <button
              type="button"
              aria-label={`Remove ${option.title}`}
              onClick={() => toggle(option)}
            >
              ×
            </button>
          </li>
        ))}
      </ul>
      <ul role="listbox" aria-multiselectable={multiple}>
        {visible.length === 0 ? (
          <li>
            {chartCaption(properties.noOptionsText, props.context, environment) || 'No options'}
          </li>
        ) : (
          visible.map((option) => (
            <li
              key={`${option.title}:${String(option.key)}`}
              role="option"
              aria-selected={selected.some((item) => sameOption(item, option))}
              onClick={() => toggle(option)}
            >
              {option.title}
            </li>
          ))
        )}
      </ul>
    </div>
  );
}
