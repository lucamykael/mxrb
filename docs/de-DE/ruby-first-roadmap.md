# MXRB: Ruby über alles

[Português](../pt-BR/ruby-first-roadmap.md) · [English](../en-US/ruby-first-roadmap.md) · **Deutsch**

## Architekturprinzip

Ruby ist die einzige öffentliche Sprache von MXRB. CLI-Befehle sind dünne
Adapter. Es wird weder MDL noch eine konkurrierende DSL eingeführt. Studio Pro
und MxBuild sind externe Validatoren, keine Abhängigkeiten des Ruby-Kerns.

## Verfügbar

- Tiefes Lesen und Schreiben von MPR v1/v2.
- Export in bearbeitbare Ruby-Projekte.
- Generierung, Integritätsprüfung, Vergleich und typisierter Diff.
- Semantischer Index, Referenzen, Caller/Callee und Impact.
- Sichere Umbenennung mit Vorschau.
- Sichere Entfernung eigenständiger Units mit Vorschau.
- Statische Analyse und ausführbare Modellbewertungen.
- Funktionale Microflow-Tests ohne JUnit.
- Lokale oder Docker-Ausführung von `mx check`, MxBuild und Runtime.
- Striktes Gate mit 100 % Zeilenabdeckung.

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
