# MXRB modeler UI

React + TypeScript workspace for the browser-based project modeler, ER editor,
and UML viewer. The project modeler catalogs pages, flows, navigation, security,
integrations, and settings from the same Ruby projection used by the CLI.
Ruby remains authoritative for model parsing, validation, persistence, and APIs.

```sh
npm install
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
