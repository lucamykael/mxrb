import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { api } from './api';
import { apiFailure, inlineStyle, isEntityRecord } from './value';
import type { InvokeHandler, SaveRecord, SelectRecord } from './contracts';
import nanoflows from '../nanoflows';
import { LoginForm } from '../../components/auth/LoginForm';
import { AppFeedback } from '../../components/feedback/AppFeedback';
import { AppNavigation } from '../../components/navigation/AppNavigation';
import { PageOutlet } from './components/PageOutlet';
import { WidgetRenderer } from './components/WidgetRenderer';
import { useSessionToken } from '../../hooks/useSessionToken';
import { AppLayout } from '../../layouts/AppLayout';
import type {
  ApiFailure,
  ApiRequest,
  ApplicationSchema,
  EntityRecord,
  InvocationResult,
  LoginResponse,
  OpenPageEffect,
  PageDefinition,
  PageWidgetProps,
  RuntimeVariables,
  Session,
  ShowMessageEffect,
} from '../types';

export function ApplicationRuntime() {
  const navigate = useNavigate();
  const { pageName } = useParams();
  const { token, saveToken, clearToken } = useSessionToken();
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

  const handleError = useCallback((failure: unknown) => {
    const normalized = apiFailure(failure);
    if (normalized.status === 401) setAuthRequired(true);
    setError(normalized);
  }, []);
  const request: ApiRequest = useCallback(
    (path: string, options: RequestInit = {}) => api(path, options, token),
    [token],
  );

  const openPage = async (
    name: string,
    context: EntityRecord | null = null,
    activeToken = token,
    updateLocation = true,
  ): Promise<void> => {
    try {
      const value = await api<PageDefinition>(
        `/api/pages/${encodeURIComponent(name)}`,
        {},
        activeToken,
      );
      let resolvedContext = context;
      if (!resolvedContext && value.data_source?.name) {
        if (value.data_source.kind === 'nanoflow') {
          const source = nanoflows[value.data_source.name as keyof typeof nanoflows];
          if (!source)
            throw new Error(`Page data source nanoflow not found: ${value.data_source.name}`);
          const execution = await source.execute({});
          resolvedContext = isEntityRecord(execution.result)
            ? { ...execution.result, transient: true }
            : null;
        } else {
          const payload = await api<InvocationResult>(
            `/api/microflows/${encodeURIComponent(value.data_source.name)}`,
            { method: 'POST', body: '{}' },
            activeToken,
          );
          const candidate = payload.context || payload.result;
          resolvedContext = isEntityRecord(candidate) ? { ...candidate, transient: true } : null;
        }
      }
      setPage(value);
      setPageContext(resolvedContext);
      setRevision((current) => current + 1);
      setError(null);
      if (updateLocation) navigate(`/pages/${encodeURIComponent(name)}`);
    } catch (failure) {
      handleError(failure);
    }
  };

  const loadApplication = async (activeToken = token) => {
    try {
      if (activeToken) {
        setSession(await api<Session>('/api/session', {}, activeToken));
      }
      const value = await api<ApplicationSchema>('/api/schema', {}, activeToken);
      setSchema(value);
      setAuthRequired(false);
      setError(null);
      const profile =
        value.navigation?.profiles?.find((item) => item.kind === 'Responsive') ||
        value.navigation?.profiles?.[0];
      const fallback = value.modules.flatMap((module) => module.pages)[0]?.name;
      const routeTarget = pageName ? decodeURIComponent(pageName) : null;
      const target = routeTarget || profile?.home_page || fallback;
      if (!target && !activeToken) {
        setAuthRequired(true);
        return;
      }
      if (!target) throw new Error('No accessible page is available for this session');
      await openPage(target, null, activeToken, !routeTarget);
    } catch (failure) {
      const normalized = apiFailure(failure);
      if (normalized.status === 401) {
        clearToken();
        setSession(null);
        setAuthRequired(true);
      }
      setError(normalized);
    }
  };

  useEffect(() => {
    if (initialLoadStarted.current) return;
    initialLoadStarted.current = true;
    void loadApplication(token);
  }, []);

  const login = async (username: string, password: string): Promise<void> => {
    setBusy(true);
    try {
      const authenticated = await api<LoginResponse>('/api/login', {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      });
      saveToken(authenticated.token);
      await loadApplication(authenticated.token);
    } catch (failure) {
      setError(apiFailure(failure));
    } finally {
      setBusy(false);
    }
  };

  const logout = async () => {
    try {
      await api('/api/logout', { method: 'POST' }, token);
    } catch (failure) {
      const normalized = apiFailure(failure);
      if (normalized.status !== 401) setError(normalized);
    } finally {
      clearToken();
      setSession(null);
      setSchema(null);
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
      if (record.transient) {
        const updated: EntityRecord = {
          ...record,
          attributes: { ...record.attributes, ...changes },
        };
        setPageContext((current) => (current?.id === updated.id ? updated : current));
        setRevision((value) => value + 1);
        setError(null);
        return Promise.resolve(updated);
      }
      return request<EntityRecord>(
        `/api/entities/${encodeURIComponent(record.type)}/${encodeURIComponent(record.id)}`,
        { method: 'PATCH', body: JSON.stringify(changes) },
      )
        .then((updated) => {
          setPageContext((current) => (current?.id === updated.id ? updated : current));
          setRevision((value) => value + 1);
          setError(null);
          return updated;
        })
        .catch((failure: unknown) => {
          const normalized = apiFailure(failure);
          if (normalized.status === 404) {
            const updated: EntityRecord = {
              ...record,
              attributes: { ...record.attributes, ...changes },
            };
            setPageContext((current) => (current?.id === updated.id ? updated : current));
            setRevision((value) => value + 1);
            setError(null);
            return updated;
          }
          handleError(failure);
          return null;
        });
    },
    [request, handleError],
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
      .then((payload) => {
        setRevision((value) => value + 1);
        if (payload.context) setPageContext(payload.context);
        const message = (payload.effects || []).find(
          (effect): effect is ShowMessageEffect => effect.type === 'show_message',
        );
        if (message?.message) setNotice(String(message.message));
        const navigation = (payload.effects || []).find(
          (effect): effect is OpenPageEffect => effect.type === 'open_page',
        );
        if (navigation?.page) {
          const context =
            Object.values(navigation.arguments || {})[0] ||
            payload.context ||
            payload.result ||
            null;
          return openPage(navigation.page, context as EntityRecord | null).then(() => payload);
        }
        return payload.context
          ? Promise.resolve(payload)
          : refreshPageContext().then(() => payload);
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
      setError(null);
      return execution.result;
    } catch (failure) {
      setError(apiFailure(failure));
      return null;
    } finally {
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
  const PageWidget = ({ widget, children }: PageWidgetProps) => (
    <WidgetRenderer
      widget={widget}
      moduleName={moduleName}
      invoke={invoke}
      invokeNanoflow={invokeNanoflow}
      navigate={openPage}
      context={pageContext}
      pageContext={pageContext}
      revision={revision}
      schema={schema}
      request={request}
      saveRecord={saveRecord}
      onError={handleError}
      onMutation={markMutation}
      onSelectRecord={selectRecord}
    >
      {children}
    </WidgetRenderer>
  );

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
      <PageOutlet page={page} busy={busy} Widget={PageWidget} />
    </AppLayout>
  );
}
