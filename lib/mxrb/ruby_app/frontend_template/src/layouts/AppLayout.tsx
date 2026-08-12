import type { CSSProperties, ReactNode } from 'react';

interface AppLayoutProps {
  className?: string;
  style?: CSSProperties;
  navigation?: ReactNode;
  feedback?: ReactNode;
  children: ReactNode;
}

export function AppLayout({ className, style, navigation, feedback, children }: AppLayoutProps) {
  return (
    <div className={`app-shell mxrb-app-shell mx-page ${className || ''}`.trim()} style={style}>
      {navigation}
      {children}
      {feedback}
    </div>
  );
}
