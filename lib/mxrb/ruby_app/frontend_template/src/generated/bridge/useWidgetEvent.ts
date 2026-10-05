import { useContext } from 'react';
import type { EntityRecord, RuntimeValue, RuntimeVariables, WidgetEvent } from '../types';
import type { WidgetRuntimeProps } from './contracts';
import { evaluate } from './expression';
import { ClientActions } from './PageEdits';
import {
  PageParameters,
  LocalVariables,
  PageParameterBindings,
  SnippetParameterBindings,
} from './PageVariables';
import { VariableScope } from './components/VariableScope';
import { useSelections } from './components/SelectionScope';
import { eventArguments, isEntityRecord, memberName } from './value';
import { useActionExecution } from './useActionExecution';

export function useWidgetEvent(props: WidgetRuntimeProps) {
  const { widget, moduleName, invoke, invokeNanoflow, navigate, saveRecord, onError } = props;
  const actions = useContext(ClientActions);
  const pageBindings = useContext(PageParameterBindings);
  const snippetBindings = useContext(SnippetParameterBindings);
  const context = actions ? actions.edits.resolve(props.context) : props.context;
  const pageContext = actions ? actions.edits.resolve(props.pageContext) : props.pageContext;
  const selections = useSelections();
  const variables = useContext(VariableScope);
  const pageParameters = useContext(PageParameters);
  const localVariables = useContext(LocalVariables);
  const execution = useActionExecution(onError);
  const dispatch = async (
    event: WidgetEvent | undefined,
    eventContext: EntityRecord | null = context || pageContext,
  ): Promise<unknown> => {
    if (!event) return Promise.resolve();
    const handler = event.handler.includes('.') ? event.handler : `${moduleName}.${event.handler}`;
    let parameters: RuntimeVariables;
    try {
      const mappings = { ...event.arguments };
      if (event.settings?.source) mappings.__source = event.settings.source;
      if (event.settings?.close_count) mappings.__close_count = event.settings.close_count;
      parameters = eventArguments({ ...event, arguments: mappings }, eventContext, {
        pageParameter: pageContext,
        pageParameters: { ...pageParameters, ...pageBindings.values },
        localVariables: localVariables.values,
        widgetValues: { ...selections.records, ...selections.lists, [widget.name]: eventContext },
        snippetParameters: { ...variables, ...snippetBindings.values },
      });
    } catch (failure) {
      onError(failure);
      return Promise.resolve();
    }
    if (event.kind === 'action') {
      if (actions) return actions.run(event, eventContext, parameters);
      onError(new Error(`Client action runtime is missing: ${event.handler}`));
      return;
    }
    const closeCount = Number(parameters.__close_count || 0);
    delete parameters.__close_count;
    if (closeCount > 0) await actions?.close?.(closeCount);
    if (event.kind === 'page') {
      const candidate = Object.values(parameters)[0];
      const targetContext = isEntityRecord(candidate) ? candidate : pageContext || context || null;
      return navigate(handler, targetContext, {
        arguments: parameters,
        ...(event.settings?.title ? { title: event.settings.title } : {}),
      });
    }
    const response =
      event.kind === 'nanoflow'
        ? await invokeNanoflow(handler, parameters, eventContext)
        : event.settings?.asynchronous
          ? await invoke(handler, parameters, eventContext, { asynchronous: true })
          : await invoke(handler, parameters, eventContext);
    const result = (
      event.kind === 'microflow' && response && typeof response === 'object' && 'result' in response
        ? response.result
        : response
    ) as RuntimeValue | undefined;
    try {
      for (const mapping of event.settings?.outputs || []) {
        if (Array.isArray(result)) throw new Error('Return value mappings do not support lists');
        const mapped = mapping.expression
          ? evaluate(mapping.expression, eventContext, {
              ...pageParameters,
              ...variables,
              ...localVariables.values,
              ActionReturnValue: result,
            })
          : mapping.source_attribute && isEntityRecord(result)
            ? result.attributes[memberName(mapping.source_attribute)]
            : result;
        const source = mapping.source as { kind?: string; name?: string };
        if (mapping.attribute) {
          const target = eventArguments(
            { ...event, arguments: { target: mapping.source } },
            eventContext,
            {
              pageParameters: { ...pageParameters, ...pageBindings.values },
              localVariables: localVariables.values,
              snippetParameters: { ...variables, ...snippetBindings.values },
              widgetValues: { ...selections.records, ...selections.lists },
            },
          ).target;
          if (!isEntityRecord(target)) throw new Error('Return value target must be an object');
          await saveRecord(target, { [memberName(mapping.attribute)]: mapped });
        } else if (source.kind === 'local_variable') localVariables.set(source.name || '', mapped);
        else if (source.kind === 'page_parameter') pageBindings.set(source.name || '', mapped);
        else if (source.kind === 'snippet_parameter')
          snippetBindings.set(source.name || '', mapped);
        else throw new Error('Return value target must be a variable, parameter or attribute');
      }
    } catch (failure) {
      onError(failure);
    }
    return response;
  };
  return {
    ...execution,
    runEvent: (event: WidgetEvent | undefined, context?: EntityRecord | null) =>
      event
        ? execution.run(
            event,
            () => dispatch(event, context),
            event.settings?.confirmation
              ? async () => !!(await actions?.confirm?.(event.settings?.confirmation))
              : undefined,
          )
        : Promise.resolve(),
  };
}
