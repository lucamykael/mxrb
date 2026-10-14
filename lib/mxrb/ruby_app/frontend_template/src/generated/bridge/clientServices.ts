// What the running application offers code written for the Mendix client
// (legacy widgets and JavaScript actions): refreshing data, the progress
// indicator, confirmations, messages and signing out.
export interface ClientServices {
  refresh?(target: { guid?: string; entity?: string }): void;
  confirm?(options: { question: string; proceed?: string; cancel?: string }): Promise<boolean>;
  progress?(visible: boolean): void;
  notify?(kind: 'info' | 'warning' | 'error', message: string): void;
  logout?(): unknown;
}

let services: ClientServices = {};

// Installs the services of a mounted application; the returned function
// restores the previous ones when it unmounts.
export function provideClientServices(next: ClientServices): () => void {
  const previous = services;
  services = next;
  return () => {
    if (services === next) services = previous;
  };
}

export const clientServices = (): ClientServices => services;
