import { useEffect, useMemo, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";

import {
  CARD_WIDTH,
  HEAD_HEIGHT,
  WORLD_HEIGHT,
  WORLD_WIDTH,
  anchorPoint,
  cardHeight,
  closestAnchor,
  kindCode,
  kindLabel,
  pathFor,
  visibleAttributes,
} from "./helpers";
import type {
  Anchor,
  AttributeMode,
  DiagramAssociation,
  DiagramData,
  DiagramEntity,
  LayoutPayload,
  LayoutResult,
  RoutingMode,
  Selection,
} from "./types";
import { requestJson } from "../shared/api";

import "./styles.css";

const ANCHOR_OPTIONS: Array<[Anchor, string]> = [
  ["north", "Superior"],
  ["east", "Direita"],
  ["south", "Inferior"],
  ["west", "Esquerda"],
];

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

export default function DomainDiagramApp() {
  const [data, setData] = useState<DiagramData | null>(null);
  const dataRef = useRef<DiagramData | null>(null);
  const [selectedModules, setSelectedModules] = useState<Set<string>>(new Set());
  const selectedModulesRef = useRef<Set<string>>(new Set());
  const [zoom, setZoomState] = useState(1);
  const zoomRef = useRef(1);
  const [dirty, setDirtyValue] = useState(false);
  const [dirtyLabel, setDirtyLabel] = useState("Layout sem alterações");
  const [selected, setSelected] = useState<Selection>(null);
  const [attributeMode, setAttributeMode] = useState<AttributeMode>("all");
  const attributeModeRef = useRef<AttributeMode>("all");
  const [routing, setRouting] = useState<RoutingMode>("orthogonal");
  const [query, setQuery] = useState("");
  const [grid, setGrid] = useState(true);
  const [, setRevision] = useState(0);
  const [toast, setToast] = useState({ message: "", error: false, visible: false });
  const toastTimer = useRef<number | null>(null);
  const viewportRef = useRef<HTMLElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);

  const visibleModules = useMemo(
    () => data?.modules.filter((module) => selectedModules.has(module.name)) ?? [],
    [data, selectedModules],
  );
  const visibleEntities = useMemo(
    () => visibleModules.flatMap((module) => module.entities),
    [visibleModules],
  );
  const entitiesByQualifiedName = useMemo(
    () =>
      Object.fromEntries(
        visibleEntities.map((entity) => [entity.qualified_name, entity]),
      ) as Record<string, DiagramEntity>,
    [visibleEntities],
  );
  const visibleAssociations = useMemo(() => {
    const names = new Set(visibleEntities.map((entity) => entity.qualified_name));
    const seen = new Set<string>();
    return visibleModules
      .flatMap((module) => module.associations)
      .filter((association) => {
        if (
          !names.has(association.from) ||
          !names.has(association.to) ||
          seen.has(association.id)
        ) {
          return false;
        }
        seen.add(association.id);
        return true;
      });
  }, [visibleEntities, visibleModules]);

  function bumpRevision() {
    setRevision((current) => current + 1);
  }

  function setDirty(value = true) {
    setDirtyValue(value);
    setDirtyLabel(value ? "● Alterações não salvas" : "Layout salvo");
  }

  function showToast(message: string, error = false) {
    setToast({ message, error, visible: true });
    if (toastTimer.current !== null) window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(
      () => setToast((current) => ({ ...current, visible: false })),
      2600,
    );
  }

  function updateZoom(value: number) {
    const next = Math.max(0.25, Math.min(2, value));
    zoomRef.current = next;
    setZoomState(next);
  }

  function findEntity(id: string) {
    return dataRef.current?.modules
      .flatMap((module) => module.entities)
      .find((entity) => entity.id === id);
  }

  function findAssociation(id: string) {
    return dataRef.current?.modules
      .flatMap((module) => module.associations)
      .find((association) => association.id === id);
  }

  function currentVisibleModules(modules = selectedModulesRef.current) {
    return dataRef.current?.modules.filter((module) => modules.has(module.name)) ?? [];
  }

  function currentVisibleEntities(modules = selectedModulesRef.current) {
    return currentVisibleModules(modules).flatMap((module) => module.entities);
  }

  function currentEntitiesByQualifiedName(modules = selectedModulesRef.current) {
    return Object.fromEntries(
      currentVisibleEntities(modules).map((entity) => [entity.qualified_name, entity]),
    ) as Record<string, DiagramEntity>;
  }

  function calculateBounds(modules = selectedModulesRef.current) {
    const entities = currentVisibleEntities(modules);
    if (!entities.length) return { x: 0, y: 0, width: 1000, height: 700 };
    const mode = attributeModeRef.current;
    const minX = Math.min(...entities.map((entity) => entity.x));
    const minY = Math.min(...entities.map((entity) => entity.y));
    const maxX = Math.max(...entities.map((entity) => entity.x + CARD_WIDTH));
    const maxY = Math.max(...entities.map((entity) => entity.y + cardHeight(entity, mode)));
    return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
  }

  function fit(modules = selectedModulesRef.current) {
    const viewport = viewportRef.current;
    if (!viewport) return;
    const bounds = calculateBounds(modules);
    const nextZoom = Math.min(
      1.3,
      (viewport.clientWidth - 100) / bounds.width,
      (viewport.clientHeight - 100) / bounds.height,
    );
    updateZoom(nextZoom);
    viewport.scrollLeft = Math.max(0, (bounds.x - 45) * nextZoom);
    viewport.scrollTop = Math.max(0, (bounds.y - 45) * nextZoom);
  }

  function arrange(modules = selectedModulesRef.current, markDirty = true) {
    const shownModules = currentVisibleModules(modules);
    const moduleColumns = Math.max(1, Math.ceil(Math.sqrt(shownModules.length)));
    shownModules.forEach((module, moduleIndex) => {
      const entityColumns = Math.max(1, Math.ceil(Math.sqrt(module.entities.length)));
      const baseX = 100 + (moduleIndex % moduleColumns) * 1050;
      const baseY = 90 + Math.floor(moduleIndex / moduleColumns) * 850;
      module.entities.forEach((entity, index) => {
        entity.x = baseX + (index % entityColumns) * 300;
        entity.y = baseY + Math.floor(index / entityColumns) * 230;
      });
    });
    if (markDirty) setDirty(true);
    bumpRevision();
    window.setTimeout(() => fit(modules), 0);
  }

  function toggleModule(moduleName: string) {
    const next = new Set(selectedModulesRef.current);
    const adding = !next.has(moduleName);
    if (adding) next.add(moduleName);
    else next.delete(moduleName);
    selectedModulesRef.current = next;
    setSelectedModules(next);
    setSelected(null);
    if (adding && next.size > 1) arrange(next, false);
    else window.setTimeout(() => fit(next), 0);
  }

  function selectAllModules() {
    if (!dataRef.current) return;
    const next = new Set(dataRef.current.modules.map((module) => module.name));
    selectedModulesRef.current = next;
    setSelectedModules(next);
    setSelected(null);
    arrange(next, false);
  }

  function clearModules() {
    const next = new Set<string>();
    selectedModulesRef.current = next;
    setSelectedModules(next);
    setSelected(null);
  }

  function startEntityDrag(event: ReactPointerEvent, entity: DiagramEntity) {
    event.preventDefault();
    event.stopPropagation();
    setSelected({ kind: "entity", id: entity.id });
    const startX = event.clientX;
    const startY = event.clientY;
    const originX = entity.x;
    const originY = entity.y;

    const move = (pointer: PointerEvent) => {
      entity.x = Math.round((originX + (pointer.clientX - startX) / zoomRef.current) / 10) * 10;
      entity.y = Math.round((originY + (pointer.clientY - startY) / zoomRef.current) / 10) * 10;
      setDirty(true);
      bumpRevision();
    };
    const stop = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", stop);
      bumpRevision();
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", stop, { once: true });
  }

  function startAnchorDrag(
    event: ReactPointerEvent,
    association: DiagramAssociation,
    side: "source" | "target",
  ) {
    event.preventDefault();
    event.stopPropagation();
    setSelected({ kind: "association", id: association.id });
    const entity = currentEntitiesByQualifiedName()[
      side === "source" ? association.from : association.to
    ];
    if (!entity) return;

    const move = (pointer: PointerEvent | ReactPointerEvent) => {
      const stage = stageRef.current;
      if (!stage) return;
      const rectangle = stage.getBoundingClientRect();
      const x = (pointer.clientX - rectangle.left) / zoomRef.current;
      const y = (pointer.clientY - rectangle.top) / zoomRef.current;
      association[`${side}_anchor`] = closestAnchor(
        entity,
        x,
        y,
        attributeModeRef.current,
      );
      association.anchor_dirty = true;
      setDirty(true);
      bumpRevision();
    };
    const stop = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", stop);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", stop, { once: true });
    move(event);
  }

  function setAssociationAnchor(
    association: DiagramAssociation,
    side: "source" | "target",
    anchor: Anchor,
  ) {
    association[`${side}_anchor`] = anchor;
    association.anchor_dirty = true;
    setDirty(true);
    bumpRevision();
  }

  async function save() {
    const currentData = dataRef.current;
    if (!currentData) return;
    const payload: LayoutPayload = {
      modules: currentData.modules.map((module) => ({
        name: module.name,
        entities: module.entities.map((entity) => ({
          id: entity.id,
          x: entity.x,
          y: entity.y,
        })),
        associations: module.associations
          .filter(
            (association) =>
              association.anchor_storage === "native" || association.anchor_dirty,
          )
          .map((association) => ({
            id: association.id,
            source_anchor: association.source_anchor,
            target_anchor: association.target_anchor,
          })),
      })),
    };

    try {
      const result = await requestJson<LayoutResult>("/api/layout", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-MXRB-Token": currentData.csrf_token,
        },
        body: JSON.stringify(payload),
      });
      currentData.modules
        .flatMap((module) => module.associations)
        .forEach((association) => {
          association.anchor_dirty = false;
        });
      setDirty(false);
      showToast(`Layout salvo · ${result.changed} item(ns) alterado(s)`);
    } catch (error) {
      showToast(errorMessage(error), true);
    }
  }

  function exportPng() {
    const currentData = dataRef.current;
    if (!currentData) return;
    const bounds = calculateBounds();
    const padding = 55;
    const scale = Math.min(
      2,
      14000 / Math.max(bounds.width + padding * 2, bounds.height + padding * 2),
    );
    const canvas = document.createElement("canvas");
    canvas.width = Math.ceil((bounds.width + padding * 2) * scale);
    canvas.height = Math.ceil((bounds.height + padding * 2) * scale);
    const context = canvas.getContext("2d");
    if (!context) {
      showToast("Não foi possível criar a imagem PNG", true);
      return;
    }
    context.scale(scale, scale);
    context.fillStyle = "#f4f5f7";
    context.fillRect(0, 0, canvas.width / scale, canvas.height / scale);
    context.translate(-bounds.x + padding, -bounds.y + padding);

    const entityMap = currentEntitiesByQualifiedName();
    context.lineWidth = 1.5;
    context.strokeStyle = "#697482";
    context.fillStyle = "#505965";
    context.font = "10px system-ui";
    visibleAssociations.forEach((association) => {
      const path = pathFor(association, entityMap, attributeMode, routing);
      if (!path) return;
      const numbers = path.d.match(/-?\d+(?:\.\d+)?/g)?.map(Number);
      if (!numbers) return;
      context.beginPath();
      context.moveTo(numbers[0], numbers[1]);
      for (let index = 2; index < numbers.length; index += 2) {
        context.lineTo(numbers[index], numbers[index + 1]);
      }
      context.stroke();
      context.fillText(association.name, path.x + 5, path.y - 6);
    });

    const palette = {
      entity: { head: "#cfe5fb", border: "#4b8bc8" },
      dto: { head: "#f8e9a3", border: "#d2a928" },
      oql_view: { head: "#ccebd4", border: "#49a566" },
    };
    visibleEntities.forEach((entity) => {
      const height = cardHeight(entity, attributeMode);
      const colors = palette[entity.kind] || palette.entity;
      context.fillStyle = "#fff";
      context.strokeStyle = colors.border;
      context.fillRect(entity.x, entity.y, CARD_WIDTH, height);
      context.strokeRect(entity.x, entity.y, CARD_WIDTH, height);
      context.fillStyle = colors.head;
      context.fillRect(entity.x, entity.y, CARD_WIDTH, HEAD_HEIGHT);
      context.strokeStyle = colors.border;
      context.beginPath();
      context.moveTo(entity.x, entity.y + HEAD_HEIGHT);
      context.lineTo(entity.x + CARD_WIDTH, entity.y + HEAD_HEIGHT);
      context.stroke();
      context.fillStyle = "#242a31";
      context.font = "bold 13px system-ui";
      context.fillText(entity.name, entity.x + 10, entity.y + 22);
      context.font = "10px system-ui";
      context.textAlign = "right";
      context.fillText(entity.module, entity.x + CARD_WIDTH - 10, entity.y + 22);
      context.textAlign = "left";
      context.font = "11px system-ui";
      visibleAttributes(entity, attributeMode).forEach((attribute, index) => {
        const y = entity.y + HEAD_HEIGHT + 18 + index * 23;
        context.fillStyle = "#303640";
        context.fillText(`${attribute.key ? "◆ " : ""}${attribute.name}`, entity.x + 10, y);
        context.fillStyle = "#78828d";
        context.textAlign = "right";
        context.fillText(attribute.type, entity.x + CARD_WIDTH - 10, y);
        context.textAlign = "left";
      });
    });

    const names = visibleModules.map((module) => module.name);
    const suffix = names.length === 1 ? names[0] : "multi-module";
    const link = document.createElement("a");
    link.download = `${currentData.project.name}-${suffix}-domain-model.png`.replace(/\s+/g, "-");
    link.href = canvas.toDataURL("image/png");
    link.click();
    showToast("PNG exportado em alta resolução");
  }

  useEffect(() => {
    let cancelled = false;
    requestJson<DiagramData>("/api/diagram")
      .then((result) => {
        if (cancelled) return;
        result.modules.forEach((module) => {
          module.entities.forEach((entity) => {
            entity.module = entity.module || module.name;
          });
          module.associations.forEach((association) => {
            association.module = module.name;
          });
        });
        const nonEmpty = result.modules.filter((module) => module.entities.length);
        const initial = result.module_filter_applied ? nonEmpty : nonEmpty.slice(0, 1);
        const initialNames = new Set(initial.map((module) => module.name));
        dataRef.current = result;
        selectedModulesRef.current = initialNames;
        setData(result);
        setSelectedModules(initialNames);
        updateZoom(1);
        if (initial.length > 1) arrange(initialNames, false);
        else window.setTimeout(() => fit(initialNames), 0);
      })
      .catch((error) => {
        if (!cancelled) showToast(errorMessage(error), true);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const beforeUnload = (event: BeforeUnloadEvent) => {
      if (!dirty) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", beforeUnload);
    return () => window.removeEventListener("beforeunload", beforeUnload);
  }, [dirty]);

  useEffect(
    () => () => {
      if (toastTimer.current !== null) window.clearTimeout(toastTimer.current);
    },
    [],
  );

  const selectedEntity =
    selected?.kind === "entity" ? findEntity(selected.id) : undefined;
  const selectedAssociation =
    selected?.kind === "association" ? findAssociation(selected.id) : undefined;
  const normalizedQuery = query.trim().toLowerCase();

  return (
    <div className="domain-diagram-root">
      <div className="shell">
        <div className="titlebar">
          <div className="brand">
            <div className="logo">MX</div>
            <span>Domain Model</span>
            <span className="project">
              {data ? `${data.project.name} · Mendix ${data.project.mendix_version}` : ""}
            </span>
          </div>
          <div className="spacer" />
          <button className="tool" type="button" onClick={() => void save()}>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M5 4h12l2 2v14H5zM8 4v6h8V4M8 20v-7h8v7" />
            </svg>
            Salvar layout no MPR
          </button>
          <button className="tool primary" type="button" onClick={exportPng}>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M12 3v12m0 0 4-4m-4 4-4-4M4 19h16" />
            </svg>
            Exportar PNG
          </button>
        </div>

        <div className="toolbar">
          <button className="tool" type="button" onClick={() => arrange()}>
            Auto-organizar
          </button>
          <button className="tool" type="button" onClick={() => fit()}>
            Ajustar à tela
          </button>
          <div className="divider" />
          <button className="tool" type="button" onClick={() => updateZoom(zoomRef.current - 0.1)}>
            −
          </button>
          <span className="zoom">{Math.round(zoom * 100)}%</span>
          <button className="tool" type="button" onClick={() => updateZoom(zoomRef.current + 0.1)}>
            +
          </button>
          <div className="divider" />
          <button className="tool" type="button" onClick={() => setGrid((current) => !current)}>
            Grade
          </button>
          <select
            aria-label="Visibilidade dos atributos"
            value={attributeMode}
            onChange={(event) => {
              const next = event.target.value as AttributeMode;
              attributeModeRef.current = next;
              setAttributeMode(next);
            }}
          >
            <option value="all">Atributos: todos</option>
            <option value="keys">Apenas chaves</option>
            <option value="none">Sem atributos</option>
          </select>
          <select
            aria-label="Roteamento dos relacionamentos"
            value={routing}
            onChange={(event) => setRouting(event.target.value as RoutingMode)}
          >
            <option value="orthogonal">Rotas ortogonais</option>
            <option value="shortest">Rotas curtas</option>
          </select>
          <div className="spacer" />
          <div className="legend">
            <span><i className="entity-color" />Entidade</span>
            <span><i className="dto-color" />DTO</span>
            <span><i className="oql-color" />OQL view</span>
          </div>
        </div>

        <div className="workspace">
          <aside className="sidebar">
            <div className="panel-title">
              <span>Módulos</span>
              <span className="panel-actions">
                <button className="panel-action" type="button" onClick={selectAllModules}>Todos</button>
                <button className="panel-action" type="button" onClick={clearModules}>Limpar</button>
              </span>
            </div>
            <input
              className="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Buscar entidade ou atributo…"
            />
            <div>
              {data?.modules.map((module) => {
                const active = selectedModules.has(module.name);
                return (
                  <div
                    className={`module ${active ? "active" : ""}`}
                    key={module.name}
                    onClick={() => toggleModule(module.name)}
                  >
                    <span className="tree-dot">{active ? "✓" : ""}</span>
                    <span>{module.name}</span>
                    <span className="count">{module.entities.length}</span>
                  </div>
                );
              })}
            </div>
          </aside>

          <main
            className={`viewport ${grid ? "grid" : ""}`}
            ref={viewportRef}
            tabIndex={0}
            onClick={() => setSelected(null)}
            onWheel={(event) => {
              if (!event.ctrlKey) return;
              event.preventDefault();
              updateZoom(zoomRef.current + (event.deltaY < 0 ? 0.1 : -0.1));
            }}
          >
            <div
              className="surface"
              style={{ width: WORLD_WIDTH * zoom, height: WORLD_HEIGHT * zoom }}
            >
              <div
                className="stage"
                ref={stageRef}
                style={{ transform: `scale(${zoom})` }}
              >
                <svg className="connections" aria-label="Relacionamentos entre entidades">
                  <defs>
                    <marker
                      id="domain-diagram-arrow"
                      viewBox="0 0 10 10"
                      refX="9"
                      refY="5"
                      markerWidth="7"
                      markerHeight="7"
                      orient="auto-start-reverse"
                    >
                      <path d="M 0 0 L 10 5 L 0 10 z" fill="#66717e" />
                    </marker>
                  </defs>
                  {visibleAssociations.map((association) => {
                    const path = pathFor(
                      association,
                      entitiesByQualifiedName,
                      attributeMode,
                      routing,
                    );
                    if (!path) return null;
                    const isSelected =
                      selected?.kind === "association" && selected.id === association.id;
                    const source = isSelected
                      ? anchorPoint(
                          entitiesByQualifiedName[association.from],
                          association.source_anchor,
                          attributeMode,
                        )
                      : null;
                    const target = isSelected
                      ? anchorPoint(
                          entitiesByQualifiedName[association.to],
                          association.target_anchor,
                          attributeMode,
                        )
                      : null;
                    return (
                      <g key={association.id}>
                        <path
                          className="edge-hit"
                          d={path.d}
                          onClick={(event) => {
                            event.stopPropagation();
                            setSelected({ kind: "association", id: association.id });
                          }}
                        />
                        <path
                          className={`edge ${isSelected ? "selected" : ""}`}
                          d={path.d}
                          markerEnd="url(#domain-diagram-arrow)"
                          onClick={(event) => {
                            event.stopPropagation();
                            setSelected({ kind: "association", id: association.id });
                          }}
                        />
                        <text className="edge-label" x={path.x + 5} y={path.y - 6}>
                          {association.name}
                        </text>
                        {source && (
                          <circle
                            className="edge-anchor source"
                            cx={source[0]}
                            cy={source[1]}
                            r="6"
                            onClick={(event) => {
                              event.stopPropagation();
                              setSelected({ kind: "association", id: association.id });
                            }}
                            onPointerDown={(event) => startAnchorDrag(event, association, "source")}
                          >
                            <title>Arraste a origem</title>
                          </circle>
                        )}
                        {target && (
                          <circle
                            className="edge-anchor target"
                            cx={target[0]}
                            cy={target[1]}
                            r="6"
                            onClick={(event) => {
                              event.stopPropagation();
                              setSelected({ kind: "association", id: association.id });
                            }}
                            onPointerDown={(event) => startAnchorDrag(event, association, "target")}
                          >
                            <title>Arraste a ponta da seta</title>
                          </circle>
                        )}
                      </g>
                    );
                  })}
                </svg>

                <div>
                  {visibleEntities.map((entity) => {
                    const attributes = visibleAttributes(entity, attributeMode);
                    const matches =
                      !normalizedQuery ||
                      entity.name.toLowerCase().includes(normalizedQuery) ||
                      entity.module.toLowerCase().includes(normalizedQuery) ||
                      entity.attributes.some((attribute) =>
                        attribute.name.toLowerCase().includes(normalizedQuery),
                      );
                    const isSelected =
                      selected?.kind === "entity" && selected.id === entity.id;
                    return (
                      <article
                        className={[
                          "entity",
                          `kind-${entity.kind}`,
                          isSelected ? "selected" : "",
                          normalizedQuery ? (matches ? "match" : "dim") : "",
                        ].join(" ")}
                        key={entity.id}
                        style={{ left: entity.x, top: entity.y }}
                        onClick={(event) => {
                          event.stopPropagation();
                          setSelected({ kind: "entity", id: entity.id });
                        }}
                      >
                        <div
                          className="entity-head"
                          onPointerDown={(event) => startEntityDrag(event, entity)}
                        >
                          <span className="kind">{kindCode(entity)}</span>
                          <span className="entity-name">{entity.name}</span>
                          <span className="qualified">{entity.module}</span>
                        </div>
                        {attributes.length ? (
                          <div className="attrs">
                            {attributes.map((attribute) => (
                              <div className="attr" key={`${entity.id}-${attribute.name}`}>
                                <span className="attr-icon">
                                  {attribute.key ? "◆" : attribute.required ? "●" : "○"}
                                </span>
                                <span className="attr-name">{attribute.name}</span>
                                <span className="attr-type">{attribute.type}</span>
                              </div>
                            ))}
                          </div>
                        ) : (
                          <div className="dto">Nenhum atributo visível</div>
                        )}
                        <i className="handle north" />
                        <i className="handle east" />
                        <i className="handle south" />
                        <i className="handle west" />
                      </article>
                    );
                  })}
                </div>
              </div>
            </div>
          </main>

          <aside className="inspector">
            <div className="panel-title">Propriedades</div>
            {!selectedEntity && !selectedAssociation && (
              <div className="empty">
                Selecione uma entidade ou relacionamento.
                <br /><br />
                Marque vários módulos para ver relações entre eles. Arraste o cabeçalho dos
                cards para organizar.
              </div>
            )}
            {selectedEntity && (
              <>
                <div className="section">
                  <h3>{kindLabel(selectedEntity)}</h3>
                  <div className="meta">
                    <strong>{selectedEntity.name}</strong>
                    <small>{selectedEntity.qualified_name}</small>
                    <small>Módulo {selectedEntity.module}</small>
                  </div>
                </div>
                <div className="section">
                  <h3>Posição</h3>
                  <div className="meta">X {selectedEntity.x} · Y {selectedEntity.y}</div>
                  <p className="hint">A posição é gravada no Domain Model do MPR.</p>
                </div>
              </>
            )}
            {selectedAssociation && (
              <>
                <div className="section">
                  <h3>
                    Relacionamento{selectedAssociation.cross_module ? " cross-module" : ""}
                  </h3>
                  <div className="meta">
                    <strong>{selectedAssociation.name}</strong>
                    <small>{selectedAssociation.from} → {selectedAssociation.to}</small>
                    <small>{selectedAssociation.type} · owner {selectedAssociation.owner}</small>
                  </div>
                </div>
                <div className="section">
                  <h3>Pontos de conexão</h3>
                  <div className="field">
                    <label htmlFor="source-anchor">Origem</label>
                    <select
                      id="source-anchor"
                      value={selectedAssociation.source_anchor}
                      onChange={(event) =>
                        setAssociationAnchor(
                          selectedAssociation,
                          "source",
                          event.target.value as Anchor,
                        )
                      }
                    >
                      {ANCHOR_OPTIONS.map(([value, label]) => (
                        <option value={value} key={value}>{label}</option>
                      ))}
                    </select>
                  </div>
                  <div className="field">
                    <label htmlFor="target-anchor">Ponta da seta</label>
                    <select
                      id="target-anchor"
                      value={selectedAssociation.target_anchor}
                      onChange={(event) =>
                        setAssociationAnchor(
                          selectedAssociation,
                          "target",
                          event.target.value as Anchor,
                        )
                      }
                    >
                      {ANCHOR_OPTIONS.map(([value, label]) => (
                        <option value={value} key={value}>{label}</option>
                      ))}
                    </select>
                  </div>
                  <p className="hint">
                    Arraste os pontos laranja e azul diretamente no diagrama ou use os campos
                    acima. Persistência: {selectedAssociation.anchor_storage === "native"
                      ? "campos nativos do Mendix"
                      : "metadados visuais seguros do MXRB"}.
                  </p>
                </div>
              </>
            )}
          </aside>
        </div>

        <div className="statusbar">
          <span className="ok">● conectado</span>
          <span>
            {visibleModules.length} módulo(s) · {visibleEntities.length} entidades ·{" "}
            {visibleAssociations.length} relacionamentos
          </span>
          <span className={dirty ? "dirty" : ""}>{dirtyLabel}</span>
          <span className="spacer" />
          <span>{data ? `Saída: ${data.output}` : ""}</span>
        </div>
      </div>
      <div className={`toast ${toast.visible ? "show" : ""}${toast.error ? " error" : ""}`}>
        {toast.message}
      </div>
    </div>
  );
}
