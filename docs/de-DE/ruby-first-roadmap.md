# MXRB: Ruby über alles

[Português](../pt-BR/ruby-first-roadmap.md) · [English](../en-US/ruby-first-roadmap.md) · **Deutsch**

## Architekturprinzip

Ruby ist die einzige öffentliche Sprache von MXRB. CLI-Befehle sind dünne
Adapter. Es wird weder MDL noch eine konkurrierende DSL eingeführt. Studio Pro
und MxBuild sind externe Validatoren, keine Abhängigkeiten des Ruby-Kerns.

## Verfügbar

- Tiefes Lesen und Schreiben von MPR v1/v2.
- Export in bearbeitbare Ruby-Projekte.
- Bearbeitbare `native_unit`-Hashes für jede native BSON-Struktur.
- Generierung, Integritätsprüfung, Vergleich und typisierter Diff.
- Semantischer Index, Referenzen, Caller/Callee und Impact.
- Sichere Umbenennung mit Vorschau.
- Sichere Entfernung eigenständiger Units mit Vorschau.
- Statische Analyse und ausführbare Modellbewertungen.
- Funktionale Microflow-Tests ohne JUnit.
- Lokale oder Docker-Ausführung von `mx check`, MxBuild und Runtime.
- Striktes Gate mit 100 % Zeilen- und Branch-Abdeckung.

## Beispiel

```ruby
Mxrb.open("app.mpr") do |project|
  project.references_to("Sales.Order")
  project.callers_of("Sales.Recalculate")
  project.impact_of("Sales.Order")
  project.plan_rename("Sales.Order", to: "Invoice")
  plan = project.plan_remove("Sales.UnusedFlow")
  plan.apply! if plan.safe?
  project.analyze
end
```

Bewertungsdateien sind gewöhnliches Ruby und werden mit
`mxrb evaluate app.mpr evaluation.rb` ausgeführt.

Schreibbare Projekte speichern einen fingerprint-basierten Cache des
semantischen Index im MPR. Schreibgeschützte Öffnungen dürfen ihn
wiederverwenden, verändern das Projekt jedoch nie.
`mxrb cache status`, `warm` und `clear` liefern Metriken und Wartung. Beim
Ersetzen wird zuerst per Upsert geschrieben und erst danach ein veralteter
Eintrag entfernt.

Die exakte native Mendix-5-Validierung bleibt von Windows/Studio Pro abhängig.
Sie ist als entfernte Legacy-Einschränkung dokumentiert und kein aktuelles
Auslieferungs-Gate.

Navigationsprofile lesen und schreiben jetzt native Mendix-Dokumente,
einschließlich rollenbasierter Startziele und rekursiver Menüs. Theme- und
Quell-Assets durchlaufen den Round-trip mit einem Prüfsummenmanifest;
Design-Tokens bieten Inventar, Lint, Kontrastmetriken und eine
Preview-basierte Migration literaler Werte.

Beim Entfernen blockieren eingehende Referenzen und Kind-Units den Plan.
Eingebettete Domain-Modellelemente benötigen ihre typisierte Mutation. Die CLI
zeigt mit `mxrb remove app.mpr Sales.UnusedFlow` nur die Vorschau; `--apply`
schreibt ausschließlich einen sicheren Plan.

Eigenständige Units können innerhalb desselben Moduls in ein Modul oder einen
Ordner verschoben werden:

```ruby
plan = project.plan_move("Sales.Process", to: "Sales.Automation")
plan.apply!
```

Der Plan bewahrt den nativen Containment-Typ und blockiert Domain-
Modellelemente, ungültige Container, Ordnerzyklen und modulübergreifende
Verschiebungen. `mxrb move` zeigt eine Vorschau; erst `--apply` schreibt.

## Geplant: offizieller Mendix Marketplace

Diese Befehlsfamilie bleibt von `mxrb module`, dem Installer für interne
Ruby-Module, getrennt. Vorgesehen sind `marketplace search`, GitHub-basiertes
`marketplace pull`, lokales `marketplace import DATEI.mpk` und später
PAT-basiertes `marketplace login/pull`.

Die Reihenfolge ist: öffentliche GitHub-Releases mit Herkunfts- und
Prüfsummen-Lockfile; sicherer lokaler MPK-Import; danach PAT-Unterstützung,
sobald die authentifizierten Plattform-Endpunkte geprüft sind. GitHub deckt
private oder unveröffentlichte Module nicht ab, der lokale MPK-Weg erfordert
einen manuellen Download, und PAT-Unterstützung setzt keine undokumentierten
Endpoint-Verträge voraus.
