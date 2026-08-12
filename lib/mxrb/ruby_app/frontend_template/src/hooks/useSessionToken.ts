import { useCallback, useState } from 'react';

const TOKEN_KEY = 'mxrb.session.token';

export function useSessionToken() {
  const [token, setToken] = useState<string | null>(() => window.localStorage.getItem(TOKEN_KEY));

  const saveToken = useCallback((value: string) => {
    window.localStorage.setItem(TOKEN_KEY, value);
    setToken(value);
  }, []);

  const clearToken = useCallback(() => {
    window.localStorage.removeItem(TOKEN_KEY);
    setToken(null);
  }, []);

  return { token, saveToken, clearToken };
}
