import type { PageComponentProps, PageDefinition, WidgetDefinition } from '../../types';
import { PageTitleContext, PageNameContext, PageLayoutContext } from './PageTitleContext';

interface PageOutletProps {
  page: PageDefinition;
  busy: boolean;
  Widget: PageComponentProps['Widget'];
}

export function PageOutlet({ page, busy, Widget }: PageOutletProps) {
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
          <main className="app-page mxrb-page" aria-busy={busy} data-page={page.name}>
            {(page.widgets || []).map((widget, index) =>
              renderWidget(widget, index, String(index)),
            )}
          </main>
        </PageLayoutContext.Provider>
      </PageNameContext.Provider>
    </PageTitleContext.Provider>
  );
}
