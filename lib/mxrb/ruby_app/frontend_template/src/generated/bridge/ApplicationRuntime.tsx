import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate, useParams } from 'react-router-dom';
import { api, setCsrfToken } from './api';
import { ClientActions, PageEdits, hasPageEdits } from './PageEdits';
import { apiFailure, inlineStyle, isEntityRecord } from './value';
import type { InvokeHandler, SaveRecord, SelectRecord, WidgetRuntimeProps } from './contracts';
import nanoflows from '../nanoflows';
import { LoginForm } from '../../components/auth/LoginForm';
import { AppFeedback } from '../../components/feedback/AppFeedback';
import { AppNavigation } from '../../components/navigation/AppNavigation';
import { PageOutlet } from './components/PageOutlet';
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

export function ApplicationRuntime() {
  const navigate = useNavigate();
  const location = useLocation();
  const { pageName } = useParams();
  const [schema, setSchema] = useState<ApplicationSchema | null>(null);
  const [page, setPage] = useState<PageDefinition | null>(null);
  const [pageContext, setPageContext] = useState<EntityRecord | null>(null);
  const [error, setError] = useState<ApiFailure | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const initialLoadStarted = useRef(false);
  const invocationInFlight = useRef(false);
  const [revision, setRevision] = useState(0);
  const [session, setSession] = useState<Session | null>(null);
  const [authRequired, setAuthRequired] = useState(false);
  const [edits, setEdits] = useState(() => new PageEdits(false));
  const [editReset, setEditReset] = useState(0);
  const actionInFlight = useRef(false);
  const schemaRef = useRef<ApplicationSchema | null>(null);
  const pageLoaded = useRef(false);
  const pageRequest = useRef(0);
  const pendingRoute = useRef<string | null>(null);
  const depth = useRef(0);

  const handleError = useCallback((failure: unknown) => {
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
    updateLocation = true,
  ): Promise<void> => {
    const requestId = ++pageRequest.current;
    try {
      const value = await api<PageDefinition>(`/api/pages/${encodeURIComponent(name)}`, {});
      let resolvedContext = context;
      if (!updateLocation && context && !context.transient) {
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
      if (requestId !== pageRequest.current) return;
      setEdits(new PageEdits(schemaRef.current ? hasPageEdits(value, schemaRef.current) : false));
      setPage(value);
      setPageContext(resolvedContext);
      setRevision((current) => current + 1);
      setError(null);
      if (updateLocation || !pageLoaded.current) {
        pendingRoute.current = name;
        if (pageLoaded.current) depth.current += 1;
        navigate(`/pages/${encodeURIComponent(name)}`, {
          replace: !pageLoaded.current,
          state: { mxrbDepth: depth.current, context: resolvedContext },
        });
      }
      pageLoaded.current = true;
    } catch (failure) {
      handleError(failure);
    }
  };

  const closePage = (count = 1) => {
    const distance = Math.min(depth.current, Math.max(1, Math.floor(Number(count) || 1)));
    if (distance > 0) navigate(-distance);
  };

  // React Router changes the URL on Back/Forward; reload the matching page
  // and its saved object context as well. Never navigate outside this app.
  const loadRoute = useRef(openPage);
  loadRoute.current = openPage;
  useEffect(() => {
    if (!pageLoaded.current || !pageName) return;
    const target = decodeURIComponent(pageName);
    if (pendingRoute.current === target) {
      pendingRoute.current = null;
      return;
    }
    depth.current = Number(location.state?.mxrbDepth) || 0;
    const context = location.state?.context;
    void loadRoute.current(target, isEntityRecord(context) ? context : null, false);
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
    if (initialLoadStarted.current) return;
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
    try {
      await api('/api/logout', { method: 'POST' });
    } catch (failure) {
      const normalized = apiFailure(failure);
      if (normalized.status !== 401) setError(normalized);
    } finally {
      setCsrfToken(null);
      setSession(null);
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
    if (!pageContext?.type || !pageContext.id) return Promise.resolve();
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

  const invoke: InvokeHandler = (name, parameters = {}, contextOverride = null) => {
    if (invocationInFlight.current) return Promise.resolve(null);
    invocationInFlight.current = true;
    setBusy(true);
    const activeContext = contextOverride || pageContext;
    return request<InvocationResult>(`/api/microflows/${encodeURIComponent(name)}`, {
      method: 'POST',
      body: JSON.stringify({
        ...parameters,
        ...(activeContext ? { __mxrb_context: activeContext } : {}),
      }),
    })
      .then(async (payload) => {
        setRevision((value) => value + 1);
        if (payload.context) setPageContext(payload.context);
        let navigated = false;
        for (const effect of payload.effects || []) {
          if (effect.type === 'show_message' && effect.message) setNotice(String(effect.message));
          if (effect.type === 'open_page' && typeof effect.page === 'string') {
            const context =
              Object.values(effect.arguments || {}).find(isEntityRecord) ||
              payload.context ||
              (isEntityRecord(payload.result) ? payload.result : null);
            await openPage(effect.page, context);
            navigated = true;
          } else if (effect.type === 'close_page') {
            closePage(Number(effect.count));
            navigated = true;
          }
        }
        if (!navigated && !payload.context) await refreshPageContext();
        return payload;
      })
      .catch(handleError)
      .finally(() => {
        invocationInFlight.current = false;
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
          const context = values.find(isEntityRecord) || null;
          await openPage(effect.page, context);
        } else if (effect.type === 'close_page') {
          closePage(Number(effect.count));
        }
      }
      setError(null);
      return execution.result;
    } catch (failure) {
      setError(apiFailure(failure));
      return null;
    } finally {
      setBusy(false);
    }
  };

  const runClientAction = async (event: WidgetEvent, record: EntityRecord | null) => {
    if (actionInFlight.current) return;
    actionInFlight.current = true;
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
          break;
        }
        case 'cancel_changes':
          // Discard text still focused, as well as changes already staged on blur.
          edits.cancel();
          setEditReset((value) => value + 1);
          break;
        case 'delete':
          if (!record || record.transient) throw new Error('Select a persisted object to delete');
          await request(
            `/api/entities/${encodeURIComponent(record.type)}/${encodeURIComponent(record.id)}`,
            {
              method: 'DELETE',
            },
          );
          edits.forget(record);
          setPageContext((current) =>
            current?.id === record.id && current.type === record.type ? null : current,
          );
          break;
        case 'close_page':
          closePage();
          return;
        default:
          throw new Error(`Unsupported client action: ${event.handler}`);
      }
      setRevision((value) => value + 1);
      setError(null);
      if (event.close_page ?? ['save_changes', 'cancel_changes'].includes(event.handler))
        closePage();
    } catch (failure) {
      handleError(failure);
    } finally {
      actionInFlight.current = false;
      setBusy(false);
    }
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

  return (
    <AppLayout
      className={page.appearance_class}
      style={inlineStyle(page.appearance_style)}
      navigation={
        <AppNavigation
          items={profile?.items || []}
          authenticated={Boolean(session)}
          onOpenPage={openPage}
          onLogout={logout}
        />
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
      <ClientActions.Provider value={{ edits, reset: editReset, run: runClientAction }}>
        <PageRuntimeContext.Provider value={pageRuntime}>
          <SelectionScope key={page.name}>
            <PageOutlet key={page.name} page={page} busy={busy} Widget={RuntimePageWidget} />
          </SelectionScope>
        </PageRuntimeContext.Provider>
      </ClientActions.Provider>
    </AppLayout>
  );
}
