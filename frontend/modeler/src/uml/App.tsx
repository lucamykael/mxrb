import { FormEvent, useCallback, useEffect, useRef, useState } from "react";
import mermaid from "mermaid";

import {
  downloadSource,
  errorMessage,
  fetchCatalog,
  fetchDiagram,
} from "./helpers";
import type {
  Catalog,
  DiagramKind,
  DiagramPayload,
  DiagramSelection,
  SequenceMode,
  SourceFormat,
} from "./types";
import "./uml.css";

const EMPTY_CATALOG: Catalog = { modules: [], microflows: [] };

const INITIAL_SELECTION: DiagramSelection = {
  kind: "class",
  modules: "",
  microflow: "",
  sequenceMode: "root",
  sequenceValue: "",
  depth: "2",
};

const TABS: ReadonlyArray<{ kind: DiagramKind; label: string }> = [
  { kind: "class", label: "Class" },
  { kind: "activity", label: "Activity" },
  { kind: "sequence", label: "Sequence" },
];

mermaid.initialize({
  startOnLoad: false,
  securityLevel: "strict",
  theme: "neutral",
  flowchart: { useMaxWidth: false },
});

export function App() {
  const [selection, setSelection] =
    useState<DiagramSelection>(INITIAL_SELECTION);
  const [catalog, setCatalog] = useState<Catalog>(EMPTY_CATALOG);
  const [catalogLoading, setCatalogLoading] = useState(true);
  const [catalogError, setCatalogError] = useState<string | null>(null);
  const [payload, setPayload] = useState<DiagramPayload | null>(null);
  const [diagramSvg, setDiagramSvg] = useState("");
  const [diagramError, setDiagramError] = useState<string | null>(null);
  const [rendering, setRendering] = useState(false);
  const [sourceFormat, setSourceFormat] = useState<SourceFormat>("mermaid");
  const diagramRef = useRef<HTMLDivElement>(null);
  const renderSequence = useRef(0);
  const activeController = useRef<AbortController | null>(null);

  const updateSelection = useCallback(
    <Key extends keyof DiagramSelection>(
      key: Key,
      value: DiagramSelection[Key],
    ) => {
      setSelection((current) => ({ ...current, [key]: value }));
    },
    [],
  );

  const renderDiagram = useCallback(async (next: DiagramSelection) => {
    activeController.current?.abort();
    const controller = new AbortController();
    activeController.current = controller;
    const sequence = ++renderSequence.current;

    setRendering(true);
    setDiagramError(null);
    setDiagramSvg("");

    try {
      const nextPayload = await fetchDiagram(next, controller.signal);
      if (sequence !== renderSequence.current) return;
      setPayload(nextPayload);
      const result = await mermaid.render(`mxrb-uml-${sequence}`, nextPayload.mermaid);

      if (sequence !== renderSequence.current) return;
      setDiagramSvg(result.svg);

      requestAnimationFrame(() => {
        if (sequence === renderSequence.current && diagramRef.current) {
          result.bindFunctions?.(diagramRef.current);
        }
      });
    } catch (error) {
      if (controller.signal.aborted || sequence !== renderSequence.current) return;
      setDiagramError(errorMessage(error));
    } finally {
      if (sequence === renderSequence.current) setRendering(false);
    }
  }, []);

  useEffect(() => {
    const controller = new AbortController();

    async function load() {
      let initialSelection = INITIAL_SELECTION;

      try {
        const nextCatalog = await fetchCatalog(controller.signal);
        if (controller.signal.aborted) return;
        const firstMicroflow = nextCatalog.microflows[0] || "";
        initialSelection = {
          ...INITIAL_SELECTION,
          microflow: firstMicroflow,
          sequenceValue: firstMicroflow,
        };
        setCatalog(nextCatalog);
        setSelection(initialSelection);
      } catch (error) {
        if (controller.signal.aborted) return;
        setCatalogError(errorMessage(error));
      } finally {
        if (!controller.signal.aborted) {
          setCatalogLoading(false);
          void renderDiagram(initialSelection);
        }
      }
    }

    void load();
    return () => {
      controller.abort();
      activeController.current?.abort();
    };
  }, [renderDiagram]);

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void renderDiagram(selection);
  }

  function selectKind(kind: DiagramKind) {
    updateSelection("kind", kind);
  }

  function selectSequenceMode(mode: SequenceMode) {
    updateSelection("sequenceMode", mode);
  }

  const source = payload?.[sourceFormat] || "";
  const sequencePlaceholder =
    selection.sequenceMode === "root" ? "Sales.CreateOrder" : "Sales";

  return (
    <div className="uml-app">
      <header className="uml-header">
        <h1>MXRB UML</h1>
        <span>Class · Activity · Sequence</span>
      </header>

      <main className="uml-layout">
        <aside className="uml-sidebar">
          <form onSubmit={submit}>
            <div className="uml-tabs" role="tablist" aria-label="Tipo de diagrama">
              {TABS.map((tab) => (
                <button
                  aria-selected={selection.kind === tab.kind}
                  className={`uml-tab${selection.kind === tab.kind ? " active" : ""}`}
                  data-kind={tab.kind}
                  key={tab.kind}
                  onClick={() => selectKind(tab.kind)}
                  role="tab"
                  type="button"
                >
                  {tab.label}
                </button>
              ))}
            </div>

            <datalist id="module-list">
              {catalog.modules.map((name) => (
                <option key={name} value={name} />
              ))}
            </datalist>
            <datalist id="microflow-list">
              {catalog.microflows.map((name) => (
                <option key={name} value={name} />
              ))}
            </datalist>

            {selection.kind === "class" && (
              <section id="class-controls">
                <label htmlFor="modules">Módulos</label>
                <input
                  id="modules"
                  list="module-list"
                  onChange={(event) => updateSelection("modules", event.target.value)}
                  placeholder="Sales,Billing"
                  value={selection.modules}
                />
                <small>Vazio inclui todos; separe vários por vírgula.</small>
              </section>
            )}

            {selection.kind === "activity" && (
              <section id="activity-controls">
                <label htmlFor="microflow">Microflow</label>
                <input
                  id="microflow"
                  list="microflow-list"
                  onChange={(event) =>
                    updateSelection("microflow", event.target.value)
                  }
                  placeholder="Sales.CreateOrder"
                  value={selection.microflow}
                />
              </section>
            )}

            {selection.kind === "sequence" && (
              <section id="sequence-controls">
                <label htmlFor="sequence-mode">Origem</label>
                <select
                  id="sequence-mode"
                  onChange={(event) =>
                    selectSequenceMode(event.target.value as SequenceMode)
                  }
                  value={selection.sequenceMode}
                >
                  <option value="root">Microflow raiz</option>
                  <option value="module">Módulo</option>
                </select>

                <label htmlFor="sequence-value">Nome qualificado</label>
                <input
                  id="sequence-value"
                  list={
                    selection.sequenceMode === "root"
                      ? "microflow-list"
                      : "module-list"
                  }
                  onChange={(event) =>
                    updateSelection("sequenceValue", event.target.value)
                  }
                  placeholder={sequencePlaceholder}
                  value={selection.sequenceValue}
                />

                <label htmlFor="depth">Profundidade</label>
                <input
                  disabled={selection.sequenceMode === "module"}
                  id="depth"
                  min="0"
                  onChange={(event) => updateSelection("depth", event.target.value)}
                  type="number"
                  value={selection.depth}
                />
              </section>
            )}

            {catalogLoading && (
              <p className="uml-status" role="status">Carregando catálogo…</p>
            )}
            {catalogError && (
              <p className="uml-error" role="alert">Catálogo: {catalogError}</p>
            )}

            <div className="uml-actions">
              <button className="uml-primary" disabled={rendering} id="render" type="submit">
                {rendering ? "Renderizando…" : "Renderizar diagrama"}
              </button>
              <button
                className="uml-secondary"
                disabled={!payload}
                id="mermaid"
                onClick={() =>
                  payload && downloadSource(payload, "mermaid", selection.kind)
                }
                type="button"
              >
                Exportar Mermaid
              </button>
              <button
                className="uml-secondary"
                disabled={!payload}
                id="plantuml"
                onClick={() =>
                  payload && downloadSource(payload, "plantuml", selection.kind)
                }
                type="button"
              >
                Exportar PlantUML
              </button>
            </div>
          </form>
        </aside>

        <div className="uml-workspace">
          <div className="uml-canvas">
            <div
              aria-busy={rendering}
              className="uml-diagram"
              id="diagram"
              ref={diagramRef}
            >
              {!rendering && catalogLoading && <span>Carregando…</span>}
              {rendering && <span>Renderizando…</span>}
              {!rendering && diagramError && (
                <pre className="uml-error" role="alert">{diagramError}</pre>
              )}
              {!rendering && !diagramError && diagramSvg && (
                <div dangerouslySetInnerHTML={{ __html: diagramSvg }} />
              )}
            </div>
          </div>

          {payload && (
            <details className="uml-source">
              <summary>Mostrar código-fonte</summary>
              <div className="uml-source-tabs" role="tablist" aria-label="Formato do código-fonte">
                {(["mermaid", "plantuml"] as SourceFormat[]).map((format) => (
                  <button
                    aria-selected={sourceFormat === format}
                    className={sourceFormat === format ? "active" : ""}
                    key={format}
                    onClick={() => setSourceFormat(format)}
                    role="tab"
                    type="button"
                  >
                    {format === "mermaid" ? "Mermaid" : "PlantUML"}
                  </button>
                ))}
              </div>
              <pre><code>{source}</code></pre>
            </details>
          )}
        </div>
      </main>
    </div>
  );
}

export default App;
