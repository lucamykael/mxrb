import { useEffect, useRef, type RefObject } from 'react';
import type { PageComponentProps, PageDefinition, WidgetDefinition } from '../../types';
import { PageTitleContext, PageNameContext, PageLayoutContext } from './PageTitleContext';

interface PageOutletProps {
  page: PageDefinition;
  busy: boolean;
  Widget: PageComponentProps['Widget'];
}

const FOCUSABLE =
  'a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';
const FOCUS_WAIT_MS = 10000;

// As the Mendix client does, an opened page moves the focus to its first
// focusable element, as its Autofocus setting allows (Always, DesktopOnly,
// Never), unless the user has already focused
// something. Widgets that load data appear later, so the search waits for
// them while the page changes.
// DesktopOnly leaves out touch devices, whose on-screen keyboard would open.
const touchDevice = (): boolean =>
  navigator.maxTouchPoints > 0 && (window.matchMedia?.('(pointer: coarse)').matches ?? false);

const autofocusEnabled = (mode: string | undefined): boolean => {
  const value = (mode || 'DesktopOnly').toLowerCase();
  if (['never', 'disabled', 'off'].includes(value)) return false;
  if (!['desktoponly', 'desktop'].includes(value)) return true;
  return !touchDevice();
};

function useInitialFocus(root: RefObject<HTMLElement | null>, mode: string | undefined) {
  useEffect(() => {
    const element = root.current;
    if (!element || !autofocusEnabled(mode)) return;
    const focusFirst = (): boolean => {
      const active = document.activeElement;
      if (active && active !== document.body) return true;
      const target = Array.from(element.querySelectorAll<HTMLElement>(FOCUSABLE)).find(
        (candidate) =>
          !candidate.matches(':disabled') &&
          !candidate.closest('[hidden], [inert]') &&
          (typeof candidate.checkVisibility !== 'function' ||
            candidate.checkVisibility({ visibilityProperty: true })),
      );
      target?.focus();
      return Boolean(target);
    };
    if (focusFirst()) return;
    const observer = new MutationObserver(() => {
      if (focusFirst()) stop();
    });
    const timer = window.setTimeout(() => stop(), FOCUS_WAIT_MS);
    const stop = () => {
      observer.disconnect();
      window.clearTimeout(timer);
    };
    observer.observe(element, { childList: true, subtree: true, attributes: true });
    return stop;
  }, [root, mode]);
}

export function PageOutlet({ page, busy, Widget }: PageOutletProps) {
  const root = useRef<HTMLElement>(null);
  useInitialFocus(root, page.autofocus);
  const renderWidget = (widget: WidgetDefinition, index: number, path: string) => (
    <Widget key={`${path}-${widget.name || widget.type}`} widget={widget} index={index}>
      {(widget.children || []).map((child, childIndex) =>
        renderWidget(child, childIndex, `${path}-${childIndex}`),
      )}
    </Widget>
  );

  return (
    <PageTitleContext.Provider value={page.title}>
      <PageNameContext.Provider value={page.name}>
        <PageLayoutContext.Provider value={page.layout || page.name}>
          <main ref={root} className="app-page mxrb-page" aria-busy={busy} data-page={page.name}>
            {(page.widgets || []).map((widget, index) =>
              renderWidget(widget, index, String(index)),
            )}
          </main>
        </PageLayoutContext.Provider>
      </PageNameContext.Provider>
    </PageTitleContext.Provider>
  );
}
