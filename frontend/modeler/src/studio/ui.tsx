import { useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import type { StudioRpc } from './rpc';
import type { StudioContext } from './types';

/** Studio Pro tool-window glyphs: 16 px, single stroke, drawn in the current text colour. */
const PATHS: Record<string, string> = {
  run: 'M5 3.5v9l7-4.5z',
  stop: 'M4.5 4.5h7v7h-7z',
  refresh: 'M12.5 8a4.5 4.5 0 1 1-1.3-3.2M12.5 2.5v2.8H9.7',
  newFile: 'M4 1.5h5l3 3v10H4zM9 1.5v3h3M8 7.5v5M5.5 10h5',
  newFolder: 'M1.5 3.5h5l1.5 1.5h6.5v8.5h-13zM8 7v5M5.5 9.5h5',
  rename: 'M2.5 11.5l7.8-7.8 2 2-7.8 7.8H2.5zM9.3 4.7l2 2',
  delete: 'M3 4.5h10M6 4.5V3h4v1.5M4.5 4.5l.7 9h5.6l.7-9M7 7v4.5M9 7v4.5',
  save: 'M2.5 2.5h9l2 2v9h-11zM5 2.5v3.5h5V2.5M5 13.5V9.5h6v4',
  clear: 'M3 13h10M4.5 10.5l5-5 2.5 2.5-3 3H6.5z',
  scrollLock: 'M8 2v12M5 11l3 3 3-3M4.5 6.5h7v3h-7z',
  search: 'M7 2.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9zM10.3 10.3L14 14',
  expandAll: 'M3 5.5l5 5 5-5',
  collapseAll: 'M3 10.5l5-5 5 5',
  branch: 'M5 2.5v11M5 5.5a5 5 0 0 0 6 4M11 4.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3M5 11.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3',
  database: 'M3 3.5c0-1 2.2-1.5 5-1.5s5 .5 5 1.5v9c0 1-2.2 1.5-5 1.5s-5-.5-5-1.5zM3 3.5c0 1 2.2 1.5 5 1.5s5-.5 5-1.5M3 8c0 1 2.2 1.5 5 1.5s5-.5 5-1.5',
  connect: 'M6 10l4-4M4.5 8.5l-1.5 1.5a2 2 0 0 0 3 3l1.5-1.5M11.5 7.5l1.5-1.5a2 2 0 0 0-3-3l-1.5 1.5',
  zoomIn: 'M7 2.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9zM10.3 10.3L14 14M5 7h4M7 5v4',
  zoomOut: 'M7 2.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9zM10.3 10.3L14 14M5 7h4',
  fit: 'M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10',
  filter: 'M2 3h12l-4.5 5.5V13l-3 1.5v-6z',
  entity: 'M2.5 2.5h11v11h-11zM2.5 5.5h11M6.5 8h3M6.5 10.5h3',
  table: 'M2.5 3h11v10h-11zM2.5 6h11M2.5 9.5h11M7 6v7',
  key: 'M10 2.5a3.5 3.5 0 1 1-3.2 4.9L2.5 11.7v1.8h2.2v-1.5h1.5v-1.5h1.5l.8-.8A3.5 3.5 0 0 1 10 2.5z',
  explain: 'M2.5 3h4v3h-4zM9.5 3h4v3h-4zM6 10h4v3H6zM4.5 6v2h7V6M8 8v2',
  folder: 'M1.5 3.5h5l1.5 1.5h6.5v8.5h-13z',
  file: 'M4 1.5h5l3 3v10H4zM9 1.5v3h3',
  ruby: 'M4 2.5h8l2.5 3.5L8 14 1.5 6zM1.5 6h13M6 2.5L5 6l3 8 3-8-1-3.5',
  task: 'M3 3.5h10v9H3zM5.5 6.5l1.5 1.5-1.5 1.5M8.5 10h2.5',
  saved: 'M4 2.5h8v11l-4-3-4 3z'
};

export type IconName = keyof typeof PATHS;

export function Icon({ name }: { name: IconName }) {
  return <svg className="mx-icon" data-icon={name} viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" focusable="false">
    <path d={PATHS[name]} fill={name === 'run' || name === 'stop' ? 'currentColor' : 'none'} stroke="currentColor"
      strokeWidth="1.1" strokeLinejoin="round" strokeLinecap="round" />
  </svg>;
}

export function Toolbar({ label, children }: { label: string; children: ReactNode }) {
  return <div className="mx-toolbar" role="toolbar" aria-label={label}>{children}</div>;
}

export function ToolButton({ icon, label, text, onClick, disabled, pressed, tone }: {
  icon: IconName; label: string; text?: string; onClick(): void; disabled?: boolean; pressed?: boolean;
  tone?: 'run' | 'stop';
}) {
  return <button type="button" className={`mx-tool${tone ? ` mx-tool-${tone}` : ''}`} title={label} aria-label={label}
    aria-pressed={pressed} disabled={disabled} onClick={onClick}><Icon name={icon} />{text && <span>{text}</span>}</button>;
}

export type MenuItem = { label: string; shortcut?: string; disabled?: boolean; action(): void } | 'separator';

/** Studio Pro context menus: white, separators, right-aligned shortcuts. Escape or outside click closes. */
export function ContextMenu({ x, y, items, onClose }: { x: number; y: number; items: MenuItem[]; onClose(): void }) {
  const menu = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState({ left: x, top: y });
  useEffect(() => {
    const element = menu.current;
    if (element) {
      setPosition({ left: Math.max(0, Math.min(x, innerWidth - element.offsetWidth - 2)),
        top: Math.max(0, Math.min(y, innerHeight - element.offsetHeight - 2)) });
      element.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
    }
    const close = (event: Event) => { if (!menu.current?.contains(event.target as Node)) onClose(); };
    const key = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose(); };
    addEventListener('mousedown', close, true); addEventListener('keydown', key, true); addEventListener('blur', onClose);
    return () => { removeEventListener('mousedown', close, true); removeEventListener('keydown', key, true); removeEventListener('blur', onClose); };
  }, [x, y, onClose]);
  return <div ref={menu} className="mx-menu" role="menu" style={position} onKeyDown={event => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    const buttons = [...menu.current!.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')];
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    buttons[(index + (event.key === 'ArrowDown' ? 1 : buttons.length - 1)) % buttons.length]?.focus();
  }}>
    {items.map((item, index) => item === 'separator' ? <div key={index} className="mx-menu-separator" role="separator" />
      : <button key={item.label} type="button" role="menuitem" disabled={item.disabled}
        onClick={() => { onClose(); item.action(); }}><span>{item.label}</span><kbd>{item.shortcut ?? ''}</kbd></button>)}
  </div>;
}

export type DialogRequest = {
  kind: 'input' | 'confirm'; title: string; message?: string; label?: string; value?: string;
  buttons?: string[]; warning?: boolean;
};
export type DialogResult = { button: string | null; value?: string };

/**
 * Studio Pro dialogs are native windows: inside Studio the host shows them. The
 * in-page fallback (same layout) serves the standalone browser acceptance only.
 */
export function useDialogs(rpc: StudioRpc, context: StudioContext) {
  const [pending, setPending] = useState<{ request: DialogRequest; resolve(result: DialogResult): void }>();
  async function show(request: DialogRequest): Promise<DialogResult> {
    const buttons = request.buttons ?? (request.kind === 'input' ? ['OK', 'Cancel'] : ['OK', 'Cancel']);
    if (context.capabilities?.native_dialogs) {
      return rpc.call<DialogResult>('host/dialog', { ...request, buttons });
    }
    return new Promise(resolve => setPending({ request: { ...request, buttons }, resolve }));
  }
  const element = pending ? <PageDialog request={pending.request} onClose={result => {
    pending.resolve(result); setPending(undefined);
  }} /> : null;
  return { show, element };
}

function PageDialog({ request, onClose }: { request: DialogRequest; onClose(result: DialogResult): void }) {
  const [value, setValue] = useState(request.value ?? '');
  const input = useRef<HTMLInputElement>(null);
  const buttons = request.buttons ?? ['OK', 'Cancel'];
  useEffect(() => {
    const field = input.current;
    if (field) {
      field.focus();
      const dot = request.value?.lastIndexOf('.') ?? -1;
      field.setSelectionRange(0, dot > 0 ? dot : field.value.length);
    }
  }, [request.value]);
  const accept = () => onClose({ button: buttons[0], value });
  return <div className="mx-dialog-backdrop">
    <div className="mx-dialog" role="dialog" aria-modal="true" aria-label={request.title}
      onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); onClose({ button: null }); } }}>
      <div className="mx-dialog-title">{request.title}</div>
      <form className="mx-dialog-body" onSubmit={event => { event.preventDefault(); accept(); }}>
        {request.kind === 'confirm' && <p className="mx-dialog-message">
          {request.warning && <span className="mx-warning-sign" aria-hidden="true">⚠</span>}
          <span>{request.message}</span></p>}
        {request.kind === 'input' && <>
          {request.message && <p>{request.message}</p>}
          <label className="mx-dialog-field"><span>{request.label ?? 'Name'}</span>
            <input ref={input} value={value} onChange={event => setValue(event.target.value)} /></label>
        </>}
        <div className="mx-dialog-buttons">
          {buttons.map((button, index) => <button key={button} type={index === 0 ? 'submit' : 'button'}
            className={index === 0 && request.kind === 'input' ? 'mx-primary' : undefined}
            disabled={index === 0 && request.kind === 'input' && !value.trim()}
            autoFocus={request.kind === 'confirm' && index === buttons.length - 1}
            onClick={index === 0 ? undefined : () => onClose({ button: button === 'Cancel' ? null : button, value })}>{button}</button>)}
        </div>
      </form>
    </div>
  </div>;
}

export function errorText(reason: unknown) {
  if (reason instanceof DOMException && reason.name === 'AbortError') return '';
  return reason instanceof Error ? reason.message : String(reason);
}
