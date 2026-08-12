import type { AppError } from '../../core/errors';

interface AppFeedbackProps {
  error: AppError | null;
  notice: string | null;
  onDismissError: () => void;
  onDismissNotice: () => void;
}

export function AppFeedback({ error, notice, onDismissError, onDismissNotice }: AppFeedbackProps) {
  return (
    <>
      {error ? (
        <aside className="app-feedback app-feedback--error mxrb-runtime-error" role="alert">
          <button type="button" onClick={onDismissError} aria-label="Dismiss error">
            ×
          </button>
          {error.message}
        </aside>
      ) : null}
      {notice ? (
        <aside className="app-feedback app-feedback--notice mxrb-runtime-notice" role="status">
          <button type="button" onClick={onDismissNotice} aria-label="Dismiss notification">
            ×
          </button>
          {notice}
        </aside>
      ) : null}
    </>
  );
}
