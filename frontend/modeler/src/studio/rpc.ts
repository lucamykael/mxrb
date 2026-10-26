type Message = { jsonrpc: string; id?: number; method?: string; params?: Record<string, unknown>;
  result?: unknown; error?: { code: number; message: string; data?: unknown } };
type WebView = { postMessage(message: unknown): void;
  addEventListener(name: 'message', listener: (event: MessageEvent<Message>) => void): void;
  removeEventListener(name: 'message', listener: (event: MessageEvent<Message>) => void): void };

declare global { interface Window { chrome?: { webview?: WebView } } }

export class StudioError extends Error {
  constructor(readonly code: number, message: string, readonly details?: unknown) { super(message); }
}

/** The same WebView2 transport as Studio Pro; no web server, CLI parser or model code in the panel. */
export class StudioRpc {
  private nextId = 0;
  private pending = new Map<number, { resolve(value: unknown): void; reject(error: Error): void;
    cleanup(): void; progress?: (value: Record<string, unknown>) => void }>();
  private listeners = new Set<(method: string, params: Record<string, unknown>) => void>();
  private webview = window.chrome?.webview;
  private closed = false;

  constructor() { this.webview?.addEventListener('message', this.receive); }

  call<T>(method: string, params: Record<string, unknown> = {}, options: {
    signal?: AbortSignal; progress?: (value: Record<string, unknown>) => void } = {}): Promise<T> {
    if (!this.webview) return Promise.reject(new Error('Open this panel in Studio Pro.'));
    if (this.closed) return Promise.reject(new Error('The Studio Pro panel is closed.'));
    if (options.signal?.aborted) return Promise.reject(new DOMException('Cancelled', 'AbortError'));
    const id = ++this.nextId;
    return new Promise<T>((resolve, reject) => {
      const cancel = () => {
        this.pending.delete(id);
        cleanup();
        this.webview!.postMessage({ jsonrpc: '2.0', method: '$/cancelRequest', params: { id } });
        reject(new DOMException('Cancelled', 'AbortError'));
      };
      const cleanup = () => options.signal?.removeEventListener('abort', cancel);
      this.pending.set(id, { resolve: value => resolve(value as T), reject, cleanup, progress: options.progress });
      try {
        this.webview!.postMessage({ jsonrpc: '2.0', id, method, params });
        options.signal?.addEventListener('abort', cancel, { once: true });
      } catch (error) {
        this.pending.delete(id); cleanup(); reject(error);
      }
    });
  }

  subscribe(listener: (method: string, params: Record<string, unknown>) => void) {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  private receive = (event: MessageEvent<Message>) => {
    const message = event.data;
    if (!message || message.jsonrpc !== '2.0') return;
    if (message.method) {
      const params = message.params ?? {};
      if (message.method === '$/progress') this.pending.get(Number(params.token))?.progress?.(params);
      else this.listeners.forEach(listener => listener(message.method!, params));
      return;
    }
    const request = this.pending.get(message.id!);
    if (!request) return;
    this.pending.delete(message.id!); request.cleanup();
    if (message.error) request.reject(new StudioError(message.error.code, message.error.message, message.error.data));
    else request.resolve(message.result);
  };

  dispose() {
    this.closed = true;
    this.webview?.removeEventListener('message', this.receive);
    this.pending.forEach((request, id) => {
      this.webview?.postMessage({ jsonrpc: '2.0', method: '$/cancelRequest', params: { id } });
      request.cleanup(); request.reject(new DOMException('Panel closed', 'AbortError'));
    });
    this.pending.clear(); this.listeners.clear();
  }
}
