# Ruby + TypeScript ↔ Mendix-Zertifizierung

Status am 12. August 2026: **beide Szenarien bestanden**.

## Fall 1 — echtes MPR

VetClinic 11.12.1 wurde exportiert, ohne das Original zu verändern. Die Home
wurde angepasst; eine Page, zwei Microflows, ein Nanoflow und eine
konventionelle React-Route entstanden ausschließlich in Ruby/TypeScript.

- MXRB-Validierung/Preflight: keine Findings; 231 Units, 5 Pages, 25 Layouts,
  4 Nanoflows und 16 Microflows.
- Manuelle TypeScript-Dateien überstanden den Reexport bytegenau.
- Prettier, ESLint, Vitest, striktes TypeScript und Vite bestanden.
- Offizielles MxBuild 11.12.1: `BUILD SUCCEEDED`.
- Chromium: keine Konsolenfehler; Home-Microflow und
  Nanoflow → Microflow → Page-Rückmeldung antworteten mit HTTP 200.

Szenario: `spec/fixtures/frontend_browser/vetclinic_real_project_flow.json`.

## Fall 2 — neues Projekt

CarePortal wurde mit `--mode ruby --flymetothemoon` erstellt. Persistente
Entität, Pflichtattribut, Pages, Microflows, Nanoflow, React-Komponente und
manuelle Route wurden nur in Ruby/TypeScript geschrieben.

- Materialisiertes MPR: 14 Units, keine Preflight-Fehler oder -Warnungen.
- Pflichtregel und native Editor-Dokumentform überstanden den Round-trip.
- Offizielles MxBuild 11.12.1: `BUILD SUCCEEDED`.
- Komponente, Test und Routes blieben bytegenau erhalten.
- Alle Frontend-Gates bestanden (4 Vitest-Tests).
- Chromium: keine Konsolenfehler; beide Ruby-Endpunkte antworteten mit HTTP 200
  und die manuelle React-Route aktualisierte ihren Zustand.

Szenario: `spec/fixtures/frontend_browser/care_portal_zero_project_flow.json`.

Temporäre Artefakte liegen unter `/tmp`, Browser-Belege unter ignoriertem
`tmp/browser-*`. Die während der Zertifizierung gefundenen Lücken—Pflichtfelder,
inkorrekte inkrementelle BSON-Form, `tasks`-Icon, monolithisches Frontend und
veraltete generierte Bridge—besitzen jetzt Regressionsabdeckung.
