import { createContext, useContext, useEffect, useRef, useState } from 'react';
import type {
  ApiRequest,
  DataViewSource,
  EntityCollectionResponse,
  EntityRecord,
  InvocationResult,
  RuntimeValue,
  RuntimeVariables,
} from '../types';
import type { InvokeHandler } from './contracts';
import { LocalVariables, PageParameters } from './PageVariables';
import { useSelections } from './components/SelectionScope';
import { VariableScope } from './components/VariableScope';
import {
  entityCollectionPath,
  eventArguments,
  isEntityRecord,
  memberName,
  type EventArgumentSources,
} from './value';

// Client nanoflows for data sources rendered outside a widget's prop chain.
export const ListSourceNanoflows = createContext<InvokeHandler | null>(null);

// The variables a data source's parameter mappings may read.
export function useSourceScopes(pageContext: EntityRecord | null): EventArgumentSources {
  const selections = useSelections();
  const pageParameters = useContext(PageParameters);
  const localVariables = useContext(LocalVariables);
  const variables = useContext(VariableScope);
  return {
    pageParameter: pageContext,
    pageParameters,
    localVariables: localVariables.values,
    snippetParameters: variables,
    widgetValues: { ...selections.records, ...selections.lists },
  };
}

// A microflow or nanoflow source's arguments, by parameter name.
export function sourceMappings(
  source: DataViewSource | undefined,
  context: EntityRecord | null,
  scopes: EventArgumentSources,
): RuntimeVariables {
  return Object.fromEntries(
    (source?.mappings || []).map((mapping) => {
      const parameter =
        String(mapping.parameter || '')
          .split('.')
          .pop() || '';
      const value = (mapping.variable || String(mapping.expression || '')) as RuntimeValue;
      const event = { event: 'source', kind: 'source', handler: '', arguments: { value } };
      return [parameter, eventArguments(event, context, scopes).value];
    }),
  );
}

// The object an association source starts from: its variable, else the context.
export function sourceStart(
  source: DataViewSource,
  context: EntityRecord | null,
  scopes: EventArgumentSources,
): EntityRecord | null {
  const variable = source.variable;
  if (!variable?.name) return context;
  const name = memberName(variable.name);
  const value =
    variable.kind === 'page_parameter'
      ? scopes.pageParameters?.[name]
      : variable.kind === 'local_variable'
        ? scopes.localVariables?.[name]
        : variable.kind === 'widget'
          ? scopes.widgetValues?.[name]
          : scopes.snippetParameters?.[name];
  return isEntityRecord(value) ? value : null;
}

const entityRecords = (value: unknown): EntityRecord[] =>
  (Array.isArray(value) ? value : [value]).filter(isEntityRecord);

// Loads the objects of a microflow, nanoflow or association list source.
export async function loadListSource(
  source: DataViewSource,
  start: EntityRecord | null,
  mappings: RuntimeVariables,
  request: ApiRequest,
  invokeNanoflow: InvokeHandler | null,
): Promise<EntityRecord[]> {
  if (source.kind === 'microflow' && source.name) {
    const payload = await request<InvocationResult>(
      `/api/microflows/${encodeURIComponent(source.name)}`,
      {
        method: 'POST',
        body: JSON.stringify({ ...mappings, ...(start ? { __mxrb_context: start } : {}) }),
      },
    );
    return entityRecords(payload.result);
  }
  if (source.kind === 'nanoflow' && source.name) {
    if (!invokeNanoflow) throw new Error(`Nanoflow data source ${source.name} cannot run here`);
    return entityRecords(await invokeNanoflow(source.name, mappings, start));
  }
  if (source.kind === 'association') {
    const steps = source.steps || [];
    if (!steps.length || steps.some((step) => !step.entity || !step.association))
      throw new Error(
        'association source must declare its association and destination at each step',
      );
    // Never turn an empty association into an unscoped entity query.
    let objects = start ? [start] : [];
    for (const step of steps) {
      const reached = await Promise.all(
        objects.map((object) =>
          request<EntityCollectionResponse>(
            entityCollectionPath(step.entity!, step.association, object),
          ).then((payload) => payload.records || []),
        ),
      );
      const seen = new Set<string>();
      objects = reached.flat().filter((record) => {
        const key = `${record.type}/${record.id}`;
        return !seen.has(key) && Boolean(seen.add(key));
      });
    }
    return objects;
  }
  throw new Error(`unsupported list data source ${source.kind}`);
}

export interface ListSourceRecords {
  records: EntityRecord[];
  loading: boolean;
  error?: string;
}

// The objects of a microflow, nanoflow or association list source, reloaded
// when its arguments, start object or the server data change.
export function useListSource(
  source: DataViewSource | undefined,
  context: EntityRecord | null,
  pageContext: EntityRecord | null,
  request: ApiRequest | undefined,
  revision = 0,
): ListSourceRecords {
  const scopes = useSourceScopes(pageContext);
  // The page passes a new invoker on every render, and running a nanoflow
  // renders the page again: the latest one runs, but only the key reloads.
  const invokeNanoflow = useRef(useContext(ListSourceNanoflows));
  invokeNanoflow.current = useContext(ListSourceNanoflows);
  const start = source ? sourceStart(source, context, scopes) : null;
  const mappings = source ? sourceMappings(source, context, scopes) : {};
  const key = JSON.stringify([source, start?.type, start?.id, mappings, revision]);
  const [state, setState] = useState<ListSourceRecords & { key: string }>({
    key: '',
    records: [],
    loading: true,
  });
  useEffect(() => {
    if (!source || !request) return;
    let active = true;
    const [, , , values] = JSON.parse(key) as [unknown, unknown, unknown, RuntimeVariables];
    loadListSource(source, start, values, request, invokeNanoflow.current)
      .then((records) => active && setState({ key, records, loading: false }))
      .catch(
        (failure: unknown) =>
          active && setState({ key, records: [], loading: false, error: String(failure) }),
      );
    return () => {
      active = false;
    };
    // The key captures the source, its start object, arguments and revision.
  }, [key, request]);
  if (!source) return { records: [], loading: false };
  return state.key === key ? state : { records: [], loading: true };
}
