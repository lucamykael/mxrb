# Anforderung: konventionelle Ruby- und TypeScript-Projekte

## Ziel

Mendix-spezifische Strukturen bleiben aus dem Anwendungscode heraus, soweit sie
nicht für eine reversible MPR-Darstellung unvermeidbar sind. Benutzer entwickeln
eine normale Ruby- und React-TypeScript-Anwendung, unabhängig davon, ob sie mit
einem echten MPR oder einem leeren Projekt beginnen.

## Verbindlicher Vertrag

- `app/` enthält konventionellen Ruby-Anwendungscode.
- `frontend/src/app`, `components`, `core`, `features`, `hooks`, `layouts` und
  `styles` gehören dem Entwickler und werden nie regeneriert.
- `frontend/src/generated` ist die einzige von MXRB verwaltete Frontend-Grenze.
- Details zu Dokumenten, Widgets, Microflows, Nanoflows und portablen IDs liegen
  ausschließlich in der generierten Bridge.
- Exporte enthalten Lockfile, striktes TypeScript, Linting, Formatierung, Tests
  und einen Produktions-Build.
- Round-trips erhalten Anwendungsdateien bytegenau und erneuern eine veraltete
  generierte Bridge.
- Neue Entitäten und Attribute verwenden die native Editor-BSON-Form.
  `required: true` erzeugt eine änder- und entfernbare `RequiredRuleInfo`.
- Übliche Namen für Navigationssymbole werden als gültige Glyph-Codes erzeugt.

## Verbindliche Zertifizierung

1. Echtes MPR: exportieren, vorhandene und neue Pages/Flows nur in
   Ruby/TypeScript bearbeiten, kompilieren, reexportieren, in Chromium ausführen
   und mit offiziellen Mendix-Werkzeugen prüfen.
2. Neues Projekt: vollständig in Ruby/TypeScript erstellen, das erste MPR
   materialisieren, reexportieren, ausführen und mit Mendix prüfen.

Beide Fälle müssen Frontend → lokaler Flow → Ruby-Backend → Rückmeldung in der
Page, stabile Dokumente, einen fehlerfreien offiziellen Build und artefaktfreie
lokale Pfade/Secrets belegen. Siehe
[`certificacao-ruby-typescript.md`](certificacao-ruby-typescript.md).
