import { useContext, useEffect, useId, useRef, useState } from 'react';
import { ClientActions } from '../PageEdits';
import { LocalVariables, PageParameterBindings, SnippetParameterBindings } from '../PageVariables';
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
  id?: string;
  widget: WidgetDefinition;
  record: EntityRecord | null;
  schema: ApplicationSchema;
  request: ApiRequest;
  saveRecord: SaveRecord;
  revision: number;
  onChanged?: (record: EntityRecord | null) => unknown;
  onEntered?: (record: EntityRecord | null) => unknown;
  onLeft?: (record: EntityRecord | null) => unknown;
  onError: ErrorHandler;
}

export function BoundField({
  id,
  widget,
  record: suppliedRecord,
  schema,
  request,
  saveRecord: suppliedSaveRecord,
  revision,
  onChanged,
  onEntered,
  onLeft,
  onError,
}: BoundFieldProps) {
  const fieldId = useId();
  const actions = useContext(ClientActions);
  const options = widget.options || {};
  const locals = useContext(LocalVariables);
  const pageBindings = useContext(PageParameterBindings);
  const snippetBindings = useContext(SnippetParameterBindings);
  const source = options.source_variable as { kind?: string; name?: string } | undefined;
  const bindings =
    source?.kind === 'page_parameter'
      ? pageBindings
      : source?.kind === 'snippet_parameter'
        ? snippetBindings
        : locals;
  const local =
    source && ['local_variable', 'page_parameter', 'snippet_parameter'].includes(source.kind || '')
      ? memberName(source.name || '')
      : '';
  const boundValue = local ? bindings.values[local] : undefined;
  const primitive = !!local && !isEntityRecord(boundValue);
  const record = isEntityRecord(boundValue)
    ? actions?.edits.resolve(boundValue) || boundValue
    : local
      ? {
          id: local,
          type: '$Local',
          attributes: { [memberName(options.attribute || widget.name)]: bindings.values[local] },
        }
      : suppliedRecord;
  const saveRecord: SaveRecord = primitive
    ? async (current, changes) => {
        bindings.set(local, Object.values(changes)[0]);
        return current ? { ...current, attributes: { ...current.attributes, ...changes } } : null;
      }
    : suppliedSaveRecord;
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
  const recordKey = `${record?.type}/${record?.id}/${kind}/${member}`;
  const sourceKey = useRef(recordKey);
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
  const boundType = primitive ? bindings.types?.[local] : undefined;
  const attributeDefinition = boundType
    ? { name: member, type: boundType.kind, enumeration: boundType.enumeration }
    : (entityDefinition?.attributes || []).find((attribute) => attribute.name === member);
  const enumeration = (schema.modules || [])
    .flatMap((module) => module.enumerations || [])
    .find(
      (item) =>
        item.id === attributeDefinition?.enumeration ||
        item.name === attributeDefinition?.enumeration,
    );
  const radioChoices =
    attributeDefinition?.type.toLowerCase() === 'boolean'
      ? [
          { value: true, label: 'Yes' },
          { value: false, label: 'No' },
        ]
      : (enumeration?.values || []).map((item) => ({
          value: item.name,
          label: item.caption || item.name,
        }));
  const enumPrefix = enumeration ? `${enumeration.name}.` : '';
  const radioValue = (candidate: string | number | boolean) =>
    enumPrefix && typeof candidate === 'string' && candidate.startsWith(enumPrefix)
      ? candidate.slice(enumPrefix.length)
      : candidate;

  useEffect(() => {
    const next = kind === 'check_box' ? Boolean(value) : draftValue(value);
    const previous = committed.current;
    const changedSource = sourceKey.current !== recordKey;
    sourceKey.current = recordKey;
    committed.current = next;
    // Initialization and delayed server responses must not erase a newer draft.
    // Selecting another record/member deliberately starts a fresh draft.
    setDraft((current) => (changedSource || current === previous ? next : current));
  }, [kind, recordKey, value]);
  useEffect(() => {
    latestRecord.current = record;
  }, [record]);

  useEffect(() => {
    if (kind !== 'reference_selector' || !referenceEntity) return;
    request<EntityCollectionResponse>(`/api/entities/${encodeURIComponent(referenceEntity)}`)
      .then((payload) => setReferences(payload.records || []))
      .catch(onError);
  }, [kind, referenceEntity, revision, request, onError]);

  const disabled = !record?.id || !member || inheritedReadOnly || !editable(options, record, schema.module_roles);
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
        await onChanged?.(primitive ? suppliedRecord : updated);
        return updated;
      });
    pending.current = task;
    return task;
  };
  const flushField = useRef<() => Promise<unknown>>(async () => {});
  flushField.current = () => persist(draft);
  useEffect(() => {
    if (!actions) return;
    const flush = () => flushField.current();
    actions.edits.fields.add(flush);
    return () => {
      actions.edits.fields.delete(flush);
    };
  }, [actions?.edits]);
  const resetVersion = useRef(actions?.reset);
  useEffect(() => {
    if (resetVersion.current === actions?.reset) return;
    resetVersion.current = actions?.reset;
    const next = kind === 'check_box' ? Boolean(value) : draftValue(value);
    committed.current = next;
    setDraft(next);
  }, [actions?.reset]);

  const changed = (next: string | number | boolean) => {
    void persist(next).catch(onError);
  };
  const blur = () => {
    void persist(draft)
      .then((updated) => updated && onLeft?.(primitive ? suppliedRecord : updated))
      .catch(onError);
  };
  const focus = () => {
    if (!disabled && record) {
      void Promise.resolve()
        .then(() => onEntered?.(primitive ? suppliedRecord : record))
        .catch(onError);
    }
  };
  const controlProps = {
    id: id || fieldId,
    className: kind === 'check_box' ? undefined : 'form-control',
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
        {options.password === true && value
          ? '••••••••'
          : kind === 'radio_button_group'
            ? (radioChoices.find((item) => item.value === radioValue(draftValue(value)))?.label ??
              String(value ?? ''))
            : displayValue(value)}
      </span>
    );
  }

  if (kind === 'radio_button_group') {
    if (!radioChoices.length)
      return (
        <span role="alert">Cannot resolve choices for {options.attribute || widget.name}</span>
      );
    return (
      <div
        role="radiogroup"
        aria-label={
          typeof options.aria_label === 'string' && options.aria_label
            ? options.aria_label
            : options.caption || widget.name
        }
        aria-required={options.aria_required === true}
        style={{
          display: 'flex',
          flexDirection: options.horizontal === true ? 'row' : 'column',
          gap: '0.5rem',
        }}
        onFocus={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget)) focus();
        }}
        onBlur={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget)) blur();
        }}
      >
        {radioChoices.map((choice) => (
          <label key={String(choice.value)}>
            <input
              type="radio"
              name={fieldId}
              disabled={disabled}
              tabIndex={typeof options.tab_index === 'number' ? options.tab_index : undefined}
              value={String(choice.value)}
              checked={radioValue(draft) === choice.value}
              onChange={() =>
                changed(
                  enumPrefix && typeof draft === 'string' && draft.startsWith(enumPrefix)
                    ? `${enumPrefix}${choice.value}`
                    : choice.value,
                )
              }
            />
            {choice.label}
          </label>
        ))}
        {draft !== '' && !radioChoices.some((choice) => choice.value === radioValue(draft)) && (
          <span role="status">Unknown choice: {String(draft)}</span>
        )}
      </div>
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
