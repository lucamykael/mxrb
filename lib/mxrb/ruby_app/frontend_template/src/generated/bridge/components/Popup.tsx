import { useEffect, useId, useRef, type ReactNode } from 'react';
import type { PopupDefinition } from '../../types';

export function Popup({
  title,
  settings,
  children,
  onClose,
  autofocus,
}: {
  title: string;
  settings: PopupDefinition;
  children: ReactNode;
  onClose: () => void;
  autofocus?: string;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const id = useId();
  const drag = useRef<{ x: number; y: number; left: number; top: number } | null>(null);
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const element = dialog.current!;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (settings.mode === 'modal') element.showModal();
    else element.show();
    Object.assign(element.style, {
      left: `${Math.max(0, (window.innerWidth - element.offsetWidth) / 2)}px`,
      top: `${Math.max(0, (window.innerHeight - element.offsetHeight) * 0.35)}px`,
    });
    if (['disabled', 'off'].includes(autofocus?.toLowerCase() || '')) element.focus();
    else if (
      !['desktop', 'desktoponly'].includes(autofocus?.toLowerCase() || '') ||
      window.matchMedia('(pointer: fine)').matches
    ) {
      element
        .querySelector<HTMLElement>(
          'input:not([disabled]), textarea:not([disabled]), select:not([disabled])',
        )
        ?.focus();
    }
    return () => {
      element.close();
      if (previous?.isConnected) previous.focus();
    };
  }, [settings.mode, autofocus]);
  return (
    <dialog
      ref={dialog}
      tabIndex={-1}
      aria-label={title}
      className="modal-dialog mx-window mx-window-active mxrb-popup"
      aria-modal={settings.mode === 'modal' ? true : undefined}
      onCancel={(event) => {
        event.preventDefault();
        close.current();
      }}
      style={{
        width: settings.width ? `${settings.width}px` : undefined,
        height: settings.height ? `${settings.height}px` : undefined,
        resize: 'none',
        margin: 0,
      }}
    >
      <div
        className="modal-content mx-window-content"
        style={{ height: '100%', display: 'flex', flexDirection: 'column' }}
      >
        <header
          className="modal-header mx-window-header"
          style={{ userSelect: 'none', flex: '0 0 auto' }}
          onPointerDown={(event) => {
            if (event.button !== 0 || (event.target as HTMLElement).closest('button')) return;
            const box = dialog.current!.getBoundingClientRect();
            drag.current = { x: event.clientX, y: event.clientY, left: box.left, top: box.top };
            event.currentTarget.setPointerCapture(event.pointerId);
          }}
          onPointerMove={(event) => {
            if (!drag.current) return;
            const element = dialog.current!;
            const left = Math.max(
              0,
              Math.min(
                window.innerWidth - element.offsetWidth,
                drag.current.left + event.clientX - drag.current.x,
              ),
            );
            const top = Math.max(
              0,
              Math.min(window.innerHeight - 48, drag.current.top + event.clientY - drag.current.y),
            );
            Object.assign(element.style, {
              inset: 'auto',
              margin: '0',
              left: `${left}px`,
              top: `${top}px`,
            });
          }}
          onPointerUp={() => {
            drag.current = null;
          }}
          onLostPointerCapture={() => {
            drag.current = null;
          }}
        >
          <button type="button" className="close" aria-label="Close" onClick={onClose}>
            ×
          </button>
          <h4 id={`${id}-caption`}>{title}</h4>
        </header>
        <div className="modal-body mx-window-body" style={{ flex: '1 1 auto' }}>
          <div className="mx-placeholder">{children}</div>
        </div>
      </div>
      {settings.resizable &&
        ['n', 'e', 's', 'w', 'ne', 'se', 'sw', 'nw'].map((edge) => (
          <div
            key={edge}
            className={`mx-resizer mx-resizer-${edge}`}
            role="button"
            aria-label={`Resize ${edge}`}
            tabIndex={0}
            onKeyDown={(event) => {
              if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return;
              event.preventDefault();
              const element = dialog.current!;
              const width =
                element.offsetWidth +
                (event.key === 'ArrowRight' ? 10 : event.key === 'ArrowLeft' ? -10 : 0);
              const height =
                element.offsetHeight +
                (event.key === 'ArrowDown' ? 10 : event.key === 'ArrowUp' ? -10 : 0);
              Object.assign(element.style, {
                width: `${Math.max(200, width)}px`,
                height: `${Math.max(100, height)}px`,
              });
            }}
            onPointerDown={(event) => {
              if (event.button !== 0) return;
              event.preventDefault();
              const element = dialog.current!;
              const box = element.getBoundingClientRect();
              const start = { x: event.clientX, y: event.clientY };
              const handle = event.currentTarget;
              handle.setPointerCapture(event.pointerId);
              handle.onpointermove = (move) => {
                const dx = move.clientX - start.x;
                const dy = move.clientY - start.y;
                const width = Math.max(
                  200,
                  Math.min(
                    window.innerWidth,
                    box.width + (edge.includes('w') ? -dx : edge.includes('e') ? dx : 0),
                  ),
                );
                const height = Math.max(
                  100,
                  Math.min(
                    window.innerHeight,
                    box.height + (edge.includes('n') ? -dy : edge.includes('s') ? dy : 0),
                  ),
                );
                Object.assign(element.style, {
                  width: `${width}px`,
                  height: `${height}px`,
                  left: `${Math.max(0, edge.includes('w') ? box.right - width : box.left)}px`,
                  top: `${Math.max(0, edge.includes('n') ? box.bottom - height : box.top)}px`,
                });
              };
              handle.onlostpointercapture = () => {
                handle.onpointermove = null;
              };
            }}
          />
        ))}
    </dialog>
  );
}
