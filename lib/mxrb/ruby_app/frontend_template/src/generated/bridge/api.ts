import type { ApiFailure, RuntimeValue } from '../types';

const errorMessage = (payload: unknown, status: number): string => {
  if (payload && typeof payload === 'object' && 'error' in payload) {
    const error = payload.error;
    if (error && typeof error === 'object' && 'message' in error) return String(error.message);
  }
  return `HTTP ${status}`;
};

export const api = async <T = RuntimeValue | undefined>(
  path: string,
  options: RequestInit = {},
): Promise<T> => {
  const headers = new Headers(options.headers);
  headers.set('Content-Type', 'application/json');
  if (csrfToken && !['GET', 'HEAD'].includes(options.method || 'GET')) {
    headers.set('X-CSRF-Token', csrfToken);
  }
  const response = await fetch(path, { ...options, headers, credentials: 'same-origin' });
  const payload: unknown = await response.json();
  if (!response.ok) {
    const error: ApiFailure = new Error(errorMessage(payload, response.status));
    error.status = response.status;
    throw error;
  }
  return payload as T;
};

let csrfToken: string | null = null;
export const setCsrfToken = (value: string | null): void => {
  csrfToken = value;
};
