import { decimal, isDecimal, numericText } from '../decimal';
import { useContext } from 'react';
import type { CSSProperties } from 'react';
import type { MarketplaceWidgetProps } from '../marketplace';
import { ReadOnlyContext, editable } from './FieldPolicy';
import { expressionValue, memberName } from '../value';

export const marketplaceValue = (value: unknown, props: MarketplaceWidgetProps): unknown =>
  typeof value === 'string' && (value.startsWith('$') || value.startsWith("'"))
    ? expressionValue(value, props.context)
    : value;

export function MarketplaceImage(props: MarketplaceWidgetProps) {
  const properties = props.widget.options?.properties || {};
  const image = String(properties.imageObject || properties.image || '');
  const url = String(marketplaceValue(properties.imageUrl || properties.url || '', props) || '');
  const source = props.schema?.presentation?.[image]?.path || url;
  const safe = /^(?:https?:\/\/|\/[^/]|blob:)/i.test(source);
  const size = (value: unknown, unit: unknown) =>
    unit === 'auto' || value === undefined
      ? undefined
      : `${Number(value)}${unit === 'percentage' ? '%' : 'px'}`;
  const style: CSSProperties = {
    width: size(properties.width, properties.widthUnit),
    height: size(properties.height, properties.heightUnit),
    maxWidth: properties.responsive === false ? undefined : '100%',
    objectFit: properties.displayAs === 'thumbnail' ? 'contain' : undefined,
  };
  const alt = String(
    properties.alternativeText || props.widget.options?.caption || props.widget.name,
  );
  if (!safe)
    return (
      <span role="status">{source ? 'Invalid image URL' : `Missing image: ${image || alt}`}</span>
    );
  const imageElement = <img src={source} alt={alt} style={style} />;
  if (properties.isBackgroundImage)
    return (
      <div style={{ ...style, backgroundImage: `url(${JSON.stringify(source)})` }}>
        {props.children}
      </div>
    );
  return props.onClick ? (
    <button type="button" onClick={props.onClick}>
      {imageElement}
    </button>
  ) : (
    imageElement
  );
}

export function MarketplaceControl(props: MarketplaceWidgetProps) {
  const { widget, context, onChange, schema } = props;
  const p = widget.options?.properties || {};
  const id = String(widget.options?.widget_id).toLowerCase();
  const inheritedReadOnly = useContext(ReadOnlyContext);
  const disabled =
    inheritedReadOnly ||
    !context ||
    p.editable === 'never' ||
    p.editable === false ||
    !editable(widget.options || {}, context, schema?.module_roles);
  const label = String(p.label || widget.options?.caption || widget.name);
  const number = (value: unknown, fallback: number) => {
    const resolved = marketplaceValue(value, props) ?? fallback;
    const parsed = Number(isDecimal(resolved) ? numericText(resolved) : resolved);
    if (!Number.isFinite(parsed)) throw new Error(`Invalid numeric property in ${widget.name}`);
    return parsed;
  };
  const read = (attribute: unknown, fallback: unknown = 0) =>
    context?.attributes[memberName(String(attribute || ''))] ?? fallback;
  const write = (attribute: unknown, value: string | number) => {
    if (disabled || typeof attribute !== 'string' || !attribute) return;
    const field = schema?.modules
      .flatMap((module) => [...(module.models || []), ...(module.dtos || [])])
      .find((entity) => entity.name === context?.type)
      ?.attributes?.find((entry) => entry.name === memberName(attribute));
    const exact =
      typeof value === 'number' && (isDecimal(read(attribute)) || field?.type === 'decimal');
    return onChange(attribute, exact ? decimal(value) : value);
  };
  const minimum = number(p.minimumValue, 0);
  const maximum = number(p.maximumValue, 100);
  if (id.includes('progress')) {
    const value = number(p.progressValue ?? read(p.progressAttribute ?? p.valueAttribute), 0);
    return (
      <label>
        {label}
        <progress aria-label={label} value={Math.max(0, value - minimum)} max={maximum - minimum}>
          {value}
        </progress>
      </label>
    );
  }
  if (id.includes('colorpicker'))
    return (
      <label>
        {label}
        <input
          aria-label={label}
          type="color"
          disabled={disabled}
          value={String(read(p.color, '#000000'))}
          onChange={(event) => write(p.color, event.target.value)}
        />
      </label>
    );
  if (id.includes('togglebuttons')) {
    const attribute = String(p.enum || '');
    const member = memberName(attribute);
    const entity = schema?.modules
      .flatMap((module) => [...(module.models || []), ...(module.dtos || [])])
      .find((model) => model.name === context?.type);
    const enumeration = entity?.attributes?.find((field) => field.name === member)?.enumeration;
    const values =
      schema?.modules
        .flatMap((module) => module.enumerations || [])
        .find((value) => value.name === enumeration)?.values || [];
    return (
      <fieldset disabled={disabled}>
        <legend>{label}</legend>
        {values.map((value) => (
          <button
            key={value.name}
            type="button"
            aria-pressed={read(attribute) === value.name}
            onClick={() => write(attribute, value.name)}
          >
            {value.caption}
          </button>
        ))}
      </fieldset>
    );
  }
  if (id.endsWith('.rating') || id.includes('starrating')) {
    const maximumRating = number(p.maximumValue, 5);
    const attribute = p.ratingAttribute ?? p.rateAttribute;
    return (
      <fieldset disabled={disabled}>
        <legend>{label}</legend>
        {Array.from({ length: Math.min(100, Math.max(0, maximumRating)) }, (_, i) => i + 1).map(
          (value) => (
            <button
              key={value}
              type="button"
              aria-label={`${value} stars`}
              aria-pressed={value <= number(read(attribute), 0)}
              onClick={() => write(attribute, value)}
            >
              {value <= number(read(attribute), 0) ? '★' : '☆'}
            </button>
          ),
        )}
      </fieldset>
    );
  }
  const slider = (attribute: unknown, caption: string, min: number, max: number) => (
    <label>
      {caption}
      <input
        aria-label={caption}
        type="range"
        disabled={disabled}
        min={min}
        max={max}
        step={number(p.stepSize, 1)}
        value={number(read(attribute, min), min)}
        onChange={(event) => write(attribute, Number(event.target.value))}
      />
    </label>
  );
  if (id.includes('rangeslider'))
    return (
      <fieldset disabled={disabled}>
        <legend>{label}</legend>
        {slider(
          p.lowerValueAttribute,
          `${label} minimum`,
          minimum,
          number(read(p.upperValueAttribute, maximum), maximum),
        )}
        {slider(
          p.upperValueAttribute,
          `${label} maximum`,
          number(read(p.lowerValueAttribute, minimum), minimum),
          maximum,
        )}
      </fieldset>
    );
  return slider(p.valueAttribute, label, minimum, maximum);
}
