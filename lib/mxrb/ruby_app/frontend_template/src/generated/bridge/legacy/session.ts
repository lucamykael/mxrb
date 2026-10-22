import { useEffect, useState } from 'react';
import { api } from '../api';
import type { MxSession } from './mx';

const loadSession = async (): Promise<MxSession> => {
  try {
    const session = await api<(MxSession & { user?: string }) | undefined>('/api/session');
    return { ...session, username: session?.username ?? session?.user };
  } catch {
    return {};
  }
};
let sessionRequest: Promise<MxSession> | null = null;

// The signed-in user mx.session reports, read once per page load.
export function useLegacySession(): MxSession | null {
  const [session, setSession] = useState<MxSession | null>(null);
  useEffect(() => {
    let active = true;
    void (sessionRequest ??= loadSession()).then((value) => active && setSession(value));
    return () => {
      active = false;
    };
  }, []);
  return session;
}
