export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export async function requestJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, init);
  const payload = (await response.json()) as T & { error?: string };
  if (!response.ok) {
    throw new ApiError(payload.error ?? `HTTP ${response.status}`, response.status);
  }
  return payload;
}
