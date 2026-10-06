import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate, useParams } from 'react-router-dom';
import { api, setCsrfToken } from './api';
import { invokeAsync } from './AsyncInvocation';
import { ClientActions, PageEdits, hasPageEdits } from './PageEdits';
import { PageDataSource, pageSourceWidget } from './PageDataSource';
import {
  PageParameters,
  VariableEnvironment,
  resolveParameters,
  assignable,
} from './PageVariables';
import { Popup } from './components/Popup';
import { LayoutState } from './components/NativeScrollContainer';
import { apiFailure, inlineStyle, isEntityRecord, recordValue } from './value';
import type { InvokeHandler, SaveRecord, SelectRecord, WidgetRuntimeProps } from './contracts';
import nanoflows from '../nanoflows';
import { LoginForm } from '../../components/auth/LoginForm';
import { AppFeedback } from '../../components/feedback/AppFeedback';
import { AppNavigation } from '../../components/navigation/AppNavigation';
import { PageOutlet } from './components/PageOutlet';
import { NavigationSelection } from './components/PageTitleContext';
import { WidgetRenderer } from './components/WidgetRenderer';
import { SelectionScope } from './components/SelectionScope';
import { AppLayout } from '../../layouts/AppLayout';
import type {
  ApiFailure,
  ApiRequest,
  ApplicationSchema,
  EntityRecord,
  InvocationResult,
  LoginResponse,
  PageDefinition,
  PageOpenOptions,
  PageWidgetProps,
  RuntimeVariables,
  Session,
  WidgetEvent,
} from '../types';

type PageRuntime = Omit<WidgetRuntimeProps, 'widget' | 'children'>;
const PageRuntimeContext = createContext<PageRuntime | null>(null);

// Keep this component's identity stable across API responses. Declaring it
// inside ApplicationRuntime remounts inputs and drops focus and unsaved drafts.
function RuntimePageWidget({ widget, children }: PageWidgetProps) {
  const runtime = useContext(PageRuntimeContext);
  if (!runtime) throw new Error('Page runtime context is missing');
  return (
    <WidgetRenderer {...runtime} widget={widget}>
      {children}
    </WidgetRenderer>
  );
}

interface Surface {
  id: string;
  page: PageDefinition;
  context: EntityRecord | null;
  parameters: RuntimeVariables;
  drafts?: PageOpenOptions['drafts'];
}
interface Workspace {
  open: (surface: Surface) => void;
  close: (id: string, count: number) => Promise<void>;
  navigate: (name: string, context: EntityRecord | null, options: PageOpenOptions) => Promise<void>;
  logout: () => Promise<void>;
  changed: () => void;
}

export function ApplicationRuntime({
  surface,
  applicationSchema,
  workspace,
}: { surface?: Surface; applicationSchema?: ApplicationSchema; workspace?: Workspace } = {}) {
  const navigate = useNavigate();
  const location = useLocation();
  const { pageName } = useParams();
  const [schema, setSchema] = useState<ApplicationSchema | null>(applicationSchema || null);
  const [page, setPage] = useState<PageDefinition | null>(surface?.page || null);
  const [pageContext, setPageContext] = useState<EntityRecord | null>(surface?.context || null);
  const [error, setError] = useState<ApiFailure | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmation, setConfirmation] = useState<{
    settings: NonNullable<NonNullable<WidgetEvent['settings']>['confirmation']>;
    resolve: (answer: boolean) => void;
  } | null>(null);
  const initialLoadStarted = useRef(false);
  const asynchronousInvocations = useRef(new Set<AbortController>());
  useEffect(() => {
    const pending = asynchronousInvocations.current;
    return () => {
      for (const controller of pending) controller.abort();
      pending.clear();
    };
  }, []);
  const [revision, setRevision] = useState(0);
  const [session, setSession] = useState<Session | null>(null);
  const [authRequired, setAuthRequired] = useState(false);
  const [edits, setEdits] = useState(() => {
    const drafts = new PageEdits(Boolean(surface?.page.popup));
    if (surface?.context?.new_record) drafts.stage(surface.context, {});
    for (const entry of surface?.drafts || []) drafts.stage(entry.record, entry.changes);
    return drafts;
  });
  const [parameters, setParameters] = useState<RuntimeVariables>(surface?.parameters || {});
  const [popups, setPopups] = useState<Surface[]>([]);
  const popupsRef = useRef(popups);
  popupsRef.current = popups;
  const updatePopups = (next: Surface[]) => {
    popupsRef.current = next;
    setPopups(next);
  };
  const surfaceElement = useRef<HTMLDivElement>(null);
  const layoutState = useRef(new Map<string, { open: boolean; focused: boolean }>());
  const navigationSelection = useRef(new Map<string, string>());
  const [editReset, setEditReset] = useState(0);
  const saveInFlight = useRef<Promise<void> | null>(null);
  const schemaRef = useRef<ApplicationSchema | null>(applicationSchema || null);
  const pageLoaded = useRef(Boolean(surface));
  const pageRequest = useRef(0);
  const pendingRoute = useRef<string | null>(null);
  const depth = useRef(0);
  const closeTransition = useRef<{ promise: Promise<void>; resolve: () => void } | null>(null);

  const handleError = useCallback((failure: unknown) => {
    if (failure instanceof DOMException && failure.name === 'AbortError') return;
    const normalized = apiFailure(failure);
    if (normalized.status === 401) setAuthRequired(true);
    setError(normalized);
  }, []);
  const request: ApiRequest = useCallback(
    (path: string, options: RequestInit = {}) => api(path, options),
    [],
  );

  const openPage = async (
    name: string,
    context: EntityRecord | null = null,
    options: PageOpenOptions | boolean = true,
    routeOptions: PageOpenOptions = {},
  ): Promise<void> => {
    const updateLocation = typeof options === 'boolean' ? options : true;
    const settings = typeof options === 'boolean' ? routeOptions : options;
    const requestId = ++pageRequest.current;
    try {
      let value = await api<PageDefinition>(`/api/pages/${encodeURIComponent(name)}`, {});
      let resolvedContext = context;
      if (!updateLocation && context && !context.transient && !context.new_record) {
        try {
          resolvedContext = await request<EntityRecord>(
            `/api/entities/${encodeURIComponent(context.type)}/${encodeURIComponent(context.id)}`,
          );
        } catch (failure) {
          if (apiFailure(failure).status !== 404) throw failure;
          resolvedContext = null;
        }
      }
      if (!context && value.data_source?.name) {
        if (value.data_source.kind === 'nanoflow') {
          const source = nanoflows[value.data_source.name as keyof typeof nanoflows];
          if (!source)
            throw new Error(`Page data source nanoflow not found: ${value.data_source.name}`);
          const execution = await source.execute({}, invoke);
          resolvedContext = isEntityRecord(execution.result) ? execution.result : null;
        } else {
          const payload = await api<InvocationResult>(
            `/api/microflows/${encodeURIComponent(value.data_source.name)}`,
            { method: 'POST', body: '{}' },
          );
          const candidate = payload.context || payload.result;
          resolvedContext = isEntityRecord(candidate) ? candidate : null;
        }
      }
      const resolvedParameters = resolveParameters(
        value.parameters,
        settings.arguments,
        resolvedContext,
        schemaRef.current!,
      );
      if (!resolvedContext)
        resolvedContext = Object.values(resolvedParameters).find(isEntityRecord) || null;
      if (settings.title !== undefined) value = { ...value, title: settings.title };
      const mode = settings.location || value.popup?.mode || 'content';
      if (mode !== 'content') {
        if (!pageLoaded.current && !surface) {
          setPage({ name: '$Workspace', title: '', widgets: [] });
          pageLoaded.current = true;
        }
        const popup: Surface = {
          id: crypto.randomUUID(),
          page: { ...value, popup: { ...value.popup, mode } },
          context: resolvedContext,
          parameters: resolvedParameters,
          drafts: settings.drafts,
        };
        if (workspace) workspace.open(popup);
        else updatePopups([...popupsRef.current, popup]);
        return;
      }
      if (surface && workspace) return workspace.navigate(name, resolvedContext, settings);
      if (requestId !== pageRequest.current) return;
      const drafts = new PageEdits(
        Boolean(resolvedContext?.new_record) ||
          (schemaRef.current ? hasPageEdits(value, schemaRef.current) : false),
      );
      if (resolvedContext?.new_record) drafts.stage(resolvedContext, {});
      for (const entry of settings.drafts || []) drafts.stage(entry.record, entry.changes);
      setEdits(drafts);
      updatePopups([]);
      setParameters(resolvedParameters);
      setPage(value);
      setPageContext(resolvedContext);
      setRevision((current) => current + 1);
      setError(null);
      if (updateLocation || !pageLoaded.current) {
        pendingRoute.current = name;
        if (pageLoaded.current) depth.current += 1;
        navigate(`/pages/${encodeURIComponent(name)}`, {
          replace: !pageLoaded.current,
          state: {
            mxrbDepth: depth.current,
            context: resolvedContext,
            arguments: resolvedParameters,
          },
        });
      }
      pageLoaded.current = true;
    } catch (failure) {
      handleError(failure);
    }
  };

  const closePage = (count = 1): Promise<void> => {
    count = Number.isFinite(count) ? Math.max(0, Math.floor(count)) : 1;
    if (!count) return Promise.resolve();
    if (surface && workspace) return workspace.close(surface.id, count);
    if (popupsRef.current.length) {
      const length = popupsRef.current.length;
      updatePopups(popupsRef.current.slice(0, Math.max(0, length - count)));
      count -= length;
      if (count <= 0) return Promise.resolve();
    }
    if (closeTransition.current) return closeTransition.current.promise;
    const distance = Math.min(depth.current, Math.max(1, Math.floor(Number(count) || 1)));
    if (distance <= 0) return Promise.resolve();
    let resolve = () => {};
    const promise = new Promise<void>((done) => {
      resolve = done;
    });
    closeTransition.current = { promise, resolve };
    navigate(-distance);
    return promise;
  };

  // React Router changes the URL on Back/Forward; reload the matching page
  // and its saved object context as well. Never navigate outside this app.
  const loadRoute = useRef(openPage);
  loadRoute.current = openPage;
  useEffect(() => {
    if (surface || !pageLoaded.current || !pageName) return;
    const target = decodeURIComponent(pageName);
    if (pendingRoute.current === target) {
      pendingRoute.current = null;
      return;
    }
    depth.current = Number(location.state?.mxrbDepth) || 0;
    const context = location.state?.context;
    void loadRoute
      .current(target, isEntityRecord(context) ? context : null, false, {
        arguments: location.state?.arguments,
      })
      .finally(() => {
        closeTransition.current?.resolve();
        closeTransition.current = null;
      });
  }, [location.key, pageName]);

  const loadApplication = async () => {
    try {
      const activeSession = await api<Session>('/api/session');
      setSession(activeSession);
      setCsrfToken(activeSession.csrf || null);
      const value = await api<ApplicationSchema>('/api/schema');
      schemaRef.current = value;
      setSchema(value);
      setAuthRequired(false);
      setError(null);
      const profile =
        value.navigation?.profiles?.find((item) => item.kind === 'Responsive') ||
        value.navigation?.profiles?.[0];
      const fallback = value.modules.flatMap((module) => module.pages)[0]?.name;
      const routeTarget = pageName ? decodeURIComponent(pageName) : null;
      const target = routeTarget || profile?.home_page || fallback;
      if (!target && !activeSession.user) {
        setAuthRequired(true);
        return;
      }
      if (!target) throw new Error('No accessible page is available for this session');
      await openPage(target, null, !routeTarget);
    } catch (failure) {
      const normalized = apiFailure(failure);
      if (normalized.status === 401) {
        setCsrfToken(null);
        setSession(null);
        setAuthRequired(true);
      }
      setError(normalized);
    }
  };

  useEffect(() => {
    if (surface || initialLoadStarted.current) return;
    initialLoadStarted.current = true;
    void loadApplication();
  }, []);

  const login = async (username: string, password: string): Promise<void> => {
    setBusy(true);
    try {
      const authenticated = await api<LoginResponse>('/api/login', {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      });
      setCsrfToken(authenticated.csrf);
      await loadApplication();
    } catch (failure) {
      setError(apiFailure(failure));
    } finally {
      setBusy(false);
    }
  };

  const logout = async () => {
    if (workspace) return workspace.logout();
    for (const controller of asynchronousInvocations.current) controller.abort();
    asynchronousInvocations.current.clear();
    updatePopups([]);
    try {
      await api('/api/logout', { method: 'POST' });
    } catch (failure) {
      const normalized = apiFailure(failure);
      if (normalized.status !== 401) setError(normalized);
    } finally {
      setCsrfToken(null);
      setSession(null);
      updatePopups([]);
      setSchema(null);
      schemaRef.current = null;
      pageLoaded.current = false;
      depth.current = 0;
      pageRequest.current += 1;
      setPage(null);
      setAuthRequired(true);
      navigate('/');
    }
  };

  const refreshPageContext = () => {
    if (!pageContext?.type || !pageContext.id || pageContext.new_record || pageContext.transient)
      return Promise.resolve();
    return request<EntityRecord>(
      `/api/entities/${encodeURIComponent(pageContext.type)}/${encodeURIComponent(pageContext.id)}`,
    )
      .then(setPageContext)
      .catch(handleError);
  };

  const saveRecord: SaveRecord = useCallback(
    (record, changes) => {
      if (!record?.type || !record.id) return Promise.resolve(record);
      if (edits.deferred) {
        const updated = edits.stage(record, changes);
        setRevision((value) => value + 1);
        return Promise.resolve(updated);
      }
      if (record.transient) {
        const updated: EntityRecord = {
          ...record,
          attributes: { ...record.attributes, ...changes },
        };
        setPageContext((current) =>
          current?.id === updated.id && current.type === updated.type ? updated : current,
        );
        setRevision((value) => value + 1);
        setError(null);
        return Promise.resolve(updated);
      }
      return request<EntityRecord>(
        `/api/entities/${encodeURIComponent(record.type)}/${encodeURIComponent(record.id)}`,
        { method: 'PATCH', body: JSON.stringify(changes) },
      )
        .then((updated) => {
          setPageContext((current) =>
            current?.id === updated.id && current.type === updated.type ? updated : current,
          );
          setRevision((value) => value + 1);
          setError(null);
          return updated;
        })
        .catch((failure: unknown) => {
          handleError(failure);
          return null;
        });
    },
    [request, handleError, edits],
  );

  const markMutation = useCallback(() => setRevision((value) => value + 1), []);
  const selectRecord: SelectRecord = useCallback((record) => setPageContext(record), []);

  const invoke: InvokeHandler = (name, parameters = {}, contextOverride = null, options = {}) => {
    setBusy(true);
    const activeContext = contextOverride || pageContext;
    const submitted = activeContext
      ? edits.changes.get(`${activeContext.type}/${activeContext.id}`)
      : undefined;
    const argumentsValue = {
      ...parameters,
      ...(activeContext ? { __mxrb_context: activeContext } : {}),
    };
    const execute = async (): Promise<InvocationResult> => {
      if (!options.asynchronous)
        return request<InvocationResult>(`/api/microflows/${encodeURIComponent(name)}`, {
          method: 'POST',
          body: JSON.stringify(argumentsValue),
        });
      const controller = new AbortController();
      asynchronousInvocations.current.add(controller);
      try {
        return await invokeAsync(request, name, argumentsValue, controller.signal);
      } finally {
        asynchronousInvocations.current.delete(controller);
      }
    };
    return execute()
      .then(async (payload) => {
        setRevision((value) => value + 1);
        const updatesPage =
          activeContext?.id === pageContext?.id && activeContext?.type === pageContext?.type;
        if (payload.context) {
          const refreshed = edits.refresh(payload.context, submitted);
          setPageContext((current) =>
            current?.id === activeContext?.id && current?.type === activeContext?.type
              ? refreshed
              : current,
          );
        }
        let navigated = false;
        for (const effect of payload.effects || []) {
          if (effect.type === 'show_message' && effect.message) setNotice(String(effect.message));
          if (effect.type === 'open_page' && typeof effect.page === 'string') {
            const context =
              (isEntityRecord(effect.context) ? effect.context : null) ||
              Object.values(effect.arguments || {}).find(isEntityRecord) ||
              payload.context ||
              (isEntityRecord(payload.result) ? payload.result : null);
            await openPage(effect.page, context, {
              arguments: effect.arguments as RuntimeVariables,
              location: effect.location as PageOpenOptions['location'],
              title: typeof effect.title === 'string' ? effect.title : undefined,
            });
            navigated = true;
          } else if (effect.type === 'close_page') {
            await closePage(Number(effect.count));
            navigated = true;
          }
        }
        if (!navigated && (!payload.context || !updatesPage)) await refreshPageContext();
        return payload;
      })
      .finally(() => {
        setBusy(false);
      });
  };

  const invokeNanoflow: InvokeHandler = async (
    name,
    parameters: RuntimeVariables = {},
    contextOverride = null,
  ) => {
    setBusy(true);
    try {
      const definition = nanoflows[name as keyof typeof nanoflows];
      const resolvedParameters: RuntimeVariables = { ...parameters };
      const activeContext = contextOverride || pageContext;
      if (
        definition?.parameters?.length === 1 &&
        !(definition.parameters[0] in resolvedParameters) &&
        activeContext
      ) {
        resolvedParameters[definition.parameters[0]] = activeContext;
      }
      if (!definition) throw new Error(`Nanoflow frontend not found: ${name}`);
      const execution = await definition.execute(resolvedParameters, invoke);
      for (const changed of execution.changes) {
        await saveRecord(changed, changed.attributes);
      }
      const message = execution.messages.at(-1);
      if (message?.message) setNotice(message.message);
      const validation = execution.validation.at(-1);
      if (validation?.message) setNotice(validation.message);
      for (const effect of execution.effects) {
        if (effect.type === 'open_page' && typeof effect.page === 'string') {
          const values =
            effect.arguments && typeof effect.arguments === 'object'
              ? Object.values(effect.arguments)
              : [];
          const context =
            (isEntityRecord(effect.context) ? effect.context : null) ||
            values.find(isEntityRecord) ||
            null;
          await openPage(effect.page, context, {
            arguments: effect.arguments as RuntimeVariables,
            location: effect.location as PageOpenOptions['location'],
            title: typeof effect.title === 'string' ? effect.title : undefined,
          });
        } else if (effect.type === 'close_page') {
          await closePage(Number(effect.count));
        }
      }
      setError(null);
      return execution.result;
    } finally {
      setBusy(false);
    }
  };

  const performClientAction = async (
    event: WidgetEvent,
    record: EntityRecord | null,
    parameters: RuntimeVariables = {},
  ) => {
    setBusy(true);
    try {
      switch (event.handler) {
        case 'save_changes': {
          await edits.flush();
          const pending = edits.pending();
          const submitted = new Map(edits.changes);
          const response = pending.length
            ? await request<{ records: EntityRecord[] }>('/api/records/commit', {
                method: 'POST',
                body: JSON.stringify({ records: pending }),
              })
            : { records: [] };
          edits.accept(response.records, submitted);
          setPageContext((current) => edits.resolve(current));
          workspace?.changed();
          break;
        }
        case 'cancel_changes':
          // Discard text still focused, as well as changes already staged on blur.
          edits.cancel();
          setEditReset((value) => value + 1);
          break;
        case 'delete': {
          const source = Object.hasOwn(parameters, '__source') ? parameters.__source : record;
          const targets = (Array.isArray(source) ? source : [source]).filter(isEntityRecord);
          if (!targets.length || targets.some((target) => target.transient || target.new_record))
            throw new Error('Select persisted objects to delete');
          if (targets.length === 1) {
            await request(
              `/api/entities/${encodeURIComponent(targets[0].type)}/${encodeURIComponent(targets[0].id)}`,
              { method: 'DELETE' },
            );
          } else {
            await request('/api/records/delete', {
              method: 'POST',
              body: JSON.stringify({ records: targets.map(({ type, id }) => ({ type, id })) }),
            });
          }
          for (const target of targets) edits.forget(target);
          setPageContext((current) =>
            targets.some((target) => current?.id === target.id && current.type === target.type)
              ? null
              : current,
          );
          workspace?.changed();
          break;
        }
        case 'create_object': {
          const creation = event.settings?.create;
          if (!creation?.entity) throw new Error('Create object requires an entity');
          const created = await request<EntityRecord>('/api/records/draft', {
            method: 'POST',
            body: JSON.stringify({ type: creation.entity }),
          });
          const drafts: NonNullable<PageOpenOptions['drafts']> = [];
          if (creation.association && record) {
            const association = schema!.modules
              .flatMap((module) => module.associations || [])
              .find((entry) => entry.name === creation.association);
            if (!association) throw new Error(`Association not found: ${creation.association}`);
            const member = association.name.split('.').at(-1)!;
            if (assignable(created.type, association.from_entity, schema!)) {
              created.attributes[member] = association.type === 'ReferenceSet' ? [record] : record;
            } else if (assignable(record.type, association.from_entity, schema!)) {
              const previous = recordValue(record, member);
              drafts.push({
                record,
                changes: {
                  [member]:
                    association.type === 'ReferenceSet'
                      ? [...(Array.isArray(previous) ? previous : []), created]
                      : created,
                },
              });
            } else throw new Error(`Invalid association context: ${creation.association}`);
          }
          if (creation.page)
            await openPage(creation.page, created, { arguments: parameters, drafts });
          else {
            edits.stage(created, {});
            for (const entry of drafts) edits.stage(entry.record, entry.changes);
            setPageContext(created);
          }
          break;
        }
        case 'open_link': {
          const link = event.settings?.link;
          const value = String(
            link?.attribute ? recordValue(record, link.attribute) || '' : link?.value || '',
          );
          const prefix =
            link?.type === 'Email'
              ? 'mailto:'
              : ['Phone', 'Call'].includes(link?.type || '')
                ? 'tel:'
                : link?.type === 'Text'
                  ? 'sms:'
                  : '';
          const url = new URL(
            prefix && !value.startsWith(prefix) ? prefix + value : value,
            window.location.href,
          );
          if (!['http:', 'https:', 'mailto:', 'tel:', 'sms:'].includes(url.protocol))
            throw new Error('Unsupported link protocol');
          window.open(url.href, '_blank', 'noopener,noreferrer');
          return;
        }
        case 'sign_out':
          await logout();
          return;
        case 'close_page':
          await closePage(Number(parameters.__close_count ?? 1));
          return;
        default:
          throw new Error(`Unsupported client action: ${event.handler}`);
      }
      setRevision((value) => value + 1);
      setError(null);
      if (event.close_page ?? ['save_changes', 'cancel_changes'].includes(event.handler))
        await closePage();
    } catch (failure) {
      handleError(failure);
    } finally {
      setBusy(false);
    }
  };

  const runClientAction = (
    event: WidgetEvent,
    record: EntityRecord | null,
    parameters: RuntimeVariables = {},
  ) => {
    if (event.handler !== 'save_changes') return performClientAction(event, record, parameters);
    if (saveInFlight.current) return saveInFlight.current;
    const operation = performClientAction(event, record, parameters);
    saveInFlight.current = operation;
    void operation.finally(() => {
      saveInFlight.current = null;
    });
    return operation;
  };

  if (authRequired) return <LoginForm onLogin={login} error={error} busy={busy} />;
  if (!schema || !page)
    return <main className="loading-page mxrb-loading">Loading application…</main>;
  const profile =
    schema.navigation?.profiles?.find((item) => item.kind === 'Responsive') ||
    schema.navigation?.profiles?.[0];
  const moduleName = page.name.split('.')[0];
  const pageRuntime: PageRuntime = {
    moduleName,
    invoke,
    invokeNanoflow,
    navigate: openPage,
    context: pageContext,
    pageContext,
    revision,
    schema,
    request,
    saveRecord,
    onError: handleError,
    onMutation: markMutation,
    onSelectRecord: selectRecord,
  };

  const popupWorkspace: Workspace = workspace || {
    open: (popup) => updatePopups([...popupsRef.current, popup]),
    close: async (id, count) => {
      const index = popupsRef.current.findIndex((popup) => popup.id === id);
      if (index < 0) return;
      updatePopups(popupsRef.current.slice(0, Math.max(0, index + 1 - count)));
      if (count > index + 1) await closePage(count - index - 1);
    },
    navigate: (name, context, options) =>
      openPage(name, context, { ...options, location: 'content' }),
    logout,
    changed: () => {
      setRevision((current) => current + 1);
      void refreshPageContext();
    },
  };
  const content = (
    <div ref={surfaceElement} className="mxrb-page-surface">
      <PageParameters.Provider value={parameters}>
        <VariableEnvironment
          key={`${surface?.id || page.name}`}
          parameters={parameters}
          definitions={page.variables}
          parameterDefinitions={page.parameters}
          context={pageContext}
          schema={schema}
        >
          <ClientActions.Provider
            value={{
              edits,
              reset: editReset,
              run: runClientAction,
              close: closePage,
              confirm: (settings) =>
                settings
                  ? new Promise((resolve) => setConfirmation({ settings, resolve }))
                  : Promise.resolve(true),
            }}
          >
            <PageRuntimeContext.Provider value={pageRuntime}>
              <LayoutState.Provider value={layoutState.current}>
                <NavigationSelection.Provider value={navigationSelection.current}>
                  <SelectionScope key={page.name}>
                    <PageDataSource.Provider value={pageSourceWidget(page)}>
                      <PageOutlet
                        key={page.name}
                        page={page}
                        busy={busy}
                        Widget={RuntimePageWidget}
                      />
                    </PageDataSource.Provider>
                  </SelectionScope>
                </NavigationSelection.Provider>
              </LayoutState.Provider>
            </PageRuntimeContext.Provider>
          </ClientActions.Provider>
        </VariableEnvironment>
      </PageParameters.Provider>
    </div>
  );
  const answerConfirmation = (answer: boolean) => {
    confirmation?.resolve(answer);
    setConfirmation(null);
  };
  const confirmationDialog = confirmation && (
    <Popup
      title="Confirmation"
      settings={{ mode: 'modal' }}
      onClose={() => answerConfirmation(false)}
    >
      <p>{confirmation.settings.question}</p>
      <button type="button" onClick={() => answerConfirmation(false)}>
        {confirmation.settings.cancel || 'Cancel'}
      </button>
      <button type="button" onClick={() => answerConfirmation(true)}>
        {confirmation.settings.proceed || 'Proceed'}
      </button>
    </Popup>
  );
  const feedback = (
    <AppFeedback
      error={error}
      notice={notice}
      onDismissError={() => setError(null)}
      onDismissNotice={() => setNotice(null)}
    />
  );
  if (surface) {
    const dismiss = () => {
      const name = page.popup?.close_action?.split('.').at(-1);
      const target = name
        ? [
            ...(surfaceElement.current?.querySelectorAll<HTMLElement>('[data-widget-name]') || []),
          ].find((element) => element.dataset.widgetName === name)
        : null;
      const button = target?.matches('button')
        ? target
        : target?.querySelector<HTMLButtonElement>('button');
      if (button && !button.hasAttribute('disabled') && !button.closest('[hidden]')) button.click();
      else {
        edits.cancel();
        void closePage();
      }
    };
    return (
      <Popup title={page.title} settings={page.popup!} autofocus={page.autofocus} onClose={dismiss}>
        {feedback}
        {content}
        {confirmationDialog}
      </Popup>
    );
  }
  return (
    <AppLayout
      className={page.appearance_class}
      style={inlineStyle(page.appearance_style)}
      navigation={
        JSON.stringify(page.widgets).includes('"navigation_profile"') ? undefined : (
          <AppNavigation
            items={profile?.items || []}
            authenticated={Boolean(session)}
            onOpenPage={openPage}
            onLogout={logout}
          />
        )
      }
      feedback={
        <AppFeedback
          error={error}
          notice={notice}
          onDismissError={() => setError(null)}
          onDismissNotice={() => setNotice(null)}
        />
      }
    >
      {content}
      {confirmationDialog}
      {popups.map((popup) => (
        <ApplicationRuntime
          key={popup.id}
          surface={popup}
          applicationSchema={schema}
          workspace={popupWorkspace}
        />
      ))}
    </AppLayout>
  );
}
