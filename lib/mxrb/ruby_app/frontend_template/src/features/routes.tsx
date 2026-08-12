import type { ReactNode } from 'react';

export interface ApplicationRoute {
  path: string;
  element: ReactNode;
}

// Add application-owned routes here. This file survives every round-trip.
export const applicationRoutes: ApplicationRoute[] = [];
