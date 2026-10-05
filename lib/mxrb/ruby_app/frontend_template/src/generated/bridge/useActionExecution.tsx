import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import type { WidgetEvent } from '../types';
import type { ErrorHandler } from './contracts';

function Progress({ blocking, message }: { blocking: boolean; message: string }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    if (!blocking) return;
    const element = dialog.current!;
    const previous = document.activeElement;
    element.showModal();
    return () => {
      element.close();
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
    };
  }, [blocking]);
  return createPortal(
    blocking ? (
      <dialog
        ref={dialog}
        className="mx-progress mx-progress-blocking"
        aria-label={message}
        onCancel={(event) => event.preventDefault()}
      >
        <div role="status">
          <progress aria-label={message} />
          {message}
        </div>
      </dialog>
    ) : (
      <div role="status" className="mx-progress mx-progress-nonblocking">
        <progress aria-label={message} />
        {message}
      </div>
    ),
    document.body,
  );
}

export function useActionExecution(onError: ErrorHandler) {
  const active = useRef(new Set<symbol>());
  const mounted = useRef(true);
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<Record<symbol, { blocking: boolean; message: string }>>(
    {},
  );
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const run = async (
    event: WidgetEvent,
    operation: () => Promise<unknown>,
    before?: () => Promise<boolean>,
  ) => {
    if (active.current.size && event.settings?.disabled_during_execution !== false) return;
    const id = Symbol();
    active.current.add(id);
    setRunning(true);
    const mode = event.settings?.progress;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      if (before && !(await before())) return;
      if (mode === 'Blocking' || mode === 'NonBlocking') {
        const show = () => {
          if (mounted.current)
            setProgress((previous) => ({
              ...previous,
              [id]: {
                blocking: mode === 'Blocking',
                message: event.settings?.progress_message || 'Processing…',
              },
            }));
        };
        if (mode === 'Blocking') show();
        else timer = setTimeout(show, 500);
      }
      return await operation();
    } catch (failure) {
      if (mounted.current) onError(failure);
    } finally {
      clearTimeout(timer);
      active.current.delete(id);
      if (mounted.current) {
        setRunning(active.current.size > 0);
        setProgress((previous) => {
          const next = { ...previous };
          delete next[id];
          return next;
        });
      }
    }
  };
  const indicators = Object.getOwnPropertySymbols(progress).map((id) => progress[id]);
  const indicator = indicators.find((entry) => entry.blocking) || indicators[0];
  return { run, running, feedback: indicator ? <Progress {...indicator} /> : null };
}
