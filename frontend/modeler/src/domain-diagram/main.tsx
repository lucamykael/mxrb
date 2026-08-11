import { StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";

import DomainDiagramApp from "./App";

let root: Root | null = null;

export function mountDomainDiagram(element: HTMLElement) {
  root?.unmount();
  root = createRoot(element);
  root.render(
    <StrictMode>
      <DomainDiagramApp />
    </StrictMode>,
  );
  return root;
}

const element = document.getElementById("root");
if (!element) throw new Error("Elemento #root não encontrado");
mountDomainDiagram(element);
