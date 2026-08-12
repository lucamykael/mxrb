# Ruby + TypeScript ↔ Mendix certification

Status on August 12, 2026: **both scenarios passed**.

## Case 1 — real MPR

VetClinic 11.12.1 was exported without changing the original. Existing Home was
edited and a page, two microflows, a nanoflow, and a conventional React route
were added only through Ruby/TypeScript sources.

- MXRB validation/preflight: no findings; 231 units, 5 pages, 25 layouts,
  4 nanoflows, and 16 microflows.
- Manual TypeScript files survived reexport byte-for-byte.
- Prettier, ESLint, Vitest, strict TypeScript, and Vite passed.
- Official MxBuild 11.12.1: `BUILD SUCCEEDED`.
- Chromium: no console errors; Home microflow and nanoflow → microflow → page
  feedback both completed with HTTP 200.

Scenario: `spec/fixtures/frontend_browser/vetclinic_real_project_flow.json`.

## Case 2 — greenfield project

CarePortal was created with `--mode ruby --flymetothemoon`. Its persistent
entity, required attribute, pages, microflows, nanoflow, React component, and
manual route were authored only in Ruby/TypeScript.

- Materialized MPR: 14 units, zero preflight errors/warnings.
- Required rule and native editor document shape survived round-trip.
- Official MxBuild 11.12.1: `BUILD SUCCEEDED`.
- Manual component, test, and routes survived byte-for-byte.
- All frontend gates passed (4 Vitest tests).
- Chromium: no console errors; both Ruby endpoints returned HTTP 200 and the
  manual React route updated state.

Scenario: `spec/fixtures/frontend_browser/care_portal_zero_project_flow.json`.

Disposable artifacts live under `/tmp`; browser evidence lives under ignored
`tmp/browser-*`. The failures found during certification—required attributes,
runtime-shaped incremental BSON, the `tasks` icon, the monolithic frontend, and
stale generated bridge restoration—now have regression coverage.
