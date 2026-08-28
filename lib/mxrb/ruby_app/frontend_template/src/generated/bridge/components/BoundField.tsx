import { useEffect, useState } from 'react';
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
  onError,
}: BoundFieldProps) {
  const options = widget.options || {};
  const member = memberName(options.attribute || widget.name);
  const kind = widget.type;
  const value = recordValue(record, member);
  const [draft, setDraft] = useState<string | number | boolean>(
    kind === 'check_box' ? Boolean(value) : draftValue(value),
  );
  const [references, setReferences] = useState<EntityRecord[]>([]);
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
    setDraft(kind === 'check_box' ? Boolean(value) : draftValue(value));
  }, [kind, record?.id, value]);

  useEffect(() => {
    if (kind !== 'reference_selector' || !referenceEntity) return;
    request<EntityCollectionResponse>(`/api/entities/${encodeURIComponent(referenceEntity)}`)
      .then((payload) => setReferences(payload.records || []))
      .catch(onError);
  }, [kind, referenceEntity, revision, request, onError]);

  const persist = (next: string | number | boolean) => {
    setDraft(next);
    if (!record?.type || !record.id || !member) return Promise.resolve(record);
    let normalized: RuntimeValue = next;
    if (kind === 'number_input') normalized = next === '' ? null : Number(next);
    if (kind === 'reference_selector') {
      normalized = references.find((item) => item.id === next) || null;
    }
    return saveRecord(record, { [member]: normalized }).then((updated) => {
      if (!updated) return null;
      if (onChanged) return onChanged(updated);
      return updated;
    });
  };
  const disabled = !record?.id || !member || options.read_only === true;

  if (kind === 'text_area') {
    return (
      <textarea
        rows={options.lines || 4}
        value={String(draft)}
        disabled={disabled}
        onChange={(event) => setDraft(event.target.value)}
        onBlur={() => persist(draft)}
      />
    );
  }
  if (kind === 'check_box') {
    return (
      <input
        type="checkbox"
        checked={Boolean(draft)}
        disabled={disabled}
        onChange={(event) => persist(event.target.checked)}
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
        value={String(draft)}
        disabled={disabled}
        onChange={(event) => persist(event.target.value)}
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
  const inputType = kind === 'date_picker' ? 'date' : kind === 'number_input' ? 'number' : 'text';
  const inputValue =
    inputType === 'date'
      ? String(draft).slice(0, 10)
      : typeof draft === 'boolean'
        ? String(draft)
        : draft;
  return (
    <input
      type={inputType}
      value={inputValue}
      disabled={disabled}
      onChange={(event) => setDraft(event.target.value)}
      onBlur={() => persist(draft)}
    />
  );
}
