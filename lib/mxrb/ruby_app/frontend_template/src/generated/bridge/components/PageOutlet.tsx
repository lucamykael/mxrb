import type { PageComponentProps, PageDefinition, WidgetDefinition } from '../../types';

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
    <main className="app-page mxrb-page region-content" aria-busy={busy} data-page={page.name}>
      {(page.widgets || []).map((widget, index) => renderWidget(widget, index, String(index)))}
    </main>
  );
}
