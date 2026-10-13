# MXRB-Architekturstandard

[Português](../pt-BR/architectural-standard.md) · [English](../en-US/architectural-standard.md) · **Deutsch**

## Zentrales Prinzip

Ruby ist die kanonische Architekturdarstellung. Mendix bleibt Laufzeit und
natives Modell. Ein Microflow wird nach seiner Verantwortung klassifiziert,
nicht allein danach, dass er ein Microflow ist.

## Schichten

- `domain`: Entitäten, Beziehungen, Invarianten und Domain Events.
- `application`: Use Cases, Abfragen, Validierungen und Jobs.
- `presentation`: Seiten, UI-Einstiegspunkte und Nanoflows.
- `infrastructure`: Integrationen, Services und technische Adapter.

Abhängigkeiten zeigen nach innen. Modulübergreifender Zugriff erfolgt über
bewusst veröffentlichte APIs.

## Persistenz und Repositories

Direkter Mendix-Retrieve ist für normales CRUD korrekt. Ein Repository ist nur
für eine echte Grenze sinnvoll, etwa externen Speicher, komplexe
Abfrageverträge oder Testisolation.

## Security, Navigation und Designsystem

App Security besitzt User Roles und globale Regeln; Module Security besitzt
Module Roles. Seiten und Flows deklarieren `allowed_roles`. Navigation ist
appweit. Semantische Ruby-Tokens beschreiben Designabsichten, während native
Mendix-Ressourcen erhalten bleiben.

## Qualitätsregeln

MXRB prüft fehlende Referenzen, Zyklen, verbotene Abhängigkeiten,
Zugriffsgrenzen, Benennung und projektspezifische Ruby-Regeln. `mx check` und
MxBuild bleiben die offiziellen Plattform-Gates.

## Supportgrenze

Domain-, Microflow-, Nanoflow-, Seiten-, Menü-, Security- und native
Navigationsflächen sind typisiert bearbeitbar. Theme- und Code-Assets
verwenden ein Manifest mit Prüfsummen; Designsystem-Tokens und -Richtlinien
besitzen einen typisierten Ruby-Vertrag. Workflows, Integrationen,
veröffentlichte APIs und Widgets ohne kompakte API bleiben über tiefes Ruby
und das native Baseline bearbeitbar, benötigen aber noch spezifische
typisierte DSLs.

## Geltungsbereich: Mendix-DSL-Export und ausführbare Ruby-Anwendung

Dieser Standard gilt für den Mendix-DSL-Export (`mxrb export`, Standardmodus),
dessen Ausgabe die architektonische Darstellung des Projekts ist. Die
ausführbare Ruby-Anwendung (`--mode ruby`, `mxrb init --mode ruby`) ist eine
erklärte Ausnahme für Flows. Sie folgt der Konvention von Ruby-Anwendungen und
schreibt Microflows, Nanoflows mit Ruby-Körper und Regeln nach
`app/services/<Modul>/`, eine Datei pro Mendix-Dokument.

Die Ausnahme besteht, weil in diesem Modus jede Service-Klasse die ausführbare
Projektion eines Dokuments ist und dessen Identität trägt (`mendix_name` und
Unit-ID). Eine Datei pro Dokument an einem vorhersehbaren Ort hält die
Änderungen des Entwicklers bytegenau im Round-trip und gleicht Identitäten ab,
ohne die Architektur zu befragen. Die Klassifizierung nach Verantwortung (Use
Case, Abfrage, Validierung, Job, Integration, Endpoint) bleibt für die in der
DSL beschriebene Architektur verpflichtend. In der ausführbaren Anwendung
drückt sie sich im Code aus, den der Entwickler unter `app/` außerhalb von
`app/services` schreibt und den `mxrb` unverändert bewahrt.
