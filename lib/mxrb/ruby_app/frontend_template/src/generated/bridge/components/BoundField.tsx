import { useContext, useEffect, useRef, useState } from 'react';
import { editable, ReadOnlyContext, ReadOnlyStyleContext } from './FieldPolicy';
import type {
  ApiRequest,
  ApplicationSchema,
  EntityCollectionResponse,
  EntityRecord,
  RuntimeValue,
  WidgetDefinition,
} from '../../types';
import type { ErrorHandler, SaveRecord } from '../contracts';
import {
  choiceValue,
  displayValue,
  draftValue,
  isEntityRecord,
  memberName,
  recordValue,
} from '../value';

interface BoundFieldProps {
  widget: WidgetDefinition;
  record: EntityRecord | null;
  schema: ApplicationSchema;
  request: ApiRequest;
  saveRecord: SaveRecord;
  revision: number;
  onChanged?: (record: EntityRecord) => unknown;
  onEntered?: (record: EntityRecord) => unknown;
  onLeft?: (record: EntityRecord) => unknown;
  onError: ErrorHandler;
}

export function BoundField({
  widget,
  record,
  schema,
  request,
  saveRecord,
  revision,
  onChanged,
  onEntered,
  onLeft,
  onError,
}: BoundFieldProps) {
  const options = widget.options || {};
  const inheritedReadOnly = useContext(ReadOnlyContext);
  const inheritedReadOnlyStyle = useContext(ReadOnlyStyleContext);
  const member = memberName(options.attribute || widget.name);
  const kind = widget.type;
  const value = recordValue(record, member);
  const [draft, setDraft] = useState<string | number | boolean>(
    kind === 'check_box' ? Boolean(value) : draftValue(value),
  );
  const [references, setReferences] = useState<EntityRecord[]>([]);
  const committed = useRef(draft);
  const latestRecord = useRef(record);
  const pending = useRef<Promise<EntityRecord | null>>(Promise.resolve(record));
  const associations = (schema.modules || []).flatMap((module) => module.associations || []);
  const association = associations.find(
    (item) => item.name === options.attribute || memberName(item.name) === member,
  );
  const referenceEntity = options.entity || options.target_entity || association?.to_entity;
  const entityDefinition = (schema.modules || [])
    .flatMap((module) => [...(module.models || []), ...(module.dtos || [])])
    .find((entity) => entity.name === record?.type);
  const attributeDefinition = (entityDefinition?.attributes || []).find(
    (attribute) => attribute.name === member,
  );
  const enumeration = (schema.modules || [])
    .flatMap((module) => module.enumerations || [])
    .find(
      (item) =>
        item.id === attributeDefinition?.enumeration ||
        item.name === attributeDefinition?.enumeration,
    );

  useEffect(() => {
    const next = kind === 'check_box' ? Boolean(value) : draftValue(value);
    committed.current = next;
    setDraft(next);
  }, [kind, record?.id, value]);
  useEffect(() => {
    latestRecord.current = record;
  }, [record]);

  useEffect(() => {
    if (kind !== 'reference_selector' || !referenceEntity) return;
    request<EntityCollectionResponse>(`/api/entities/${encodeURIComponent(referenceEntity)}`)
      .then((payload) => setReferences(payload.records || []))
      .catch(onError);
  }, [kind, referenceEntity, revision, request, onError]);

  const disabled = !record?.id || !member || inheritedReadOnly || !editable(options, record);
  const persist = async (next: string | number | boolean): Promise<EntityRecord | null> => {
    if (disabled || !record) return null;
    setDraft(next);
    let normalized: RuntimeValue = next;
    if (kind === 'number_input') normalized = next === '' ? null : Number(next);
    if (kind === 'reference_selector') {
      normalized = references.find((item) => item.id === next) || null;
    }
    const task = pending.current
      .catch(() => null)
      .then(async () => {
        if (latestRecord.current?.id !== record.id) return null;
        if (next === committed.current) return latestRecord.current;
        const updated = await saveRecord(latestRecord.current, { [member]: normalized });
        if (!updated) return null;
        committed.current = next;
        latestRecord.current = updated;
        await onChanged?.(updated);
        return updated;
      });
    pending.current = task;
    return task;
  };
  const changed = (next: string | number | boolean) => {
    void persist(next).catch(onError);
  };
  const blur = () => {
    void persist(draft)
      .then((updated) => updated && onLeft?.(updated))
      .catch(onError);
  };
  const focus = () => {
    if (!disabled && record) {
      void Promise.resolve()
        .then(() => onEntered?.(record))
        .catch(onError);
    }
  };
  const controlProps = {
    disabled,
    onFocus: focus,
    onBlur: blur,
    'aria-label':
      typeof options.aria_label === 'string' && options.aria_label ? options.aria_label : undefined,
    'aria-required': options.aria_required === true,
    tabIndex: typeof options.tab_index === 'number' ? options.tab_index : undefined,
  };
  const textProps = {
    placeholder: typeof options.placeholder === 'string' ? options.placeholder : undefined,
    maxLength:
      typeof options.max_length === 'number' && options.max_length > 0
        ? options.max_length
        : undefined,
    autoComplete: typeof options.autocomplete === 'string' ? options.autocomplete : undefined,
  };

  const readOnlyStyle =
    options.read_only_style === 'text' || options.read_only_style === 'control'
      ? options.read_only_style
      : inheritedReadOnlyStyle;
  if (disabled && readOnlyStyle === 'text') {
    return (
      <span className="mxrb-field-read-only">
        {options.password === true && value ? '••••••••' : displayValue(value)}
      </span>
    );
  }

  if (kind === 'text_area') {
    return (
      <textarea
        {...controlProps}
        {...textProps}
        rows={options.lines || 4}
        value={String(draft)}
        onChange={(event) => setDraft(event.target.value)}
      />
    );
  }
  if (kind === 'check_box') {
    return (
      <input
        {...controlProps}
        type="checkbox"
        checked={Boolean(draft)}
        onChange={(event) => changed(event.target.checked)}
      />
    );
  }
  if (kind === 'drop_down' || kind === 'reference_selector') {
    const enumValues = (enumeration?.values || []).map((item) => ({
      id: item.name,
      label: item.caption || item.name,
    }));
    const configuredValue = options.values || options.items || options.options || enumValues;
    const configured: RuntimeValue[] = Array.isArray(configuredValue)
      ? configuredValue
      : configuredValue
        ? Object.values(configuredValue)
        : [];
    const choices: RuntimeValue[] = kind === 'reference_selector' ? references : configured;
    return (
      <select
        {...controlProps}
        value={String(draft)}
        onChange={(event) => changed(event.target.value)}
      >
        <option value="">—</option>
        {draft &&
        !choices.some(
          (item) => (choiceValue(item, 'id') || choiceValue(item, 'value') || item) === draft,
        ) ? (
          <option value={String(draft)}>{displayValue(value)}</option>
        ) : null}
        {choices.map((item, index) => (
          <option
            key={String(choiceValue(item, 'id') || choiceValue(item, 'value') || index)}
            value={String(choiceValue(item, 'id') || choiceValue(item, 'value') || item)}
          >
            {displayValue(
              choiceValue(item, 'label') ||
                choiceValue(item, 'caption') ||
                (isEntityRecord(item) ? recordValue(item, options.display_attribute) : undefined) ||
                choiceValue(item, 'id') ||
                choiceValue(item, 'value') ||
                item,
            )}
          </option>
        ))}
      </select>
    );
  }
  const inputType =
    kind === 'date_picker'
      ? 'date'
      : kind === 'number_input'
        ? 'number'
        : options.password === true
          ? 'password'
          : 'text';
  const inputValue =
    inputType === 'date'
      ? String(draft).slice(0, 10)
      : typeof draft === 'boolean'
        ? String(draft)
        : draft;
  return (
    <input
      {...controlProps}
      {...textProps}
      type={inputType}
      value={inputValue}
      onChange={(event) => setDraft(event.target.value)}
    />
  );
}
