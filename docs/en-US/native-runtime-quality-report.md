# Native build and Runtime quality report

Date: August 1, 2026.

## Confirmed result

- no functional stage invokes `mx`, `mxbuild`, `mxcli`, Studio Pro, or Model SDK;
- clean 12-stage build and web generation passed on 6.10.8 (39 pages), 7.5.0 (45), 7.17.0 (66), 9.6.1.29396 (90), and 11.12.1;
- format round-trip matrix passed on six real fixtures from 5.21.4 through 11.12.1: 1,506 units, 1,734 artifacts, and 3,388 references;
- audited compiler schemas/seeds cover families 6.x, 7.x, 9.x, and 11.x. Families 5.x, 8.x, and 10.x fail closed for native compilation; Runtime requires the exact patch;
- Data Grid 1 covers database/XPath/microflow sources, search, sorting, paging, selection, and audited buttons. Data Grid 2 covers XPath, attribute columns, and create action;
- web profiles are Dojo on 6/7, hybrid Dojo/React on 9, and React on 11;
- Projects API inventoried 130 accessible apps. Three real Git projects (`MyFirstModule`, `LearnNow Trainning Management`, and `SLATaskApp`) passed validate → export → generate → validate → compare;
- `MyFirstModule` was regenerated as exact 11.12.1 without proprietary builders. Runtime synchronized 655 database operations, created the active `mx` administrator, served the React shell and styled login publicly on `127.0.0.1:18080`, and exposed the expected domain tables;
- final QA: 821 examples, zero failures, 100% lines (12,987/12,987), 100% branches (4,611/4,611), and clean RuboCop across 205 files.

## Corrections from the improvement report

- selective Java proxy generation for entities, inheritance, enumerations, and constants referenced by custom Java;
- official Database Connector build-extension lowering to External Database Connector Java actions, including safe query-builder `SELECT` generation;
- OQL view source compilation, generalized entity persistence flags, demo-user role arrays, system texts, and exact association storage/access rights;
- stable PostgreSQL readiness, public loopback Runtime port (`--runtime-port`), environment-backed admin password, and active admin creation;
- self-contained login resources, rendered template placeholders, cache busting, and styled/i18n login shell;
- Atlas CSS, manifest, and public-asset hydration; the real Team Server
  homepage now renders actionable React grids, headings, and buttons;
- React developer-mode page imports carry the session cache token; the patched
  client chunk is content-hashed and Rspack's self-import shares the entrypoint
  token, eliminating stale blank-homepage reloads without disabling cache;
- the generated shell supplies a bounded `openForm` compatibility adapter over
  `openForm2`, so cached legacy click handlers navigate instead of failing
  silently without issuing a Runtime request;
- real browser clicks verified Home → Courses → Add → Save. Parameter-backed
  DataView/TextBox forms render and persist values; create passes GUIDs through
  `openForm2`, while commit/rollback authorization is derived from page module
  roles. PostgreSQL confirmed the four saved QA values;
- template/image/ZIP traversal and unsafe identifier protection, plus symlink rejection for native inputs;
- comparison normalizes absent Runtime boolean defaults, restoring exact legacy round trips.

## Explicit boundaries

1. Dojo widgets other than Data Grid 1 remain listed in `web/mxrb-legacy-pages.json`; they are not silently reported as rendered.
2. Data Grid 2 coverage is the audited XPath/attribute/create subset; other datasource, filter, and action variants fail closed.
3. Installed 6/7/9 distributions contain exact Runtime bundles but no compatible PAD/launcher. The available 11 launcher requires Java 21 and cannot safely start 9 on Java 11. Legacy `db up` therefore fails closed; only the exact 11.12.1 boot is claimed.
4. Runtime uses a local trial/developer license, which emits the expected time-limit warning.
5. Cloud Build/Deploy/Pipelines/Backups are optional external verification adapters, never dependencies of native generation or Runtime startup.

There is no hidden `mx`/`mxbuild` fallback.
