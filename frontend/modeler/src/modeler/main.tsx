import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import "../shared/theme.css";
import { App } from "./App";

const root = document.getElementById("root");
if (!root) throw new Error("MXRB modeler root element is missing");

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
