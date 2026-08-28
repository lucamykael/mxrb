import pages from '../../pages';
import type { PageComponentProps, PageDefinition } from '../../types';

interface PageOutletProps {
  page: PageDefinition;
  busy: boolean;
  Widget: PageComponentProps['Widget'];
}

export function PageOutlet({ page, busy, Widget }: PageOutletProps) {
  const PageComponent = pages[page.name as keyof typeof pages];
  if (!PageComponent) {
    return (
      <main className="app-page mxrb-page region-content" role="alert">
        Generated React page not found: {page.name}
      </main>
    );
  }
  return <PageComponent busy={busy} Widget={Widget} />;
}
