import { useEffect, useMemo, useState } from "react";

import { errorMessage, fetchProject, matchesSearch, readableType } from "./helpers";
import type {
  CatalogDocument,
  Flow,
  ModuleCatalog,
  NavigationItem,
  Page,
  ProjectCatalog,
  Section,
} from "./types";
import "./modeler.css";

const SECTIONS: ReadonlyArray<{ id: Section; label: string; glyph: string }> = [
  { id: "overview", label: "Overview", glyph: "⌂" },
  { id: "pages", label: "Pages", glyph: "▤" },
  { id: "logic", label: "Logic", glyph: "◇" },
  { id: "navigation", label: "Navigation", glyph: "↗" },
  { id: "security", label: "Security", glyph: "◈" },
  { id: "integrations", label: "Integrations", glyph: "⇄" },
  { id: "settings", label: "Settings", glyph: "⚙" },
];

function metricLabel(name: string): string {
  return name === "microflows" ? "Microflows" : name === "nanoflows" ? "Nanoflows" : readableType(name);
}

function Empty({ children }: { children: string }) {
  return <div className="empty-state">{children}</div>;
}

function Tags({ values }: { values: string[] }) {
  if (values.length === 0) return <span className="muted">No restrictions</span>;
  return <span className="tags">{values.map((value) => <span key={value}>{value}</span>)}</span>;
}

function ModulePill({ module }: { module: ModuleCatalog }) {
  return (
    <span className="module-pill">
      <span className="module-dot" />
      {module.name}
      {module.marketplace && <small>Marketplace</small>}
    </span>
  );
}

function Overview({ catalog }: { catalog: ProjectCatalog }) {
  const metrics = Object.entries(catalog.summary);
  return (
    <>
      <section className="metric-grid">
        {metrics.map(([name, value]) => (
          <article className="metric-card" key={name}>
            <strong>{value}</strong>
            <span>{metricLabel(name)}</span>
          </article>
        ))}
      </section>
      <section className="surface-card">
        <div className="section-heading">
          <div><p>Application structure</p><h2>Modules</h2></div>
          <span>{catalog.modules.length} loaded</span>
        </div>
        <div className="module-grid">
          {catalog.modules.map((module) => (
            <article className="module-card" key={module.id}>
              <ModulePill module={module} />
              <dl>
                <div><dt>Entities</dt><dd>{module.entities.length}</dd></div>
                <div><dt>Pages</dt><dd>{module.pages.length}</dd></div>
                <div><dt>Logic</dt><dd>{module.microflows.length + module.nanoflows.length}</dd></div>
                <div><dt>Roles</dt><dd>{module.module_roles.length}</dd></div>
              </dl>
            </article>
          ))}
        </div>
      </section>
    </>
  );
}

function Pages({ modules, search }: { modules: ModuleCatalog[]; search: string }) {
  const pages = modules.flatMap((module) => module.pages.map((page) => ({ module, page })))
    .filter(({ page }) => matchesSearch(`${page.qualified_name} ${page.title} ${page.url}`, search));
  if (pages.length === 0) return <Empty>No pages match the current scope.</Empty>;
  return (
    <div className="catalog-list">
      {pages.map(({ module, page }) => <PageCard key={page.id} module={module} page={page} />)}
    </div>
  );
}

function PageCard({ module, page }: { module: ModuleCatalog; page: Page }) {
  return (
    <article className="catalog-card">
      <div className="card-title"><ModulePill module={module} /><span className="kind">Page</span></div>
      <h3>{page.name}</h3>
      <p>{page.title || "Untitled page"}</p>
      <div className="card-facts">
        <span>{page.widget_count} widgets</span><span>{Object.keys(page.widget_types).length} widget types</span>
        <span>{page.url || "No URL"}</span>
      </div>
      <Tags values={page.allowed_module_roles} />
    </article>
  );
}

function Logic({ modules, search }: { modules: ModuleCatalog[]; search: string }) {
  const flows = modules.flatMap((module) => [...module.microflows, ...module.nanoflows]
    .map((flow) => ({ module, flow })))
    .filter(({ flow }) => matchesSearch(`${flow.qualified_name} ${flow.documentation}`, search));
  if (flows.length === 0) return <Empty>No flows match the current scope.</Empty>;
  return (
    <div className="catalog-list">
      {flows.map(({ module, flow }) => <FlowCard key={`${flow.kind}-${flow.id}`} module={module} flow={flow} />)}
    </div>
  );
}

function FlowCard({ module, flow }: { module: ModuleCatalog; flow: Flow }) {
  return (
    <article className="catalog-card">
      <div className="card-title"><ModulePill module={module} /><span className={`kind ${flow.kind}`}>{flow.kind}</span></div>
      <h3>{flow.name}</h3>
      <p>{flow.documentation || "No documentation"}</p>
      <div className="card-facts">
        <span>{flow.parameter_count} parameters</span><span>{flow.object_count} objects</span><span>{flow.flow_count} edges</span>
      </div>
      <Tags values={flow.allowed_module_roles} />
    </article>
  );
}

function Navigation({ catalog }: { catalog: ProjectCatalog }) {
  if (catalog.navigation.profiles.length === 0) return <Empty>No navigation profiles were found.</Empty>;
  return (
    <div className="catalog-list">
      {catalog.navigation.profiles.map((profile) => (
        <article className="catalog-card navigation-card" key={`${profile.kind}-${profile.name}`}>
          <div className="card-title"><span className="kind">{profile.offline ? "Offline" : "Online"}</span></div>
          <h3>{profile.name || profile.kind || "Navigation profile"}</h3>
          <div className="card-facts"><span>Home: {profile.home_page || profile.home_microflow || "not set"}</span></div>
          <NavigationTree items={profile.items} />
        </article>
      ))}
    </div>
  );
}

function NavigationTree({ items }: { items: NavigationItem[] }) {
  if (items.length === 0) return <p className="muted">No menu items</p>;
  return (
    <ul className="navigation-tree">
      {items.map((item, index) => (
        <li key={`${item.page || item.microflow || "item"}-${index}`}>
          <span>{Object.values(item.caption ?? {})[0] || item.page || item.microflow || "Menu item"}</span>
          {item.items && <NavigationTree items={item.items} />}
        </li>
      ))}
    </ul>
  );
}

function Security({ catalog, modules }: { catalog: ProjectCatalog; modules: ModuleCatalog[] }) {
  return (
    <div className="two-column">
      <section className="surface-card">
        <div className="section-heading"><div><p>Project policy</p><h2>{catalog.security.level || "Not configured"}</h2></div></div>
        {catalog.security.user_roles.length === 0 ? <Empty>No project user roles were found.</Empty> :
          catalog.security.user_roles.map((role) => (
            <article className="role-row" key={role.name}><div><strong>{role.name}</strong><p>{role.description || "No description"}</p></div><Tags values={role.module_roles} /></article>
          ))}
      </section>
      <section className="surface-card">
        <div className="section-heading"><div><p>Module policy</p><h2>Module roles</h2></div></div>
        {modules.flatMap((module) => module.module_roles.map((role) => ({ module, role }))).map(({ module, role }) => (
          <article className="role-row" key={`${module.id}-${role.name}`}><div><strong>{module.name}.{role.name}</strong><p>{role.description || "No description"}</p></div></article>
        ))}
      </section>
    </div>
  );
}

function Documents({ modules, search, configuration = false }: { modules: ModuleCatalog[]; search: string; configuration?: boolean }) {
  const documents = modules.flatMap((module) => (configuration ? module.configurations : module.integrations)
    .map((document) => ({ module, document })))
    .filter(({ document }) => matchesSearch(`${document.name} ${document.type} ${document.group}`, search));
  if (documents.length === 0) return <Empty>No matching model documents were found.</Empty>;
  return <div className="catalog-list">{documents.map(({ module, document }) => <DocumentCard key={document.id} module={module} document={document} />)}</div>;
}

function DocumentCard({ module, document }: { module: ModuleCatalog; document: CatalogDocument }) {
  return (
    <article className="catalog-card"><div className="card-title"><ModulePill module={module} /><span className="kind">{document.group}</span></div><h3>{document.name}</h3><p>{readableType(document.type)}</p></article>
  );
}

function Settings({ catalog, modules, search }: { catalog: ProjectCatalog; modules: ModuleCatalog[]; search: string }) {
  return (
    <div className="settings-stack">
      <Documents modules={modules} search={search} configuration />
      {catalog.settings.map((setting) => (
        <section className="surface-card" key={setting.id}>
          <div className="section-heading"><div><p>{readableType(setting.type)}</p><h2>{setting.name || "Project settings"}</h2></div></div>
          <dl className="settings-grid">{Object.entries(setting.values).map(([name, value]) => <div key={name}><dt>{readableType(name)}</dt><dd>{String(value)}</dd></div>)}</dl>
        </section>
      ))}
    </div>
  );
}

export function App() {
  const [catalog, setCatalog] = useState<ProjectCatalog | null>(null);
  const [section, setSection] = useState<Section>("overview");
  const [moduleName, setModuleName] = useState("all");
  const [search, setSearch] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    fetchProject(controller.signal).then(setCatalog).catch((reason: unknown) => {
      if (!controller.signal.aborted) setError(errorMessage(reason));
    });
    return () => controller.abort();
  }, []);

  const modules = useMemo(() => catalog?.modules.filter((module) => moduleName === "all" || module.name === moduleName) ?? [], [catalog, moduleName]);

  if (error) return <main className="load-screen error"><strong>Project modeler unavailable</strong><span>{error}</span></main>;
  if (!catalog) return <main className="load-screen"><span className="spinner" />Loading Mendix project…</main>;

  const currentLabel = SECTIONS.find((item) => item.id === section)?.label ?? section;
  return (
    <div className="modeler-app">
      <header className="topbar">
        <a className="brand" href="./modeler"><span>MX</span><strong>MXRB Modeler</strong></a>
        <div className="project-identity"><strong>{catalog.project.name}</strong><span>Mendix {catalog.project.mendix_version}</span></div>
        <nav><a href="./">UML diagrams</a><a href="http://127.0.0.1:4568/">Domain editor</a></nav>
      </header>
      <aside className="sidebar">
        <p>Workspace</p>
        {SECTIONS.map((item) => <button className={section === item.id ? "active" : ""} key={item.id} onClick={() => setSection(item.id)}><span>{item.glyph}</span>{item.label}</button>)}
        <div className="sidebar-footer"><span>Read-only projection</span><small>Ruby backend · React TypeScript</small></div>
      </aside>
      <main className="modeler-main">
        <div className="workspace-header">
          <div><p>Project model</p><h1>{currentLabel}</h1></div>
          <div className="workspace-tools">
            <input aria-label="Search artifacts" onChange={(event) => setSearch(event.target.value)} placeholder="Search model…" value={search} />
            <select aria-label="Filter module" onChange={(event) => setModuleName(event.target.value)} value={moduleName}><option value="all">All modules</option>{catalog.modules.map((module) => <option key={module.id} value={module.name}>{module.name}</option>)}</select>
          </div>
        </div>
        {section === "overview" && <Overview catalog={{ ...catalog, modules }} />}
        {section === "pages" && <Pages modules={modules} search={search} />}
        {section === "logic" && <Logic modules={modules} search={search} />}
        {section === "navigation" && <Navigation catalog={catalog} />}
        {section === "security" && <Security catalog={catalog} modules={modules} />}
        {section === "integrations" && <Documents modules={modules} search={search} />}
        {section === "settings" && <Settings catalog={catalog} modules={modules} search={search} />}
      </main>
    </div>
  );
}
