# MXRB modeler UI

React + TypeScript workspace for the browser-based project modeler, ER editor,
and UML viewer. The project modeler catalogs pages, flows, navigation, security,
integrations, and settings from the same Ruby projection used by the CLI.
Ruby remains authoritative for model parsing, validation, persistence, and APIs.

```sh
npm ci
npm run test:studio
npm run test:build
npm run typecheck
npm run build
```

All editable frontend source must use `.ts` or `.tsx`; `.js` and `.jsx` source
files are rejected by the Ruby test suite. The committed production bundle is
written to `lib/mxrb/web_ui` and ships in the gem. Those generated `.js` files
are distribution artifacts, not source. Node is a development/build dependency
only; MXRB serves the generated HTML, CSS, and JavaScript directly through its
loopback-only Ruby servers.

For development, start the corresponding Ruby server and set
`MXRB_UI_API_PORT=4568` for the ER editor or `MXRB_UI_API_PORT=4569` for UML
before running `npm run dev`.

The catalog and UML browser scenarios share a small versioned project. From the
repository root, generate it and start the server in one terminal:

```sh
mkdir -p tmp/modeler-browser
bundle exec ruby bin/mxrb generate spec/fixtures/modeler_catalog/project.rb tmp/modeler-browser/Shop.mpr
bundle exec ruby -Ilib -rmxrb -e 'Mxrb::Uml::Server.new("tmp/modeler-browser/Shop.mpr", port: 4579).start'
```

In another terminal, exercise the compiled bundles:

```sh
bundle exec ruby script/frontend_browser_acceptance --scenario spec/fixtures/frontend_browser/modeler_catalog_flow.json --url http://127.0.0.1:4579 --output-dir tmp/modeler-browser/catalog
bundle exec ruby script/frontend_browser_acceptance --scenario spec/fixtures/frontend_browser/uml_diagrams_flow.json --url http://127.0.0.1:4579 --output-dir tmp/modeler-browser/uml
```

These scenarios require local Chromium and loopback sockets. They cover catalog
navigation and rendering class, activity, and sequence diagrams using the
bundled Mermaid and DOMPurify dependencies.

The modeler uses esbuild with four HTML entrypoints. `npm run build:studio`
rebuilds only Studio and preserves the other bundles. The development server
uses port 5173 (override with `MXRB_UI_PORT`), proxies `/api` to the Ruby port,
and reloads the browser after source changes. Temporary development bundles
are written to `tmp/modeler-dev`; production assets remain reproducible.
