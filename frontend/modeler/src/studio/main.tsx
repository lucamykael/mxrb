import { createRoot } from 'react-dom/client';
import { useEffect, useState } from 'react';
import { StudioRpc } from './rpc';
import { Explorer } from './Explorer';
import { Tasks } from './Tasks';
import type { StudioContext } from './types';
import './studio.css';

const rpc = new StudioRpc();
window.addEventListener('pagehide', () => rpc.dispose(), { once: true });

function App() {
  const [context, setContext] = useState<StudioContext>();
  const [error, setError] = useState('');
  const [panel, setPanel] = useState('explorer');
  useEffect(() => {
    const controller = new AbortController();
    const apply = (next: StudioContext) => {
      for (const key of Array.from(document.documentElement.style)) {
        if (key.startsWith('--studio-')) document.documentElement.style.removeProperty(key);
      }
      for (const [key, value] of Object.entries(next.theme ?? {})) {
        if (/^--studio-[a-z-]+$/.test(key)) document.documentElement.style.setProperty(key, value);
      }
      setContext(next);
    };
    rpc.call('initialize', {}, { signal: controller.signal })
      .then(() => rpc.call<StudioContext>('host/context', {}, { signal: controller.signal })).then(apply)
      .catch(reason => { if (!controller.signal.aborted) setError(String(reason)); });
    const unsubscribe = rpc.subscribe((method, params) => { if (method === 'host/contextChanged') apply(params as StudioContext); });
    return () => { controller.abort(); unsubscribe(); };
  }, []);
  if (error) return <div role="alert" className="error">{error}</div>;
  if (!context) return <p role="status">Connecting to MXRB…</p>;
  return <main className="studio-panels">
    <nav aria-label="MXRB panels">
      <button aria-pressed={panel === 'explorer'} onClick={() => setPanel('explorer')}>Ruby App Explorer</button>
      <button aria-pressed={panel === 'tasks'} onClick={() => setPanel('tasks')}>MXRB Tasks</button>
    </nav>
    <div hidden={panel !== 'explorer'}><Explorer rpc={rpc} context={context} /></div>
    <div hidden={panel !== 'tasks'}><Tasks rpc={rpc} context={context} /></div>
  </main>;
}

createRoot(document.getElementById('root')!).render(<App />);
