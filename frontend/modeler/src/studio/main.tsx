import { createRoot } from 'react-dom/client';
import { useEffect, useState } from 'react';
import { StudioRpc } from './rpc';
import { Explorer } from './Explorer';
import { Tasks } from './Tasks';
import { GlobalEr } from './GlobalEr';
import { DatabaseExplorer } from './DatabaseExplorer';
import { Parity } from './Parity';
import type { PanelKind, StudioContext } from './types';
import { SyncPanel } from './SyncPanel';
import './studio.css';
import './panels.css';

const PANELS: [PanelKind, string][] = [['explorer', 'Ruby App Explorer'], ['tasks', 'MXRB Tasks'], ['sync', 'Ruby Sync'],
  ['er', 'MXRB Global ER'], ['database', 'MXRB Database'], ['parity', 'MXRB Parity']];

const rpc = new StudioRpc();
window.addEventListener('pagehide', () => rpc.dispose(), { once: true });

function App() {
  const [context, setContext] = useState<StudioContext>();
  const [error, setError] = useState('');
  const [panel, setPanel] = useState<PanelKind>('explorer');
  const [opened, setOpened] = useState(new Set<PanelKind>(['explorer', 'tasks']));
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
    {!context.panel && <nav aria-label="MXRB panels">
      {PANELS.map(([kind, title]) => <button key={kind} aria-pressed={panel === kind}
        onClick={() => { setPanel(kind); setOpened(previous => new Set(previous).add(kind)); }}>{title}</button>)}
    </nav>}
    {(!context.panel || context.panel === 'explorer') && <div hidden={(context.panel ?? panel) !== 'explorer'}><Explorer rpc={rpc} context={context} /></div>}
    {(!context.panel || context.panel === 'tasks') && <div hidden={(context.panel ?? panel) !== 'tasks'}><Tasks rpc={rpc} context={context} /></div>}
    {(context.panel === 'sync' || (!context.panel && opened.has('sync'))) && <div hidden={(context.panel ?? panel) !== 'sync'}><SyncPanel rpc={rpc} context={context} /></div>}
    {(context.panel === 'er' || (!context.panel && opened.has('er'))) && <div hidden={(context.panel ?? panel) !== 'er'}><GlobalEr rpc={rpc} context={context} /></div>}
    {(context.panel === 'database' || (!context.panel && opened.has('database'))) && <div hidden={(context.panel ?? panel) !== 'database'}><DatabaseExplorer rpc={rpc} context={context} /></div>}
    {(context.panel === 'parity' || (!context.panel && opened.has('parity'))) && <div hidden={(context.panel ?? panel) !== 'parity'}><Parity rpc={rpc} context={context} /></div>}
  </main>;
}

createRoot(document.getElementById('root')!).render(<App />);
