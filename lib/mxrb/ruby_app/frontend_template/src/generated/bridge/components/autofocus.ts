// A page or popup's Autofocus setting: Always, DesktopOnly (the default) or
// Never. DesktopOnly leaves out touch devices, whose on-screen keyboard would
// open.
const touchDevice = (): boolean =>
  navigator.maxTouchPoints > 0 && (window.matchMedia?.('(pointer: coarse)').matches ?? false);

export const autofocusEnabled = (mode: string | undefined): boolean => {
  const value = (mode || 'DesktopOnly').toLowerCase();
  if (['never', 'disabled', 'off'].includes(value)) return false;
  if (!['desktoponly', 'desktop'].includes(value)) return true;
  return !touchDevice();
};

const FOCUS_WAIT_MS = 10000;
const QUIET_MS = 150;

// Focuses the first element +find+ returns in +container+ once the container
// stops changing for a moment (widgets that load data render later, and the
// first field may be one of them), as long as +free+ says the focus may still
// move. A re-render that replaces the focused element moves the focus to its
// replacement. Returns a function that stops waiting.
export function focusWhenReady(
  container: HTMLElement,
  find: (container: HTMLElement) => HTMLElement | null | undefined,
  free: () => boolean,
): () => void {
  let placed: HTMLElement | null = null;
  let quiet = 0;
  const idle = () =>
    !document.activeElement ||
    document.activeElement === document.body ||
    document.activeElement === container;
  const attempt = () => {
    if (placed?.isConnected) return;
    if (placed ? !idle() : !free()) {
      stop();
      return;
    }
    const target = find(container);
    if (!target) return;
    target.focus();
    placed = target;
  };
  const settle = () => {
    window.clearTimeout(quiet);
    quiet = window.setTimeout(attempt, QUIET_MS);
  };
  const observer = new MutationObserver(settle);
  const timer = window.setTimeout(() => stop(), FOCUS_WAIT_MS);
  const stop = () => {
    observer.disconnect();
    window.clearTimeout(timer);
    window.clearTimeout(quiet);
  };
  observer.observe(container, { childList: true, subtree: true, attributes: true });
  settle();
  return stop;
}
