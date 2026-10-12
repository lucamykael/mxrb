import { useEffect, useRef, type RefObject } from 'react';
import type { PageComponentProps, PageDefinition, WidgetDefinition } from '../../types';
import { autofocusEnabled, focusWhenReady } from './autofocus';
import { PageTitleContext, PageNameContext, PageLayoutContext } from './PageTitleContext';

interface PageOutletProps {
  page: PageDefinition;
  busy: boolean;
  Widget: PageComponentProps['Widget'];
}

const FOCUSABLE =
  'a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';

// As the Mendix client does, an opened page moves the focus to its first
// focusable element, as its Autofocus setting allows (Always, DesktopOnly,
// Never), unless the user has already focused
// something. Widgets that load data appear later, so the search waits for
// them while the page changes.
function useInitialFocus(root: RefObject<HTMLElement | null>, mode: string | undefined) {
  useEffect(() => {
    const element = root.current;
    if (!element || !autofocusEnabled(mode)) return;
    return focusWhenReady(
      element,
      (container) =>
        Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE)).find(
          (candidate) =>
            !candidate.matches(':disabled') &&
            !candidate.closest('[hidden], [inert]') &&
            (typeof candidate.checkVisibility !== 'function' ||
              candidate.checkVisibility({ visibilityProperty: true })),
        ),
      () => !document.activeElement || document.activeElement === document.body,
    );
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
