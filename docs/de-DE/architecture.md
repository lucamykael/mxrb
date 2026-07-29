# Mendix-Projektarchitektur in MXRB

[Português](../pt-BR/architecture.md) · [English](../en-US/architecture.md) · **Deutsch**

MXRB bildet Mendix-Projekte als bearbeitbares Ruby ab und bewahrt gleichzeitig
das native Modell für sichere Roundtrips. Ruby ist die einzige öffentliche
Sprache; es gibt keine parallele MDL-ähnliche Syntax.

## Kompatibilitätsprinzipien

- Qualifizierte Mendix-Namen bleiben kanonisch.
- Native Units ohne typisierte Ruby-Abstraktion bleiben verlustfrei erhalten.
- Typisierte Änderungen ersetzen nur ausdrücklich deklarierte Strukturen.
- MPR v1 bleibt in SQLite, MPR v2 in `mprcontents/`.
- `mx`, MxBuild und Runtime sind externe Gates, keine Kern-APIs.

## Kanonische Struktur

```text
project.rb
app/{security,navigation}
modules/Sales/
  domain/
  application/
  presentation/
  infrastructure/
  security/
```

`domain` enthält Entitäten und Regeln. `application` enthält Use Cases,
Abfragen und Jobs. `presentation` enthält Seiten und clientseitige Nanoflows.
`infrastructure` enthält Integrationen, Dienste und Adapter.

## Abhängigkeitsregel

```text
presentation ─┐
              ├─> application ─> domain
infrastructure┘
```

Der semantische Graph prüft fehlende Ziele, Zyklen, Modulgrenzen und verbotene
Abhängigkeiten.

## Ruby → Mendix

Definitionen werden ausgewertet, native Units zuerst wiederhergestellt und
typisierte Overlays über stabile Namen zusammengeführt. Danach aktualisiert
MXRB Hashes und v1/v2-Speicher. `mxrb validate`, `mx check` und MxBuild bilden
aufeinanderfolgende Gates.

## Mendix → Ruby

MXRB indexiert alle Units, exportiert typisierte Artefakte und schreibt nicht
typisierte Units nach `.mxrb/native_units.json`. Fingerprints erlauben die
exakte Wiederverwendung unveränderter Flow- und Seitenstrukturen.

## Namenskonventionen und Wahrheit

Mendix-Namen bleiben exakt; Ruby-Dateien verwenden `snake_case`. Ruby ist für
deklarierte typisierte Strukturen maßgeblich, das native Manifest für den
bewahrten Rest. Eine tiefe Ruby-Änderung invalidiert den Fingerprint und wird
neu generiert.
